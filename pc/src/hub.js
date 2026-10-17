'use strict';
/**
 * HealthLink Hub —— 电脑端核心。
 *
 * 职责：
 *   1. 接收手机上行（hello / sample / batch / ping / ack），维护设备注册表
 *   2. 写入环形缓冲，供断线重连后按 seq 重放
 *   3. 把样本实时推送给所有下游订阅者（面板 / 第三方程序）
 *   4. 为 REST 查询提供检索能力
 *   5. 通过事件把样本广播给转发器（relay.js）
 *
 * 设计原则：Hub 不认识 WebSocket，只认识"连接对象"这个概念。
 *   连接对象需要提供 sendJson(obj) / close(code, reason) / context。
 *   这样测试时可以塞假连接进去，不需要真的开端口。
 */

const { EventEmitter } = require('events');
const { SampleBuffer } = require('./storage');

const PROTOCOL_VERSION = 1;

/** 允许的指标白名单（与 docs/protocol/README.md 3.5 节一致） */
const KNOWN_METRICS = new Set([
  'heart_rate',
  'resting_heart_rate',
  'hrv',
  'spo2',
  'stress',
  'sleep',
  'sleep_nap',
  'body_temperature',
  'heart_rate_series'
]);

function nowMs() {
  return Date.now();
}

function hexPreview(id, head = 8) {
  if (typeof id !== 'string' || id.length <= head) return id;
  return `${id.slice(0, head)}…`;
}

class Hub extends EventEmitter {
  /**
   * @param {object} options
   * @param {object} options.config 见 config.js
   * @param {object} [options.logger]
   */
  constructor(options = {}) {
    super();
    this.config = options.config || {};
    this.log = options.logger || createConsoleLogger(this.config.logLevel);
    this.buffer = new SampleBuffer(this.config.bufferCapacity || 20000);
    this.startedAt = nowMs();

    /** @type {Map<string, object>} deviceId -> 设备状态 */
    this.devices = new Map();
    /** @type {Set<object>} 订阅者连接 */
    this.subscribers = new Set();

    this.stats = {
      samplesReceived: 0,
      batchesReceived: 0,
      bytesReceived: 0,
      rejected: 0,
      replayed: 0,
      pushedToSubscribers: 0
    };
  }

  // ============================================================ 设备接入

  /**
   * 处理 /ingest 连接建立。返回一个"待 hello"的会话对象。
   * @param {object} conn WebSocket 连接
   * @param {string} remoteAddress
   */
  attachIngest(conn, remoteAddress) {
    const session = {
      id: `ing-${Math.random().toString(16).slice(2, 10)}`,
      deviceId: null,
      greeted: false,
      remoteAddress,
      connectedAt: nowMs(),
      conn
    };
    conn.context.session = session;
    return session;
  }

  /**
   * 处理一条上行消息（已 JSON.parse 的 Envelope）。
   * @returns {{ok: boolean, error?: string}}
   */
  handleIngestMessage(session, envelope) {
    if (!envelope || typeof envelope !== 'object') {
      return this._reject(session, 'malformed', '消息不是 JSON 对象');
    }
    if (envelope.v !== undefined && envelope.v !== PROTOCOL_VERSION) {
      return this._reject(session, 'unsupported_version', `不支持的协议版本 v=${envelope.v}`);
    }
    const type = envelope.type;
    if (!type) return this._reject(session, 'malformed', '缺少 type 字段');

    if (type !== 'hello' && !session.greeted) {
      return this._reject(session, 'handshake_required', '首条消息必须是 hello');
    }

    switch (type) {
      case 'hello':
        return this._handleHello(session, envelope);
      case 'sample':
        return this._handleSample(session, envelope);
      case 'batch':
        return this._handleBatch(session, envelope);
      case 'ping':
        session.conn.sendJson(makeEnvelope('pong', 0, session.deviceId, { echo: envelope.ts || nowMs() }));
        return { ok: true };
      case 'ack':
        // 手机确认收到电脑的下行；目前只需记录，不做重传
        return { ok: true };
      case 'nack':
        this.log.warn(`设备 ${hexPreview(session.deviceId)} 回报 nack: ${JSON.stringify(envelope.payload)}`);
        return { ok: true };
      default:
        return this._reject(session, 'unknown_type', `未知消息类型 ${type}`);
    }
  }

