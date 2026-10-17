/**
 * 采集服务 —— 手机端的编排核心。
 *
 * 职责：
 *   1. 按周期从 HealthStore 读取各指标，归一化成协议 payload
 *   2. 维护 seq（单调递增）与 lastSeq 持久化，供断线补传
 *   3. 通过 Transport 把信封发出去（传输细节完全不知道）
 *   4. 处理电脑下发的 hello_ack（远程调采集周期、补传要求）
 *   5. 维护一份运行状态给 UI 显示
 *
 * 刻意不做的事：不直接调用 webSocket，不直接调用 healthStore 的裸接口，
 * 只依赖 Transport / HealthStoreClient 两个抽象，方便替换与测试。
 */

import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

import { Logger } from '../common/Logger';
import { AppPrefs, KEYS } from '../common/Prefs';
import { HealthStoreClient } from '../health/HealthStoreClient';
import { BleHealthSource } from '../health/BleHealthSource';
import { HealthSource } from '../health/HealthSource';
import {
  BatchPayload,
  Envelope,
  HealthMetric,
  HelloAckPayload,
  HelloPayload,
  PROTOCOL_VERSION,
  PermissionsPayload,
  QueuedSample,
  SamplePayload,
  SleepPayload,
  SourceKind,
  sourceLabel,
  sleepStatusLabel
} from '../model/HealthTypes';
import { ContinuousTaskManager } from './ContinuousTaskManager';
import { LanWsTransport, ensureDeviceId } from '../transport/LanWsTransport';
import { TransportEvents, TransportState } from '../transport/Transport';

const TAG = 'CollectionService';

/**
 * 周期采集的去重窗口（毫秒）。
 * 推送型数据源（BLE 心率）已即时上传；周期采集在这个窗口内不再重发同一指标，
 * 超过窗口才补发一次，作为"兜底防止漏发"。取 30 秒 ≈ 默认周期的一半。
 */
const HR_PUSH_DEDUP_WINDOW_MS = 30000;

export interface ServiceSnapshot {
  running: boolean;
  transportState: TransportState;
  deviceId: string;
  serverUrl: string;
  collectIntervalMs: number;
  lastSeq: number;
  sentCount: number;
  pendingCount: number;
  droppedCount: number;
  lastSampleAt: number;
  lastError: string;
  /** 当前数据源是否就绪 */
  healthStoreReady: boolean;
  /** 已授权的健康指标（仅 HealthKit 数据源有意义；BLE 下为空） */
  authorizedMetrics: HealthMetric[];
  backgroundTaskRunning: boolean;
  backgroundModes: string[];
  lastSamples: SamplePayload[];
  lastSleep: SleepPayload | null;
  remoteIntervalMs: number;

  // ---- 数据源相关（BLE 直连版新增）----
  /** 当前数据源种类 */
  sourceKind: SourceKind;
  /** 数据源名字（给 UI 显示） */
  sourceName: string;
  /** 数据源自身状态文字，例如"已连接 HUAWEI WATCH" */
  sourceStateText: string;
  /** BLE 已连接的设备名 */
  bleDeviceName: string;
  /** BLE 是否已连接 */
  bleConnected: boolean;
  /** BLE 设备电量（-1 表示未读到） */
  bleBattery: number;
}

export type SnapshotListener = (snapshot: ServiceSnapshot) => void;

export class CollectionService {
  private static instance: CollectionService | null = null;

  private transport: LanWsTransport = new LanWsTransport();
  private background: ContinuousTaskManager = new ContinuousTaskManager();

  /**
   * 两个数据源实例都常驻。
   * 为什么要都留着：用户在 UI 上切换数据源时，如果每次都 new 一个，
   * BLE 那边的扫描监听、GATT 连接状态会丢失，切换回来还得重连。
   */
  private bleSource: BleHealthSource = new BleHealthSource();
  private kitSource: HealthStoreClient = new HealthStoreClient();
  /** 当前生效的数据源种类（从偏好存储读，默认 BLE —— 它不需要华为审批） */
  private sourceKind: SourceKind = 'ble';

