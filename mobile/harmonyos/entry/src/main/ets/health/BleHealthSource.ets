/**
 * BLE 直连数据源 —— 实现 HealthSource，从蓝牙健康设备读数据。
 *
 * ## 能读到什么（取决于设备暴露什么）
 *   · 心率（0x180D / 0x2A37）—— 支持标准心率服务的设备，实时订阅
 *   · 血氧（0x1822 / 0x2A5E）—— 少数设备有
 *   · 电量（0x180F / 0x2A19）—— 用来判断设备是否还在线
 *
 * ## 明确读不到什么（不要期待）
 *   睡眠分期、HRV、压力、静息心率 —— 这些需要设备端算法产出，
 *   标准 GATT 里没有对应服务。华为手表把这些放在厂商私有通道，
 *   第三方应用通过 BLE 读不到，只能走 Health Service Kit（需审批）。
 *
 * 所以本实现的定位是：**把能拿到的真实数据拿全，把拿不到的如实说明**，
 * 而不是假装能拿到。
 */

import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';
import { AppPrefs, KEYS } from '../common/Prefs';
import { HealthMetric, SamplePayload } from '../model/HealthTypes';
import {
  BleClient,
  BleConnectionState,
  DiscoveredDevice,
  DiscoveredService,
  parseBatteryLevel,
  parseHeartRateMeasurement,
  parseSpo2Measurement,
  shortUuid,
  toHex
} from '../ble/BleClient';
import { HealthSource, HealthSourceInitResult, HealthSourceStatus } from './HealthSource';

const TAG = 'BleHealthSource';

/**
 * 扫描时优先过滤的服务。注意这是"过滤条件"，不是"必须支持"——
 * 有些设备不在广播里带服务 UUID，所以提供"扫全部"的开关。
 */
export const BLE_HEALTH_SERVICE_FILTER: string[] = ['180D', '1822', '1810', '1809'];

/**
 * 心率值的有效性下限/上限（次分）。
 * 用于滤掉某些设备在未佩戴时上报的 0 或异常值。
 */
const HR_MIN_VALID = 20;
const HR_MAX_VALID = 250;

/**
 * 相邻两个心率点之间的最小间隔。
 * 心率设备常常每秒推好几次，全发出去会把电脑端的缓冲刷满、也没意义。
 * 官方也建议采集间隔 ≥ 1 分钟（对后台长时任务友好），这里对"实时订阅"
 * 放宽到 5 秒，兼顾实时曲线与流量。
 */
const HR_MIN_PUBLISH_INTERVAL_MS = 5000;

export class BleHealthSource implements HealthSource {
  readonly name = 'BLE 直连';

  private client: BleClient = new BleClient();
  private inited: boolean = false;
  private initMessage: string = '未初始化';
  private running: boolean = false;

  private sampleHandler: ((payload: SamplePayload) => void) | null = null;

  /** 最近一次各指标的值，syncOnce() 用它返回 */
  private latest: Map<string, SamplePayload> = new Map();
  private latestHeartRate: number = 0;
  private lastPublishAt: number = 0;
  private lastDataAt: number = 0;
  private batteryLevel: number = -1;
  private connectedName: string = '';
  private statusText: string = '未连接';

  // ------------------------------------------------------------ 生命周期

  async init(): Promise<HealthSourceInitResult> {
    if (this.inited) {
      return { ready: true, message: this.initMessage };
    }

    this.client.setEvents({
      onDeviceFound: (d: DiscoveredDevice) => {
        // 扫描结果由扫描页消费，这里不处理
      },
      onConnectionChange: (state: BleConnectionState, deviceId: string) => {
        this.statusText = this.describeState(state);
        Logger.info(TAG, `连接状态：${this.statusText}`);
      },
      onServices: (services: DiscoveredService[]) => {
        const known = services.filter((s) => s.isKnown);
        Logger.info(TAG, `发现 ${services.length} 个服务，其中认识 ${known.length} 个`);
        for (const s of services) {
          Logger.info(TAG, `  服务 ${s.serviceUuid} ${s.serviceName}`);
          for (const c of s.characteristics) {
            Logger.info(TAG, `    特征 ${c.characteristicUuid} ${c.characteristicName} [${c.properties.join('/')}]${c.subscribed ? ' 已订阅' : ''}`);
          }
        }
        // 连接后检查有没有可用的健康服务，没有就明确告知用户
        this.warnIfNoHealthService(services);
      },
      onCharacteristicValue: (serviceUuid: string, charUuid: string, value: Uint8Array) => {
        this.handleCharacteristic(serviceUuid, charUuid, value);
      },
      onError: (message: string) => {
        this.statusText = message;
        Logger.warn(TAG, message);
      }
    });

    if (!this.client.isBluetoothOn()) {
      this.inited = true;
      this.initMessage = '蓝牙未打开：请先在系统设置里打开蓝牙';
      Logger.warn(TAG, this.initMessage);
      return { ready: true, message: this.initMessage };
    }

    this.inited = true;
    this.initMessage = 'BLE 已就绪';
    Logger.info(TAG, this.initMessage);
    return { ready: true, message: this.initMessage };
  }