  _handleHello(session, envelope) {
    const deviceId = envelope.deviceId;
    if (!deviceId || typeof deviceId !== 'string' || deviceId.length < 8) {
      return this._reject(session, 'bad_device_id', 'deviceId 缺失或过短');
    }
    const payload = envelope.payload || {};

    // 同一 deviceId 重复连接：踢掉旧连接，保留新连接（见契约第 5 节）
    const existing = this.devices.get(deviceId);
    if (existing && existing.conn && existing.conn !== session.conn && existing.conn.writable) {
      this.log.warn(`设备 ${hexPreview(deviceId)} 重复连接，踢掉旧连接`);
      existing.conn.context.replaced = true;
      existing.conn.close(4409, 'replaced by a newer connection');
    }

    const device = existing || {
      deviceId,
      firstSeen: nowMs(),
      samplesReceived: 0
    };
    const previousLastSeq = device.lastSeq || 0;
    const deviceClaimedLastSeq = Number(payload.lastSeq);
    const hasClaim = Number.isFinite(deviceClaimedLastSeq) && deviceClaimedLastSeq >= 0;

    let needBackfillFrom = -1;
    if (hasClaim && deviceClaimedLastSeq > previousLastSeq) {
      // 手机在断线期间继续采集了：请求补传 (previousLastSeq, deviceClaimedLastSeq]
      needBackfillFrom = previousLastSeq + 1;
    }

    device.deviceId = deviceId;
    device.online = true;
    device.connectedAt = nowMs();
    device.lastSeen = nowMs();
    device.remoteAddress = session.remoteAddress;
    device.conn = session.conn;
    device.hello = {
      model: payload.model,
      osVersion: payload.osVersion,
      appVersion: payload.appVersion,
      collectIntervalMs: payload.collectIntervalMs,
      backgroundMode: payload.backgroundMode,
      healthStoreReady: payload.healthStoreReady,
      permissions: payload.permissions,
      protocol: payload.protocol
    };
    device.lastSeq = hasClaim ? deviceClaimedLastSeq : (device.lastSeq || 0);
    device.session = session;
    this.devices.set(deviceId, device);
    session.deviceId = deviceId;
    session.greeted = true;

    session.conn.sendJson(
      makeEnvelope('hello_ack', 0, deviceId, {
        serverTime: nowMs(),
        accepted: true,
        needBackfillFrom,
        collectIntervalMs: payload.collectIntervalMs || this.config.defaultCollectIntervalMs || 60000,
        metrics: Array.from(KNOWN_METRICS)
      })
    );

    const wasOffline = existing ? existing.online === false : false;
    this.log.info(
      `设备上线 ${hexPreview(deviceId)} 机型=${payload.model || '未知'} ` +
        `lastSeq=${device.lastSeq} 需补传自=${needBackfillFrom}`
    );
    if (!existing || wasOffline) {
      this.broadcastDeviceEvent(deviceId, 'online', { model: payload.model, backgroundMode: payload.backgroundMode });
    }
    return { ok: true };
  }

  _handleSample(session, envelope) {
    const sample = this._normalizeSample(envelope, session.deviceId);
    if (!sample.ok) return this._reject(session, sample.error, sample.message);

    const device = this.devices.get(session.deviceId);
    if (device) {
      device.lastSeen = nowMs();
      device.samplesReceived++;
      if (Number.isFinite(Number(envelope.seq))) device.lastSeq = Number(envelope.seq);
    }
    this._ingestSample(sample.record);
    session.conn.sendJson(makeEnvelope('ack', 0, session.deviceId, { ackSeq: envelope.seq }));
    return { ok: true };
  }