  private running: boolean = false;
  private timerId: number = -1;
  private lastSampleAt: number = 0;
  private lastError: string = '';
  private remoteIntervalMs: number = 0;
  private lastSamples: SamplePayload[] = [];
  private lastSleep: SleepPayload | null = null;
  /**
   * 每个指标最近一次「已上传」的时间戳。
   * 用途：BLE 是推送型，收到值就由 [pushImmediately] 立即上传；
   * 周期采集（tick）再用它去重，避免同一条数据被发两次。
   */
  private lastSentAt: Map<string, number> = new Map();
  private lastHelloAck: HelloAckPayload | null = null;
  private authorizedMetrics: HealthMetric[] = [];
  private listeners: SnapshotListener[] = [];
  private tickInFlight: boolean = false;

  static getInstance(): CollectionService {
    if (CollectionService.instance === null) {
      CollectionService.instance = new CollectionService();
    }
    return CollectionService.instance;
  }

  // ---------------------------------------------------------------- 数据源

  /** 当前数据源（统一按 HealthSource 接口用） */
  getSource(): HealthSource {
    return this.sourceKind === 'ble' ? this.bleSource : this.kitSource;
  }

  getSourceKind(): SourceKind {
    return this.sourceKind;
  }

  /** BLE 数据源实例（扫描页要直接用它做扫描/连接） */
  getBleSource(): BleHealthSource {
    return this.bleSource;
  }

  /** 华为 Kit 数据源实例（授权按钮要用） */
  getKitSource(): HealthStoreClient {
    return this.kitSource;
  }

  /**
   * 兼容旧调用（UI 里原本用 getHealthClient() 请求授权）。
   * 新代码请用 getKitSource()，语义更清楚。
   */
  getHealthClient(): HealthStoreClient {
    return this.kitSource;
  }

  /**
   * 切换数据源。
   * 切换时会：停掉旧数据源 → 记住选择 → 初始化新数据源。
   * 正在采集的话会一并停止，避免两个源同时往同一个 seq 上写。
   */
  async setSourceKind(kind: SourceKind): Promise<void> {
    if (this.sourceKind === kind) return;
    Logger.info(TAG, `切换数据源：${sourceLabel(this.sourceKind)} → ${sourceLabel(kind)}`);

    const wasRunning = this.running;
    if (wasRunning) await this.stop();

    try {
      await this.getSource().stop();
    } catch (err) {
      Logger.warn(TAG, '停止旧数据源时出错（继续切换）');
    }

    this.sourceKind = kind;
    await AppPrefs.put(KEYS.sourceKind, kind);

    // 初始化新数据源
    const ctx = this.storedContext;
    const result = await this.getSource().init(ctx === null ? undefined : ctx);
    if (!result.ready) {
      this.setError(`${sourceLabel(kind)} 初始化失败：${result.message}`);
    } else {
      Logger.info(TAG, `${sourceLabel(kind)} 已就绪`);
    }
    this.notify();
  }

  // ---------------------------------------------------------------- 生命周期

  /** UIAbility 的 context，长时任务与 HealthStore 初始化都需要它 */
  private storedContext: common.UIAbilityContext | null = null;

  setAbilityContext(context: common.UIAbilityContext): void {
    this.storedContext = context;
  }

  getContext(): common.UIAbilityContext | null {
    return this.storedContext;
  }