  isReady(): boolean {
    return this.inited;
  }

  getInitMessage(): string {
    return this.initMessage;
  }

  /**
   * 开始采集。
   *
   * 设计要点：BLE 必须先连上具体设备才能采。但用户上一次连过的设备会被记在偏好存储里，
   * 而蓝牙连接在**退后台/设备休眠/超时**后经常悄悄断开。这时如果直接报失败，
   * 用户必须手动跑去「蓝牙设备」页重连 —— 体验很差，而且容易被误判成"坏了"。
   *
   * 所以这里做**自动重连**：没连上但有上次的设备地址，就先尝试连回去，成功则直接开始采集。
   */
  async start(): Promise<HealthSourceInitResult> {
    if (!this.inited) {
      await this.init();
    }
    if (!this.client.isBluetoothOn()) {
      return { ready: false, message: '蓝牙未打开，无法开始采集' };
    }

    // 尚未连接 → 尝试自动重连上次的设备
    if (this.client.state !== 'connected') {
      const lastId = AppPrefs.getString(KEYS.bleDeviceId, '');
      if (lastId.length > 0) {
        Logger.info(TAG, `检测到未连接，尝试自动重连上次设备 ${lastId}`);
        this.statusText = '正在自动重连上次的设备…';
        const ok = await this.client.connect(lastId);
        if (!ok) {
          return {
            ready: false,
            message: '自动重连上次设备失败。请到「蓝牙设备」页重新扫描并连接（臂带要戴在皮肤上、别被其他 App 占用）'
          };
        }
        Logger.info(TAG, '自动重连成功');
      } else {
        return { ready: false, message: '尚未连接蓝牙设备，请先在「蓝牙设备」页连接你的手表/手环/心率带' };
      }
    }

    this.running = true;
    this.statusText = '采集中';
    Logger.info(TAG, `开始采集，设备=${this.connectedName || this.client.currentDeviceId}`);
    return { ready: true, message: 'BLE 采集已启动' };
  }

  async stop(): Promise<void> {
    this.running = false;
    this.statusText = '已停止';
    Logger.info(TAG, '已停止采集（保留蓝牙连接，方便快速恢复）');
  }

  /** 断开蓝牙连接（退出应用/用户主动断开时调） */
  async disconnectDevice(): Promise<void> {
    this.running = false;
    this.latest.clear();
    this.latestHeartRate = 0;
    await this.client.disconnect();
    this.statusText = '未连接';
  }

  isRunning(): boolean {
    return this.running;
  }

  // ------------------------------------------------------------ 采样

  async syncOnce(): Promise<SamplePayload[]> {
    const out: SamplePayload[] = [];
    for (const p of this.latest.values()) {
      out.push(p);
    }
    if (out.length === 0) {
      Logger.info(TAG, '手动同步：暂无可发送的数据（设备还没上报过）');
    }
    return out;
  }

  onSample(handler: (payload: SamplePayload) => void): void {
    this.sampleHandler = handler;
  }

  getStatus(): HealthSourceStatus {
    const metrics: HealthMetric[] = [];
    for (const key of this.latest.keys()) {
      metrics.push(key as HealthMetric);
    }
    return {
      stateText: this.statusText,
      deviceName: this.connectedName,
      activeMetrics: metrics,
      lastDataAt: this.lastDataAt
    };
  }

  // ------------------------------------------------------------ 给 UI 用的透传

  getClient(): BleClient {
    return this.client;
  }

  /** 扫描页需要用这个来更新设备列表 */
  scan(aggressive: boolean = false): void {
    this.client.clearDeviceList();
    this.client.startScan(BLE_HEALTH_SERVICE_FILTER, aggressive);
  }

  /** 扫全部设备（有些设备不在广播里带服务 UUID，过滤会漏掉它们） */
  scanAll(): void {
    this.client.clearDeviceList();
    this.client.startScan([], false);
  }

  stopScan(): void {
    this.client.stopScan();
  }