  _handleBatch(session, envelope) {
    const payload = envelope.payload || {};
    const list = Array.isArray(payload.samples) ? payload.samples : null;
    if (!list) return this._reject(session, 'bad_batch', 'batch.payload.samples 必须是数组');
    if (list.length > 5000) return this._reject(session, 'bad_batch', 'batch 单批超过 5000 条');

    const accepted = [];
    let rejectedCount = 0;
    for (const raw of list) {
      const normalized = this._normalizeSample({ seq: envelope.seq, ts: envelope.ts, payload: raw }, session.deviceId);
      if (normalized.ok) accepted.push(normalized.record);
      else rejectedCount++;
    }

    // 补传顺序可能乱，按数据点时间升序入库（契约 3.3 节要求）
    accepted.sort((a, b) => (a.payload.startTime || a.ts) - (b.payload.startTime || b.ts));

    const device = this.devices.get(session.deviceId);
    if (device) {
      device.lastSeen = nowMs();
      if (Number.isFinite(Number(envelope.seq))) device.lastSeq = Number(envelope.seq);
    }

    this.stats.batchesReceived++;
    let delivered = 0;
    for (const record of accepted) delivered += this._ingestSample(record) ? 1 : 0;
    device && (device.samplesReceived += delivered);

    this.log.info(
      `收到补传批次 ${hexPreview(session.deviceId)} 条数=${list.length} 接受=${delivered} ` +
        `拒绝=${rejectedCount} 原因=${payload.reason || '未说明'}`
    );
    session.conn.sendJson(
      makeEnvelope('ack', 0, session.deviceId, {
        ackSeq: envelope.seq,
        accepted: delivered,
        rejected: rejectedCount
      })
    );
    return { ok: true };
  }

  /** 归一化 + 校验一条样本 */
  _normalizeSample(envelope, deviceId) {
    const p = envelope.payload;
    if (!p || typeof p !== 'object') return { ok: false, error: 'malformed', message: 'payload 缺失' };
    if (typeof p.metric !== 'string') return { ok: false, error: 'malformed', message: 'metric 缺失' };
    if (!KNOWN_METRICS.has(p.metric)) {
      return { ok: false, error: 'unknown_metric', message: `未知指标 ${p.metric}` };
    }
    const isComposite = p.metric === 'sleep' || p.metric === 'sleep_nap';
    if (!isComposite && p.value !== null && !Number.isFinite(Number(p.value))) {
      return { ok: false, error: 'malformed', message: `value 不是数值: ${p.value}` };
    }
    if (isComposite && (!p.sleep || typeof p.sleep !== 'object')) {
      return { ok: false, error: 'malformed', message: `${p.metric} 必须带 sleep 对象` };
    }
    return {
      ok: true,
      record: {
        seq: Number(envelope.seq) || 0,
        ts: Number(envelope.ts) || nowMs(),
        deviceId,
        receivedAt: nowMs(),
        payload: p
      }
    };
  }

  /** 真正落缓冲 + 推订阅者 + 触发转发。@returns {boolean} 是否入库 */
  _ingestSample(record) {
    const stored = this.buffer.push(record);
    this.stats.samplesReceived++;

    // 每台设备每个指标只留最新一条，供设备卡片直接展示
    const device = this.devices.get(record.deviceId);
    if (device) {
      device.latest = device.latest || {};
      device.latest[record.payload.metric] = {
        value: record.payload.value,
        unit: record.payload.unit,
        startTime: record.payload.startTime,
        endTime: record.payload.endTime,
        source: record.payload.source,
        receivedAt: record.receivedAt,
        sleep: record.payload.sleep || null
      };
    }

    this.emit('sample', stored);
    this.pushToSubscribers(stored);
    return true;
  }

  // ============================================================ 本机设备（无连接）