  /** 只做一次的重活：初始化偏好存储、数据源、传输层事件 */
  async bootstrap(): Promise<void> {
    ensureDeviceId();

    // 恢复上次选择的数据源；默认 BLE（不需要华为审批，开箱可用）
    const saved = AppPrefs.getString(KEYS.sourceKind, 'ble');
    this.sourceKind = saved === 'healthStore' ? 'healthStore' : 'ble';

    // ⚠️ 必须把上次保存的「电脑地址」读回传输层。
    //    踩过的坑：原来只写了 AppPrefs.put(KEYS.serverUrl)，却从来没有读回来 ——
    //    于是用户填过地址、也看到"已连接"，但 App 一重启地址就变回"（未设置）"，
    //    数据全进离线队列、界面上什么都没发出去，极难排查。
    const savedUrl = AppPrefs.getString(KEYS.serverUrl, '');
    if (savedUrl.length > 0) {
      this.transport.setUrl(savedUrl);
      Logger.info(TAG, `已恢复上次的电脑地址：${savedUrl}`);
    } else {
      Logger.warn(TAG, '尚未设置电脑地址，数据会先暂存在手机里');
    }

    const ctx = this.storedContext;
    const source = this.getSource();

    // 把数据源产生的每一条 payload 记进"最近一轮"，供 UI 显示与手动同步。
    // 注意：这里**不发包**，发包统一由 tick() 里的 syncOnce() 返回值驱动 ——
    // 否则推送型数据源（BLE 通知）会和轮询路径重复发送。
    source.onSample((payload: SamplePayload) => {
      this.rememberSample(payload);
    });

    if (this.sourceKind === 'healthStore') {
      const initResult = await source.init(ctx === null ? undefined : ctx);
      if (!initResult.ready) {
        this.setError(initResult.message);
      }
    } else {
      const initResult = await this.bleSource.init();
      if (!initResult.ready) {
        this.setError(initResult.message);
      }
    }

    this.wireTransport();
    this.notify();
  }

  /** 记一条样本到"最近一轮"（不做发送） */
  private rememberSample(payload: SamplePayload): void {
    // 同一指标只保留最新一条，避免 lastSamples 随时间无限增长
    const idx = this.lastSamples.findIndex((p) => p.metric === payload.metric);
    if (idx >= 0) this.lastSamples[idx] = payload;
    else this.lastSamples.push(payload);
    if (payload.metric === 'sleep' && payload.sleep) {
      this.lastSleep = payload.sleep;
    }
    this.lastSampleAt = Date.now();

    // ⚠️ 推送型数据源（BLE 心率）收到值就**立即上传**，不等下一个采集周期。
    //    原来的架构把 BLE 当"轮询型"处理：值只进 latest 缓存，等 tick（默认 60s）才发送，
    //    于是用户看到的是"心率半天不动、点一下手动同步才上去"。
    //    周期采集保留为兜底（防止个别漏发），去重由 [lastSentAt] 负责。
    this.pushImmediately(payload);
  }

  /**
   * 立即发送一条刚采集到的数据（不做周期等待）。
   * 只负责"推"，不负责"存"；失败时交给传输层的离线队列，不丢数据。
   */
  private pushImmediately(payload: SamplePayload): void {
    if (!this.running) return;
    if (this.transport.state !== 'open') {
      // 没连上电脑就先不推，等周期采集/重连后由队列统一补（避免无谓的 seq 消耗）
      return;
    }
    // 记录"已发送时间"，供 tick 去重，避免同一条数据被周期采集再发一次
    this.lastSentAt.set(payload.metric, Date.now());
    this.sendSample(payload).catch((e: Error) => {
      Logger.warn(TAG, `即时上传失败: ${e.message}`);
    });
  }

  getBackgroundManager(): ContinuousTaskManager {
    return this.background;
  }

  private wireTransport(): void {
    const events: TransportEvents = {
      onOpen: () => {
        Logger.info(TAG, '传输层已连接，准备发送 hello');
        this.sendHello().catch((e: Error) => Logger.error(TAG, `发送 hello 失败: ${e.message}`));
        this.notify();
      },
      onClose: (code: number, reason: string) => {
        Logger.warn(TAG, `传输层断开 code=${code} reason=${reason}`);
        this.notify();
      },
      onError: (message: string) => {
        this.setError(message);
      },
      onMessage: (envelope: Envelope) => {
        this.handleDownlink(envelope);
      },
      onStateChange: () => {
        this.notify();
      }
    };
    this.transport.setEvents(events);
  }