  async connect(device: DiscoveredDevice): Promise<boolean> {
    this.connectedName = device.name;
    const ok = await this.client.connect(device.deviceId);
    if (ok) {
      this.statusText = `已连接 ${device.name}`;
    }
    return ok;
  }

  async disconnect(): Promise<void> {
    await this.disconnectDevice();
  }

  isConnected(): boolean {
    return this.client.state === 'connected';
  }

  getBatteryLevel(): number {
    return this.batteryLevel;
  }

  // ------------------------------------------------------------ 内部：解析特征值

  private handleCharacteristic(serviceUuid: string, charUuid: string, value: Uint8Array): void {
    const svc = shortUuid(serviceUuid);
    const chr = shortUuid(charUuid);
    const hex = toHex(value);
    Logger.info(TAG, `收到 ${svc}/${chr} = ${hex}`);

    this.lastDataAt = Date.now();

    // 心率
    if (svc === '180D' && chr === '2A37') {
      const hr = parseHeartRateMeasurement(value);
      if (hr === null) return;
      if (hr < HR_MIN_VALID || hr > HR_MAX_VALID) {
        // 未佩戴时很多设备上报 0，直接忽略，避免污染曲线
        Logger.info(TAG, `心率 ${hr} 超出合理范围，忽略（可能是未佩戴）`);
        return;
      }
      this.latestHeartRate = hr;
      this.publishHeartRate(value.length, true);
      return;
    }

    // 血氧
    if (svc === '1822' && (chr === '2A5E' || chr === '2A5F')) {
      const spo2 = parseSpo2Measurement(value);
      if (spo2 === null) return;
      const now = Date.now();
      const payload: SamplePayload = {
        metric: 'spo2',
        value: spo2,
        unit: '%',
        startTime: now - 1000,
        endTime: now,
        source: 'ble'
      };
      this.publish(payload);
      return;
    }

    // 电量：不当作健康指标上报，只用于 UI 显示设备是否还活着
    if (svc === '180F' && chr === '2A19') {
      const b = parseBatteryLevel(value);
      if (b !== null) {
        this.batteryLevel = b;
        Logger.info(TAG, `设备电量 ${b}%`);
      }
      return;
    }

    // 其它特征只记录，不上报（我们不知道语义，不能瞎编指标）
    Logger.info(TAG, `未识别的特征 ${svc}/${chr}，仅记录原始值`);
  }

  /**
   * 心率有节流：设备可能每秒推多次，只在间隔够了才上报。
   * 但 UI 的"最近值"始终更新，所以手动同步时拿到的是最新值。
   */
  private publishHeartRate(rawLength: number, fromNotify: boolean): void {
    const now = Date.now();
    if (now - this.lastPublishAt < HR_MIN_PUBLISH_INTERVAL_MS) {
      return;
    }
    this.lastPublishAt = now;
    const payload: SamplePayload = {
      metric: 'heart_rate',
      value: this.latestHeartRate,
      unit: 'bpm',
      startTime: now - 1000,
      endTime: now,
      source: 'ble'
    };
    this.publish(payload);
  }

  private publish(payload: SamplePayload): void {
    this.latest.set(payload.metric, payload);
    if (this.running && this.sampleHandler !== null) {
      this.sampleHandler(payload);
    }
  }

  /**
   * 连上之后如果没发现任何认识的健康服务，明确告诉用户，
   * 并说明这意味着什么 —— 而不是让它静静地不工作。
   */
  private warnIfNoHealthService(services: DiscoveredService[]): void {
    // mapServices() 已把 serviceUuid 归一成短码，这里直接比短码即可
    const hasHr = services.some((s) => s.serviceUuid === '180D');
    if (hasHr) {
      Logger.info(TAG, '发现标准心率服务（0x180D），心率可以实时读取');
      return;
    }
    const knownList = services.filter((s) => s.isKnown).map((s) => s.serviceUuid);
    const unknownList = services.filter((s) => !s.isKnown).map((s) => s.serviceUuid);
    const msg =
      '该设备没有暴露标准心率服务（0x180D）。' +
      `认识的服务：[${knownList.join(', ') || '无'}]，` +
      `私有服务：[${unknownList.join(', ') || '无'}]。` +
      '这说明厂商把健康数据放在私有协议里，第三方应用通过 BLE 读不到，' +
      '只能改用厂商 App 或华为 Health Service Kit。';
    this.statusText = '设备无标准健康服务';
    Logger.warn(TAG, msg);
  }

  private describeState(state: BleConnectionState): string {
    switch (state) {
      case 'connecting':
        return '正在连接…';
      case 'connected':
        return '已连接';
      case 'disconnected':
        return '已断开';
      default:
        return '未连接';
    }
  }
}