  /**
   * 注册一台"本机直连"设备（不通过 WebSocket 连接）。
   *
   * 用途：PC 蓝牙桥（pc/ble/）让电脑直接把心率设备接进服务端。
   * 这种设备没有 WebSocket 会话，所以走这条路径注册 —— 但注册之后，
   * 设备列表、面板、订阅者推送、转发全都和普通设备一视同仁。
   *
   * @param {string} deviceId 设备标识（本机桥用固定 ID，保证重启后仍是同一台）
   * @param {object} meta     展示信息（model / sourceKind 等）
   */
  registerLocalDevice(deviceId, meta = {}) {
    if (!deviceId || deviceId.length < 8) {
      throw new Error('deviceId 缺失或过短');
    }
    const existing = this.devices.get(deviceId);
    const device = existing || {
      deviceId,
      firstSeen: nowMs(),
      samplesReceived: 0
    };
    const wasOffline = existing ? existing.online === false : false;

    device.deviceId = deviceId;
    device.online = true;
    device.connectedAt = device.connectedAt || nowMs();
    device.lastSeen = nowMs();
    device.remoteAddress = 'local';
    device.conn = null;                 // 没有连接
    device.local = true;                // 标记为"本机设备"，便于 UI 区分
    device.localKind = meta.localKind || 'ble-bridge';
    device.hello = Object.assign({}, device.hello, {
      model: meta.model || '本机蓝牙设备',
      appVersion: meta.appVersion || 'pc-ble-bridge',
      protocol: PROTOCOL_VERSION,
      localDevice: true
    });
    device.lastSeq = device.lastSeq || 0;
    this.devices.set(deviceId, device);

    this.log.info(`本机设备已注册 ${hexPreview(deviceId)} 类型=${device.localKind} 名称=${meta.model || '-'}`);
    if (!existing || wasOffline) {
      this.broadcastDeviceEvent(deviceId, 'online', { model: meta.model, localDevice: true });
    }
    return device;
  }

  /**
   * 注入一条来自"本机设备"的样本。
   *
   * 与 WebSocket 路径共用 _normalizeSample（所以校验规则完全一致），
   * 落库后自然会被订阅者收到、被转发目标转发。
   *
   * @returns {{ok:boolean, error?:string, message?:string}}
   */
  ingestLocalSample(deviceId, payload, seq) {
    const envelope = {
      seq: Number.isFinite(Number(seq)) ? Number(seq) : 0,
      ts: nowMs(),
      payload
    };
    const normalized = this._normalizeSample(envelope, deviceId);
    if (!normalized.ok) return normalized;

    const device = this.devices.get(deviceId);
    if (!device) return { ok: false, error: 'no_device', message: `设备 ${deviceId} 未注册` };

    device.lastSeen = nowMs();
    device.lastSeq = normalized.record.seq || device.lastSeq;
    device.samplesReceived = (device.samplesReceived || 0) + 1;
    this._ingestSample(normalized.record);
    return { ok: true, record: normalized.record };
  }

  /** 本机设备下线（桥退出时调用） */
  unregisterLocalDevice(deviceId, reason) {
    const device = this.devices.get(deviceId);
    if (!device) return;
    device.online = false;
    device.conn = null;
    this.log.info(`本机设备离线 ${hexPreview(deviceId)} 原因=${reason || '未知'}`);
    this.broadcastDeviceEvent(deviceId, 'offline', { reason, localDevice: true });
  }

  /** 设备断开 */
  detachIngest(session, code, reason) {
    const deviceId = session && session.deviceId;
    if (!deviceId) return;
    const device = this.devices.get(deviceId);
    if (!device) return;
    // 只有"当前连接"断开才标离线；被新连接顶掉的旧连接不应该把设备标成离线
    if (device.conn !== session.conn) return;
    device.online = false;
    device.lastSeen = device.lastSeen || nowMs();
    device.disconnectedAt = nowMs();
    device.conn = null;
    this.log.info(`设备离线 ${hexPreview(deviceId)} code=${code} reason=${reason || ''}`);
    this.broadcastDeviceEvent(deviceId, 'offline', { code, reason });
  }

  // ============================================================ 订阅者