  /** 设置电脑地址，例如 ws://192.168.1.5:18787/ingest?token=xxx */
  async setServerUrl(url: string): Promise<void> {
    this.transport.setUrl(url);
    await AppPrefs.put(KEYS.serverUrl, url);
    Logger.info(TAG, `电脑地址已设置为 ${url}`);
    this.notify();
  }

  getServerUrl(): string {
    return this.transport.endpoint;
  }

  getTransport(): LanWsTransport {
    return this.transport;
  }

  /** 开始采集并上传 */
  async start(): Promise<void> {
    if (this.running) {
      Logger.info(TAG, '采集已在运行');
      return;
    }
    const url = this.transport.endpoint;
    if (!url || url.length === 0) {
      this.setError('请先填写电脑地址（在下方「电脑地址」输入框里粘贴启动器打印的那一行，再点保存）');
      return;
    }

    // 1) 申请长时任务，否则退后台 3 秒就被挂起
    if (this.storedContext !== null) {
      this.background.setContext(this.storedContext);
      const taskState = await this.background.start(['bluetoothInteraction', 'dataTransfer']);
      if (!taskState.running) {
        this.setError(`长时任务申请失败：${taskState.lastError}`);
      }
    } else {
      Logger.warn(TAG, '没有 UIAbilityContext，跳过长时任务申请（退后台会被系统挂起）');
    }

    // 2) 启动数据源
    //    BLE 路径下必须先连上设备才能采，这里会明确报错而不是静默空转，
    //    否则用户只会看到"连接正常但永远没有数据"，极难排查。
    const source = this.getSource();
    if (!source.isReady()) {
      const r = await source.init(this.storedContext === null ? undefined : this.storedContext);
      if (!r.ready) {
        this.setError(`${sourceLabel(this.sourceKind)} 未就绪：${r.message}`);
        return;
      }
    }
    const started = await source.start();
    if (!started.ready) {
      this.setError(`${sourceLabel(this.sourceKind)} 启动失败：${started.message}`);
      return;
    }

    // 3) 连电脑
    this.running = true;
    await this.transport.connect();

    // 4) 立刻采一轮，然后按周期采
    await this.tick();
    this.scheduleNext();
    Logger.info(TAG, `采集已启动，数据源=${source.name}，周期 ${this.collectIntervalMs()}ms`);
    this.notify();
  }

  /** 停止采集并上传 */
  async stop(): Promise<void> {
    this.running = false;
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.transport.close();
    await this.background.stop();
    Logger.info(TAG, '采集已停止');
    this.notify();
  }

  isRunning(): boolean {
    return this.running;
  }

  /** 立刻手动采一轮（UI 上的"立即同步"按钮） */
  async syncNow(): Promise<void> {
    // 地址没填就点同步，数据只会静默进离线队列、并白白消耗序号 ——
    // 用户看不到任何反馈，会以为"同步按钮坏了"。这里明确拦住并说明原因。
    const url = this.transport.endpoint;
    if (!url || url.length === 0) {
      this.setError('还没填「电脑地址」，数据只能暂存在手机里 —— 请先填地址并保存');
      this.notify();
      return;
    }
    await this.tick();
    if (this.running) this.scheduleNext();
    this.notify();
  }

  // ---------------------------------------------------------------- 采集循环

