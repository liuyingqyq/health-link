/**
 * 局域网 WebSocket 传输实现。
 *
 * 关键行为（与 docs/protocol/README.md 第 7 节一致）：
 *   - 断线后 1s/2s/4s/8s/16s/30s 退避重连，上限 30s，永不放弃
 *   - 未连上时发出的信封进离线队列（有上限，超限丢最旧并计数）
 *   - 连上后先发 hello（带 lastSeq），再按电脑要求补传 batch
 *
 * 注意：手机端不能"监听"电脑连接（应用沙箱不允许后台监听入站连接），
 * 所以链路方向只能是手机主动外连电脑。
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

import { Logger } from '../common/Logger';
import { AppPrefs, KEYS } from '../common/Prefs';
import { Envelope, PingPayload, PongPayload, PROTOCOL_VERSION } from '../model/HealthTypes';
import { Transport, TransportEvents, TransportState } from './Transport';

const TAG = 'LanWsTransport';

/** 重连退避序列（毫秒），用完后固定取最后一个 */
const BACKOFF_MS: number[] = [1000, 2000, 4000, 8000, 16000, 30000];

/** 离线队列上限，超限丢最旧 */
const QUEUE_CAPACITY: number = 2000;

/** 应用层心跳周期 */
const PING_INTERVAL_MS: number = 30000;

export class LanWsTransport implements Transport {
  private ws: webSocket.WebSocket | null = null;
  private events: TransportEvents = {};
  private _state: TransportState = 'idle';
  private url: string = '';
  private attempt: number = 0;
  private reconnectTimer: number = -1;
  private pingTimer: number = -1;
  private manualClose: boolean = false;

  /**
   * 是否处于"已连接但握手未完成"状态。
   * 为 true 时 [flushQueue] 不放行积压数据，必须等收到 `hello_ack`。
   * 契约 3.1：手机必须在 hello 之后才开始发 sample。
   */
  private handshakePending: boolean = false;

  /** 离线队列：连接未就绪时暂存 */
  private queue: Envelope[] = [];
  private droppedCount: number = 0;
  private sentCount: number = 0;

  get state(): TransportState {
    return this._state;
  }

  get pendingCount(): number {
    return this.queue.length;
  }

  get dropped(): number {
    return this.droppedCount;
  }

  get sent(): number {
    return this.sentCount;
  }

  get endpoint(): string {
    return this.url;
  }

  setEvents(events: TransportEvents): void {
    this.events = events;
  }

  /** 用电脑端给的完整地址覆盖，例如 ws://192.168.1.5:18787/ingest?token=xxx */
  setUrl(url: string): void {
    this.url = url;
  }

  private setState(state: TransportState): void {
    if (this._state === state) return;
    this._state = state;
    if (this.events.onStateChange) {
      this.events.onStateChange(state);
    }
  }