  /**
   * 注册一个下游订阅者。
   * @param {object} conn 连接
   * @param {object} options
   * @param {number} options.since 从此 seq 之后开始重放；0 表示不重放
   * @param {string} options.topic
   */
  attachSubscriber(conn, options = {}) {
    const sub = {
      id: `sub-${Math.random().toString(16).slice(2, 10)}`,
      conn,
      since: Number(options.since) || 0,
      topic: options.topic || 'health',
      deviceIds: [],
      metrics: [],
      connectedAt: nowMs(),
      sent: 0
    };
    conn.context.subscriber = sub;
    this.subscribers.add(sub);

    let replayed = 0;
    let gap = null;
    if (sub.since > 0) {
      // 用**业务 seq** 定位（不是内部 order）：
      // 订阅者的 since 是发送方的 seq 空间，与缓冲的内部插入序号不是一回事。
      // 详见 storage.replaySinceSeq 的注释。
      const result = this.buffer.replaySinceSeq(
        sub.since,
        (rec) => {
          if (!this._subscriberAccepts(sub, rec)) return;
          conn.sendJson(makeEnvelope('sample', rec.seq, rec.deviceId, rec.payload));
          sub.sent++;
          this.stats.replayed++;
        },
        (gapInfo) => {
          gap = gapInfo;
          // gap 必须**先于**重放数据到达：这里在回调里立刻发，
          // 而 replaySinceSeq 是先算出 gap 再遍历，所以顺序天然正确。
          conn.sendJson(makeEnvelope('gap', 0, '*', gapInfo));
        }
      );
      replayed = result.replayed;
      gap = result.gap;
    }

    conn.sendJson(
      makeEnvelope('subscribed', 0, '*', {
        topic: sub.topic,
        replayed,
        live: true,
        gap,
        devices: Array.from(this.devices.keys())
      })
    );
    this.log.info(`订阅者接入 ${sub.id} since=${sub.since} 重放=${replayed} 缺口=${gap ? gap.lost : 0}`);
    return sub;
  }

  detachSubscriber(sub) {
    if (!sub) return;
    this.subscribers.delete(sub);
    this.log.info(`订阅者断开 ${sub.id} 本次共推送 ${sub.sent} 条`);
  }

  _subscriberAccepts(sub, record) {
    if (sub.deviceIds.length && !sub.deviceIds.includes(record.deviceId)) return false;
    if (sub.metrics.length && !sub.metrics.includes(record.payload.metric)) return false;
    return true;
  }

  /** 处理订阅者发来的控制消息 */
  handleSubscriberMessage(sub, envelope) {
    if (!envelope || typeof envelope !== 'object') return { ok: false, error: 'malformed' };
    switch (envelope.type) {
      case 'subscribe_filter': {
        const p = envelope.payload || {};
        sub.deviceIds = Array.isArray(p.deviceIds) ? p.deviceIds : [];
        sub.metrics = Array.isArray(p.metrics) ? p.metrics : [];
        sub.conn.sendJson(
          makeEnvelope('subscribed', 0, '*', {
            topic: sub.topic,
            replayed: 0,
            live: true,
            devices: Array.from(this.devices.keys())
          })
        );
        return { ok: true };
      }
      case 'query': {
        const p = envelope.payload || {};
        const result = this.buffer.query({
          deviceIds: p.deviceIds || [],
          metrics: p.metrics || [],
          startTime: p.startTime,
          endTime: p.endTime,
          limit: p.limit || 500,
          order: 'asc'
        });
        sub.conn.sendJson(
          makeEnvelope('query_result', 0, '*', {
            requestId: p.requestId || null,
            samples: result.samples.map((r) => r.payload),
            truncated: result.truncated
          })
        );
        return { ok: true };
      }
      case 'ping':
        sub.conn.sendJson(makeEnvelope('pong', 0, '*', { echo: envelope.ts || nowMs() }));
        return { ok: true };
      default:
        sub.conn.sendJson(makeEnvelope('nack', 0, '*', { reason: 'unknown_type', detail: envelope.type }));
        return { ok: false, error: 'unknown_type' };
    }
  }

  pushToSubscribers(record) {
    for (const sub of this.subscribers) {
      if (!this._subscriberAccepts(sub, record)) continue;
      if (!sub.conn.writable) continue;
      sub.conn.sendJson(makeEnvelope('sample', record.seq, record.deviceId, record.payload));
      sub.sent++;
      this.stats.pushedToSubscribers++;
    }
  }