  private scheduleNext(): void {
    if (this.timerId !== -1) clearTimeout(this.timerId);
    if (!this.running) return;
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      this.tick()
        .catch((e: Error) => Logger.error(TAG, `采集轮次异常: ${e.message}`))
        .then(() => {
          this.scheduleNext();
        });
    }, this.collectIntervalMs());
  }

  /** 采集周期：电脑下发的优先，其次是本地设置 */
  collectIntervalMs(): number {
    if (this.remoteIntervalMs >= 10000) return this.remoteIntervalMs;
    return AppPrefs.getNumber(KEYS.collectIntervalMs, 60000);
  }

  /**
   * 采集一轮。
   *
   * 这里刻意做了"数据源无关"：不管底下是 BLE 还是华为 Kit，
   * 都通过 `source.syncOnce()` 拿到"这一轮有哪些新数据"再发送。
   *
   * 为什么不直接用数据源的推送回调来发送：
   *   BLE 是推送型（特征值变化就回调），Kit 是拉取型（轮询读）。
   *   如果推送回调里也发送，BLE 路径会和这里的 syncOnce() 返回值重复发送。
   *   所以推送回调只负责"记进最近一轮"，发送统一走这里 —— 一个出口，不会重复。
   */
  private async tick(): Promise<void> {
    if (this.tickInFlight) {
      Logger.warn(TAG, '上一轮采集还没结束，跳过本轮');
      return;
    }
    this.tickInFlight = true;
    const collected: SamplePayload[] = [];
    try {
      const source = this.getSource();
      let fresh: SamplePayload[] = [];
      try {
        fresh = await source.syncOnce();
      } catch (err) {
        const e = err as BusinessError;
        Logger.warn(TAG, `数据源 ${source.name} 采集失败: ${e.message}`);
        this.setError(`采集失败：${e.message}`);
      }

      for (const payload of fresh) {
        // 去重：这条数据如果在「周期内」已经被 pushImmediately 即时上传过，就不重复发送。
        // 只有超过周期一半才重发，避免同一条数据被上传两次。
        const sentAt = this.lastSentAt.get(payload.metric);
        if (sentAt !== undefined && Date.now() - sentAt < HR_PUSH_DEDUP_WINDOW_MS) {
          continue;
        }
        this.lastSentAt.set(payload.metric, Date.now());
        collected.push(payload);
        await this.sendSample(payload);
        if (payload.metric === 'sleep' && payload.sleep) {
          this.lastSleep = payload.sleep;
          Logger.info(
            TAG,
            `睡眠数据已采集：得分=${payload.sleep.sleepScore} 分期段数=${payload.sleep.sleepSegment ? payload.sleep.sleepSegment.length : 0}`
          );
        }
      }

      if (collected.length > 0) this.clearError();
      if (collected.length === 0 && this.running) {
        // 不是错误，但要留下线索，方便排查"为什么没数据"
        const st = source.getStatus();
        Logger.info(TAG, `本轮无新数据（数据源=${source.name}，状态=${st.stateText}）`);
      }

      // 长时任务进度续期（DATA_TRANSFER 超过 10 分钟不更新会被取消）
      if (this.background.isRunning()) {
        const detail = collected.length > 0
          ? `已采集 ${collected.length} 项，最近：${describe(collected[collected.length - 1])}`
          : `本轮无新数据（${source.getStatus().stateText}）`;
        await this.background.updateProgress(detail);
      }
    } finally {
      this.tickInFlight = false;
      this.notify();
    }
  }

  // ---------------------------------------------------------------- 发送

  private nextSeq(): number {
    const current = AppPrefs.getNumber(KEYS.seq, 0);
    const next = current + 1;
    AppPrefs.put(KEYS.seq, next).catch(() => {
      Logger.warn(TAG, 'seq 持久化失败');
    });
    return next;
  }

  lastSeq(): number {
    return AppPrefs.getNumber(KEYS.seq, 0);
  }

  private async sendSample(payload: SamplePayload): Promise<void> {
    const envelope: Envelope = {
      v: PROTOCOL_VERSION,
      type: 'sample',
      seq: this.nextSeq(),
      ts: Date.now(),
      deviceId: ensureDeviceId(),
      payload: payload
    };
    await this.transport.send(envelope);

    // 数据没连上电脑时会静默进离线队列。这里明确说清楚，
    // 否则用户只会看到"日志有数据但电脑上什么都没有"，极难排查。
    if (this.transport.state !== 'open') {
      Logger.warn(
        TAG,
        `已采集 ${payload.metric}=${payload.value}，但电脑未连接（传输状态=${this.transport.state}），` +
          `已存入离线队列，连接恢复后会自动补传`
      );
      this.setError('数据已采集，但还没连上电脑 —— 请填写「电脑地址」并保存');
    }
  }

  /** 连接建立后必须发的第一条消息 */
  private async sendHello(): Promise<void> {
    const hello: HelloPayload = {
      protocol: PROTOCOL_VERSION,
      model: this.deviceModel(),
      osVersion: this.osVersion(),
      appVersion: '1.0.0',
      collectIntervalMs: this.collectIntervalMs(),
      lastSeq: this.lastSeq(),
      backgroundMode: this.background.getState().modes,
      healthStoreReady: this.getSource().isReady(),
      permissions: this.permissionSnapshot()
    };
    const envelope: Envelope = {
      v: PROTOCOL_VERSION,
      type: 'hello',
      seq: 1,
      ts: Date.now(),
      deviceId: ensureDeviceId(),
      payload: hello
    };
    await this.transport.send(envelope);
    Logger.info(TAG, `hello 已发送，lastSeq=${hello.lastSeq}`);
  }

  // ---------------------------------------------------------------- 下行处理

  private handleDownlink(envelope: Envelope): void {
    switch (envelope.type) {
      case 'hello_ack':
        this.handleHelloAck(envelope);
        break;
      case 'ack':
        Logger.debug(TAG, `收到 ack: ${JSON.stringify(envelope.payload)}`);
        break;
      case 'nack':
        Logger.warn(TAG, `收到 nack: ${JSON.stringify(envelope.payload)}`);
        this.setError(`电脑端拒绝：${JSON.stringify(envelope.payload)}`);
        break;
      case 'pong':
        Logger.debug(TAG, '收到 pong');
        break;
      case 'ping':
        // 传输层已自动回 pong
        break;
      default:
        Logger.warn(TAG, `未知下行类型 ${envelope.type}，已忽略`);
        break;
    }
  }

  private handleHelloAck(envelope: Envelope): void {
    const payload = envelope.payload as HelloAckPayload;
    this.lastHelloAck = payload;

    // 电脑可以远程调整采集周期
    if (payload.collectIntervalMs && payload.collectIntervalMs !== this.remoteIntervalMs) {
      this.remoteIntervalMs = payload.collectIntervalMs;
      Logger.info(TAG, `电脑下发采集周期 ${payload.collectIntervalMs}ms，已生效`);
      if (this.running) this.scheduleNext();
    }

    // 电脑说它缺数据：needBackfillFrom > 0 时补传
    if (payload.needBackfillFrom && payload.needBackfillFrom > 0) {
      Logger.info(TAG, `电脑请求从 seq=${payload.needBackfillFrom} 开始补传`);
      this.sendBackfill(payload.needBackfillFrom).catch((e: Error) => {
        Logger.warn(TAG, `补传失败: ${e.message}`);
      });
    }
    this.notify();
  }

  /**
   * 补传。
   *
   * 诚实说明：手机端只在内存里保留"最近一轮"的样本，所以**无法**真正补传
   * 断线期间的全部历史。这里做的是：
   *   - 把最近一轮采集到的样本重新发一遍（能覆盖短暂闪断）
   *   - 如果需要的起点比本地能提供的更早，明确把缺口告知电脑端，而不是假装补全
   * 这样电脑端能看到真实情况，不会误以为数据完整。
   */
  private async sendBackfill(fromSeq: number): Promise<void> {
    const samples = this.lastSamples;
    if (samples.length === 0) {
      Logger.warn(TAG, `电脑要求补传 seq>=${fromSeq}，但本地没有可补的样本（缺口需由电脑端记录）`);
      return;
    }
    const batch: BatchPayload = {
      samples: samples,
      count: samples.length,
      reason: 'reconnect_backfill'
    };
    const envelope: Envelope = {
      v: PROTOCOL_VERSION,
      type: 'batch',
      seq: this.nextSeq(),
      ts: Date.now(),
      deviceId: ensureDeviceId(),
      payload: batch
    };
    await this.transport.send(envelope);
    Logger.info(TAG, `已补传 ${samples.length} 条（覆盖最近一轮，更早的缺口电脑端需自行标记）`);
  }

  // ---------------------------------------------------------------- 状态

  getSnapshot(): ServiceSnapshot {
    const bg = this.background.getState();
    const source = this.getSource();
    const srcStatus = source.getStatus();
    return {
      running: this.running,
      transportState: this.transport.state,
      deviceId: ensureDeviceId(),
      serverUrl: this.transport.endpoint,
      collectIntervalMs: this.collectIntervalMs(),
      lastSeq: this.lastSeq(),
      sentCount: this.transport.sent,
      pendingCount: this.transport.pendingCount,
      droppedCount: this.transport.dropped,
      lastSampleAt: this.lastSampleAt,
      lastError: this.lastError,
      healthStoreReady: source.isReady(),
      authorizedMetrics: this.authorizedMetrics,
      backgroundTaskRunning: bg.running,
      backgroundModes: bg.modes,
      lastSamples: this.lastSamples,
      lastSleep: this.lastSleep,
      remoteIntervalMs: this.remoteIntervalMs,
      // ---- 数据源相关 ----
      sourceKind: this.sourceKind,
      sourceName: source.name,
      sourceStateText: srcStatus.stateText,
      bleDeviceName: this.bleSource.getStatus().deviceName,
      bleConnected: this.bleSource.isConnected(),
      bleBattery: this.bleSource.getBatteryLevel()
    };
  }

  subscribe(listener: SnapshotListener): void {
    this.listeners.push(listener);
  }

  unsubscribe(listener: SnapshotListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  setAuthorizedMetrics(metrics: HealthMetric[]): void {
    this.authorizedMetrics = metrics;
    this.notify();
  }

  private setError(message: string): void {
    this.lastError = message;
    this.notify();
  }

  private clearError(): void {
    if (this.lastError.length > 0) {
      this.lastError = '';
    }
  }

  private notify(): void {
    const snapshot = this.getSnapshot();
    for (const listener of this.listeners) {
      try {
        listener(snapshot);
      } catch (err) {
        Logger.warn(TAG, '状态监听回调异常');
      }
    }
  }

  private permissionSnapshot(): PermissionsPayload {
    return {
      healthDataRead: this.authorizedMetrics.length > 0,
      internet: true,
      keepBackgroundRunning: this.background.getState().running
    };
  }

  private deviceModel(): string {
    try {
      return `${deviceInfo.brand} ${deviceInfo.marketName}`;
    } catch (err) {
      return 'unknown';
    }
  }

  private osVersion(): string {
    try {
      return `${deviceInfo.osFullName} (API ${deviceInfo.sdkApiVersion})`;
    } catch (err) {
      return 'unknown';
    }
  }
}

/** 生成给日志/通知用的一句话描述 */
export function describe(payload: SamplePayload): string {
  if (payload.metric === 'sleep') {
    const sleep = payload.sleep;
    if (sleep === null || sleep === undefined) return '睡眠（无明细）';
    const score = sleep.sleepScore === null || sleep.sleepScore === undefined ? '?' : `${sleep.sleepScore}`;
    const segs = sleep.sleepSegment ? sleep.sleepSegment.length : 0;
    const first = sleep.sleepSegment && sleep.sleepSegment.length > 0
      ? sleepStatusLabel(sleep.sleepSegment[0].sleepStatus)
      : '无分期';
    return `睡眠 得分=${score} 分期${segs}段(首段${first})`;
  }
  const unit = payload.unit === null ? '' : payload.unit;
  return `${payload.metric}=${payload.value}${unit}`;
}

/** 把队列样本转成可读文本（调试用） */
export function describeQueued(sample: QueuedSample): string {
  return `#${sample.seq} ${describe(sample.payload)}`;
}