  async connect(): Promise<void> {
    if (this._state === 'open' || this._state === 'connecting') return;
    if (!this.url || this.url.length === 0) {
      this.emitError('未配置电脑地址');
      return;
    }
    this.manualClose = false;
    this.setState('connecting');

    const ws = webSocket.createWebSocket();
    this.ws = ws;

    ws.on('open', (err: BusinessError, value: Object) => {
      if (err) {
        this.emitError(`open 事件异常: ${err.code} ${err.message}`);
        return;
      }
      this.attempt = 0;
      this.setState('open');
      // 新一轮连接必须先完成握手（收到 hello_ack），期间不放行积压队列，
      // 否则排队的 sample 会抢在 hello 之前发出，被电脑端按契约拒掉。
      this.handshakePending = true;
      Logger.info(TAG, `已连接 ${this.url}`);
      if (this.events.onOpen) this.events.onOpen();
      this.startPing();
      this.flushQueue();
    });

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err) {
        this.emitError(`message 事件异常: ${err.code} ${err.message}`);
        return;
      }
      if (typeof value !== 'string') {
        Logger.warn(TAG, '收到二进制帧，协议只使用文本帧，已忽略');
        return;
      }
      this.handleIncoming(value);
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      const code = value ? value.code : -1;
      const reason = value ? value.reason : '';
      Logger.warn(TAG, `连接关闭 code=${code} reason=${reason}`);
      this.stopPing();
      this.ws = null;
      // 复位握手标记：否则下次连接时连 hello 都会被闸门拦住，永远握不上手
      this.handshakePending = false;
      this.setState('closed');
      if (this.events.onClose) this.events.onClose(code, reason);
      if (!this.manualClose) this.scheduleReconnect();
    });

    ws.on('error', (err: BusinessError) => {
      this.emitError(`连接错误 code=${err.code} msg=${err.message}`);
    });

    try {
      await ws.connect(this.url);
    } catch (err) {
      const e = err as BusinessError;
      this.emitError(`连接失败 code=${e.code} msg=${e.message}`);
      // 同样复位，避免下次连接时 hello 被闸门拦住
      this.handshakePending = false;
      this.setState('closed');
      this.scheduleReconnect();
    }
  }

  async send(envelope: Envelope): Promise<void> {
    // hello 是握手的发起者，必须直发（否则会被下面的闸门拦住，永远完不成握手）
    if (envelope.type === 'hello') {
      if (this._state !== 'open' || this.ws === null) {
        this.enqueue(envelope);
        return;
      }
      await this.writeNow(envelope);
      return;
    }
    // ⚠️ 握手未完成时也要入队，不能直发。
    //    因为 state 在 open 事件里就被置为 'open'，此时 hello 还没被电脑端确认，
    //    直发会让 sample/batch 抢在 hello 之前到达（电脑端按契约回 handshake_required 丢掉）。
    if (this._state !== 'open' || this.ws === null || this.handshakePending) {
      this.enqueue(envelope);
      return;
    }
    await this.writeNow(envelope);
  }

  close(): void {
    this.manualClose = true;
    this.stopPing();
    this.clearReconnect();
    const ws = this.ws;
    this.ws = null;
    if (ws !== null) {
      ws.close().then(() => {
        Logger.info(TAG, '连接已主动关闭');
      }).catch((err: BusinessError) => {
        Logger.warn(TAG, `关闭连接失败 code=${err.code}`);
      });
    }
    this.setState('closed');
  }

  // ---------------------------------------------------------------- 内部

  private async writeNow(envelope: Envelope): Promise<void> {
    const ws = this.ws;
    if (ws === null) {
      this.enqueue(envelope);
      return;
    }
    try {
      await ws.send(JSON.stringify(envelope));
      this.sentCount++;
    } catch (err) {
      const e = err as BusinessError;
      this.emitError(`发送失败 code=${e.code} msg=${e.message}`);
      this.enqueue(envelope);
    }
  }

  private enqueue(envelope: Envelope): void {
    this.queue.push(envelope);
    while (this.queue.length > QUEUE_CAPACITY) {
      this.queue.shift();
      this.droppedCount++;
    }
  }

  /**
   * 连接建立后把积压的信封按顺序发出去。
   *
   * ⚠️ 必须等握手完成（收到 hello_ack）才放行：
   *   契约第 3.1 节要求「手机必须在 hello 之后才开始发 sample」。
   *   原来在 open 事件里直接 flush，而 onOpen 内部发 hello 是异步的（有 await），
   *   执行权会让出 → 排队的 sample 抢在 hello 之前发出 → 电脑端按契约回
   *   `nack handshake_required` 并丢掉这条数据（实测日志出现过这条拒绝）。
   */
  private flushQueue(): void {
    if (this.queue.length === 0) return;
    if (this.handshakePending) {
      Logger.info(TAG, `握手未完成，${this.queue.length} 条积压暂不发送（等 hello_ack）`);
      return;
    }
    const pending = this.queue;
    this.queue = [];
    Logger.info(TAG, `开始补发离线队列 ${pending.length} 条`);
    for (const envelope of pending) {
      // 逐条 await 会拖长函数，这里串行但不阻塞调用方
      this.writeNow(envelope).catch((e: Error) => {
        Logger.warn(TAG, `补发失败: ${e.message}`);
      });
    }
  }

  /**
   * 握手完成后放行积压队列。
   * 由 [handleIncoming] 收到 `hello_ack` 时自动调用。
   */
  private finishHandshake(): void {
    if (!this.handshakePending) return;
    this.handshakePending = false;
    Logger.info(TAG, '握手完成（收到 hello_ack），放行积压队列');
    this.flushQueue();
  }

  private handleIncoming(text: string): void {
    let envelope: Envelope;
    try {
      envelope = JSON.parse(text) as Envelope;
    } catch (err) {
      Logger.warn(TAG, '收到无法解析的消息，已忽略');
      return;
    }
    // 收到电脑的 ping 要回 pong（协议 3.6 / 4.2）
    if (envelope.type === 'ping') {
      const pongPayload: PongPayload = { echo: envelope.ts };
      const pong: Envelope = {
        v: PROTOCOL_VERSION,
        type: 'pong',
        seq: 0,
        ts: Date.now(),
        deviceId: AppPrefs.getString(KEYS.deviceId, ''),
        payload: pongPayload
      };
      this.writeNow(pong).catch(() => {
        Logger.warn(TAG, '回复 pong 失败');
      });
      return;
    }
    // 收到 hello_ack 表示握手完成，放行之前积压的离线数据
    if (envelope.type === 'hello_ack') {
      this.finishHandshake();
    }
    if (this.events.onMessage) this.events.onMessage(envelope);
  }

  private scheduleReconnect(): void {
    if (this.manualClose) return;
    if (this.reconnectTimer !== -1) return;
    const delay = BACKOFF_MS[Math.min(this.attempt, BACKOFF_MS.length - 1)];
    this.attempt++;
    Logger.info(TAG, `${delay}ms 后进行第 ${this.attempt} 次重连`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connect().catch((e: Error) => {
        Logger.warn(TAG, `重连调用失败: ${e.message}`);
      });
    }, delay);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      const deviceId = AppPrefs.getString(KEYS.deviceId, '');
      // 先构造具名类型的载荷变量：ArkTS 不允许把对象字面量直接塞给 payload
      const pingPayload: PingPayload = { rtt: null };
      const ping: Envelope = {
        v: PROTOCOL_VERSION,
        type: 'ping',
        seq: 0,
        ts: Date.now(),
        deviceId,
        payload: pingPayload
      };
      this.writeNow(ping).catch(() => {
        Logger.warn(TAG, '心跳发送失败');
      });
    }, PING_INTERVAL_MS);
  }

  private stopPing(): void {
    if (this.pingTimer !== -1) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  private emitError(message: string): void {
    Logger.error(TAG, message);
    if (this.events.onError) this.events.onError(message);
  }
}

/** 生成一个稳定的设备 ID：首次启动生成随机 16 字节的 hex，之后持久化复用 */
export function ensureDeviceId(): string {
  let id = AppPrefs.getString(KEYS.deviceId, '');
  if (id.length >= 16) return id;
  const bytes = util.generateRandomBinaryUUID(false);
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    const part = bytes[i].toString(16);
    hex += part.length === 1 ? `0${part}` : part;
  }
  id = hex;
  AppPrefs.put(KEYS.deviceId, id).catch(() => {
    Logger.warn(TAG, '设备 ID 持久化失败');
  });
  Logger.info(TAG, `已生成新的设备 ID: ${id}`);
  return id;
}