  broadcastDeviceEvent(deviceId, event, extra = {}) {
    const env = makeEnvelope('device_event', 0, deviceId, { event, ...extra });
    for (const sub of this.subscribers) {
      if (!sub.conn.writable) continue;
      sub.conn.sendJson(env);
    }
    this.emit('device_event', { deviceId, event, ...extra });
  }

  // ============================================================ 查询

  /** 设备列表（含在线判定） */
  listDevices() {
    const now = nowMs();
    const offlineAfter = this.config.offlineAfterMs || 120000;
    return Array.from(this.devices.values()).map((d) => ({
      deviceId: d.deviceId,
      online: Boolean(d.online && d.conn && d.conn.writable) || now - (d.lastSeen || 0) <= offlineAfter,
      firstSeen: d.firstSeen,
      lastSeen: d.lastSeen || d.firstSeen,
      connectedAt: d.connectedAt || null,
      disconnectedAt: d.disconnectedAt || null,
      remoteAddress: d.remoteAddress || null,
      hello: d.hello || null,
      lastSeq: d.lastSeq || 0,
      samplesReceived: d.samplesReceived || 0,
      latest: d.latest || {}
    }));
  }

  getLatestMap() {
    const out = {};
    for (const d of this.devices.values()) out[d.deviceId] = d.latest || {};
    return out;
  }

  querySamples(filter) {
    const max = this.config.maxQueryLimit || 1000;
    const limit = Math.min(Number(filter.limit) || 100, max);
    return this.buffer.query({ ...filter, limit });
  }

  statsSnapshot() {
    const devices = Array.from(this.devices.values());
    const offlineAfter = this.config.offlineAfterMs || 120000;
    const now = nowMs();
    const online = devices.filter((d) => d.online && d.conn && d.conn.writable).length;
    return {
      uptimeMs: now - this.startedAt,
      startedAt: this.startedAt,
      devices: { total: devices.length, online },
      subscribers: { total: this.subscribers.size },
      ingest: {
        samples: this.stats.samplesReceived,
        bytes: this.stats.bytesReceived,
        batches: this.stats.batchesReceived,
        rejected: this.stats.rejected
      },
      buffer: {
        size: this.buffer.length,
        capacity: this.buffer.capacity,
        oldestSeq: this.buffer.oldestOrder,
        newestSeq: this.buffer.newestOrder,
        estimatedBytes: this.buffer.estimateBytes()
      },
      offlineAfterMs: offlineAfter,
      replayed: this.stats.replayed,
      pushedToSubscribers: this.stats.pushedToSubscribers
    };
  }

  _reject(session, reason, detail) {
    this.stats.rejected++;
    this.log.warn(`拒绝来自 ${hexPreview(session.deviceId || session.id)} 的消息: ${reason} - ${detail}`);
    if (session.conn && session.conn.writable) {
      session.conn.sendJson(makeEnvelope('nack', 0, session.deviceId, { reason, detail }));
    }
    return { ok: false, error: reason, message: detail };
  }
}

/** 构造协议信封 */
function makeEnvelope(type, seq, deviceId, payload) {
  return { v: PROTOCOL_VERSION, type, seq: seq || 0, ts: nowMs(), deviceId: deviceId || '*', payload: payload || {} };
}

function createConsoleLogger(level = 'info') {
  const levels = { debug: 10, info: 20, warn: 30, error: 40 };
  const threshold = levels[level] === undefined ? 20 : levels[level];
  const emit = (name, stream) => (...args) => {
    if (levels[name] < threshold) return;
    stream.write(`[${new Date().toISOString()}] [${name}] ${args.join(' ')}\n`);
  };
  return {
    level,
    debug: emit('debug', process.stdout),
    info: emit('info', process.stdout),
    warn: emit('warn', process.stderr),
    error: emit('error', process.stderr)
  };
}

module.exports = { Hub, makeEnvelope, createConsoleLogger, KNOWN_METRICS, PROTOCOL_VERSION };
