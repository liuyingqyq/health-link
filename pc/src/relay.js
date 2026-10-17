'use strict';
/**
 * 转发器 —— 电脑端"把健康数据发给其他人"的实现。
 *
 * 这就是电脑端自己的"长加载 / 长时任务"等价物：
 *   - 每个目标维持一条常驻长连接（websocket）或定时推送（http）
 *   - 断线指数退避重连，不退出、不放弃
 *   - 发不出去就进本地队列，恢复后按顺序补发
 *   - 队列有上限，超限丢最旧并计数（避免内存无限增长拖垮整机）
 *
 * 数据流：Hub 每收到一条样本 emit('sample') → Matcher 过滤 → 目标队列 → 发送循环
 */

const fs = require('fs');
const path = require('path');
const { WsClient } = require('./wsclient');
const { stripBom } = require('./config');

const DEFAULT_QUEUE_CAPACITY = 20000;
const VALID_KINDS = new Set(['websocket', 'http']);

class ForwardTarget {
  constructor(spec, logger) {
    this.log = logger;
    this.spec = normalizeSpec(spec);
    this.queue = [];
    this.state = 'disabled';
    this.sentTotal = 0;
    this.failedTotal = 0;
    this.droppedTotal = 0;
    this.attempts = 0;
    this.lastError = null;
    this.lastSentAt = null;
    this.connectedAt = null;
    this.client = null;
    this._flushTimer = null;
    this._retryTimer = null;
    this._httpSending = false;
  }

  get id() {
    return this.spec.id;
  }

  get enabled() {
    return this.spec.enabled;
  }

  start() {
    if (!this.spec.enabled) {
      this.state = 'disabled';
      return;
    }
    if (this.spec.kind === 'websocket') this._connectWs();
    else this._startHttpTimer();
  }

  stop() {
    this._clearTimers();
    if (this.client) {
      try {
        this.client.close(1000, 'target stopped');
      } catch (_) {
        /* 忽略 */
      }
      this.client = null;
    }
    this.state = this.spec.enabled ? 'connecting' : 'disabled';
  }

  destroy() {
    this._clearTimers();
    if (this.client) {
      this.client.destroy();
      this.client = null;
    }
  }

  _clearTimers() {
    if (this._flushTimer) clearInterval(this._flushTimer);
    if (this._retryTimer) clearTimeout(this._retryTimer);
    this._flushTimer = null;
    this._retryTimer = null;
  }

  /** 是否关心这条样本 */
  matches(record) {
    if (this.spec.deviceIds.length && !this.spec.deviceIds.includes(record.deviceId)) return false;
    if (this.spec.metrics.length && !this.spec.metrics.includes(record.payload.metric)) return false;
    return true;
  }

  /** 入队。超限丢最旧。 */
  enqueue(record) {
    const env = {
      v: 1,
      type: 'sample',
      seq: record.seq,
      ts: record.ts,
      deviceId: record.deviceId,
      payload: record.payload
    };
    this.queue.push(env);
    while (this.queue.length > this.spec.queueCapacity) {
      this.queue.shift();
      this.droppedTotal++;
    }
    if (this.spec.kind === 'http') this._flushHttp();
  }

  /**
   * 接管另一个目标尚未发出的队列（配置更新时用，保证不丢数据）。
   * 超出本目标容量时丢最旧，并计入 droppedTotal。
   */
  adoptQueue(entries) {
    if (!entries || entries.length === 0) return;
    this.queue = entries.concat(this.queue);
    while (this.queue.length > this.spec.queueCapacity) {
      this.queue.shift();
      this.droppedTotal++;
    }
    if (this.spec.kind === 'http') this._flushHttp();
  }

  // ---------------------------------------------------------------- WebSocket

  _connectWs() {
    if (this.client) return;
    this.state = 'connecting';
    let client;
    try {
      client = new WsClient(this.spec.url, { connectTimeoutMs: 5000 });
    } catch (err) {
      this._onConnectFailure(err);
      return;
    }
    this.client = client;

    client.on('open', () => {
      this.state = 'connected';
      this.connectedAt = Date.now();
      this.attempts = 0;
      this.lastError = null;
      this.log.info(`转发目标 ${this.id} 已连接 ${this.spec.url}`);
      this._flushTimer = setInterval(() => this._flushWs(), Math.max(50, this.spec.batchMs || 1000));
      this._flushWs();
    });

    client.on('error', (err) => {
      this.lastError = err.message;
      this.log.warn(`转发目标 ${this.id} 连接错误: ${err.message}`);
    });

    client.on('close', (code, reason) => {
      this.connectedAt = null;
      if (this._flushTimer) clearInterval(this._flushTimer);
      this._flushTimer = null;
      this.client = null;
      if (!this.spec.enabled) {
        this.state = 'disabled';
        return;
      }
      this._onConnectFailure(new Error(`连接关闭 code=${code} ${reason || ''}`));
    });

    client.connect();
  }

  _onConnectFailure(err) {
    this.failedTotal++;
    this.lastError = err.message;
    if (!this.spec.enabled) {
      this.state = 'disabled';
      return;
    }
    const max = this.spec.retry.maxAttempts || 5;
    if (max > 0 && this.attempts >= max) {
      this.state = 'error';
      this.log.error(`转发目标 ${this.id} 重试 ${this.attempts} 次仍失败，停止重连（可用 /api/forward 重新启用）`);
      this.spec.enabled = false;
      return;
    }
    this.attempts++;
    const delay = Math.min(this.spec.retry.backoffMs * Math.pow(2, this.attempts - 1), 60000);
    this.state = 'backoff';
    this.log.warn(`转发目标 ${this.id} 将在 ${delay}ms 后第 ${this.attempts} 次重连`);
    this._retryTimer = setTimeout(() => {
      this._retryTimer = null;
      if (this.spec.enabled && !this.client) this._connectWs();
    }, delay);
    if (this._retryTimer.unref) this._retryTimer.unref();
  }

  _flushWs() {
    if (!this.client || this.state !== 'connected' || this.queue.length === 0) return;
    const batch = this.queue.splice(0, this.queue.length);
    if (this.spec.batchMs > 0 && batch.length > 1) {
      const error = this._sendWs(JSON.stringify({ v: 1, type: 'batch', ts: Date.now(), deviceId: '*', payload: { samples: batch.map((e) => e.payload), count: batch.length, reason: 'forward' } }));
      if (error) this._requeue(batch);
      return;
    }
    for (const env of batch) {
      const error = this._sendWs(JSON.stringify(env));
      if (error) {
        this._requeue(batch.slice(batch.indexOf(env)));
        return;
      }
    }
  }

  _sendWs(text) {
    try {
      const ok = this.client.send(text);
      if (!ok) return new Error('socket 不可写');
      this.sentTotal++;
      this.lastSentAt = Date.now();
      return null;
    } catch (err) {
      this.lastError = err.message;
      this.failedTotal++;
      return err;
    }
  }

  // ---------------------------------------------------------------- HTTP

  _startHttpTimer() {
    this.state = 'connected';
    this.connectedAt = Date.now();
    const interval = Math.max(200, this.spec.batchMs || 2000);
    this._flushTimer = setInterval(() => this._flushHttp(), interval);
    if (this._flushTimer.unref) this._flushTimer.unref();
  }

  async _flushHttp() {
    if (!this.spec.enabled || this._httpSending || this.queue.length === 0) return;
    this._httpSending = true;
    const batch = this.queue.splice(0, Math.min(this.queue.length, 500));
    try {
      await postJson(this.spec.url, {
        v: 1,
        type: 'batch',
        ts: Date.now(),
        deviceId: '*',
        payload: { samples: batch.map((e) => e.payload), count: batch.length, reason: 'forward' }
      });
      this.sentTotal += batch.length;
      this.lastSentAt = Date.now();
      this.lastError = null;
      this.state = 'connected';
    } catch (err) {
      this.lastError = err.message;
      this.failedTotal++;
      this.state = 'error';
      this._requeue(batch);
      // 失败不丢数据，等下一轮定时器再试
      if (this.spec.retry.maxAttempts > 0 && this.attempts++ >= this.spec.retry.maxAttempts) {
        this.log.error(`转发目标 ${this.id} HTTP 连续失败 ${this.attempts} 次，暂停（数据保留在队列中）`);
        this.spec.enabled = false;
        this.state = 'disabled';
        this._clearTimers();
      }
    } finally {
      this._httpSending = false;
    }
  }

  _requeue(envs) {
    this.queue.unshift(...envs);
    while (this.queue.length > this.spec.queueCapacity) {
      this.queue.pop(); // 放回时优先丢最新的，保住已有顺序
      this.droppedTotal++;
    }
  }

  /** 主动测试连通性 */
  async test() {
    const started = Date.now();
    if (this.spec.kind === 'http') {
      try {
        await postJson(this.spec.url, { v: 1, type: 'hello', ts: Date.now(), deviceId: '*', payload: { protocol: 1, probe: true } });
        return { reachable: true, latencyMs: Date.now() - started, error: null };
      } catch (err) {
        return { reachable: false, latencyMs: Date.now() - started, error: err.message };
      }
    }
    return await new Promise((resolve) => {
      let settled = false;
      const client = new WsClient(this.spec.url, { connectTimeoutMs: 5000 });
      const done = (reachable, error) => {
        if (settled) return;
        settled = true;
        try {
          client.destroy();
        } catch (_) {
          /* 忽略 */
        }
        resolve({ reachable, latencyMs: Date.now() - started, error });
      };
      const timer = setTimeout(() => done(false, '连接超时'), 6000);
      client.on('open', () => {
        clearTimeout(timer);
        done(true, null);
      });
      client.on('error', (err) => {
        clearTimeout(timer);
        done(false, err.message);
      });
      client.connect();
    });
  }

  toJSON() {
    return {
      ...this.spec,
      queueCapacity: undefined,
      state: this.state,
      queued: this.queue.length,
      sentTotal: this.sentTotal,
      failedTotal: this.failedTotal,
      droppedTotal: this.droppedTotal,
      lastError: this.lastError,
      lastSentAt: this.lastSentAt,
      connectedAt: this.connectedAt,
      attempts: this.attempts
    };
  }
}

function normalizeSpec(spec) {
  if (!spec || typeof spec !== 'object') throw new Error('转发目标必须是对象');
  if (!spec.id || typeof spec.id !== 'string') throw new Error('转发目标缺少 id');
  const kind = spec.kind || 'websocket';
  if (!VALID_KINDS.has(kind)) throw new Error(`kind 必须是 websocket 或 http，收到 ${kind}`);
  if (!spec.url || typeof spec.url !== 'string') throw new Error('转发目标缺少 url');
  if (kind === 'websocket' && !/^wss?:\/\//.test(spec.url)) {
    throw new Error('websocket 目标的 url 必须以 ws:// 或 wss:// 开头');
  }
  if (kind === 'http' && !/^https?:\/\//.test(spec.url)) {
    throw new Error('http 目标的 url 必须以 http:// 或 https:// 开头');
  }
  return {
    id: spec.id,
    enabled: spec.enabled !== false,
    kind,
    url: spec.url,
    deviceIds: Array.isArray(spec.deviceIds) ? spec.deviceIds : [],
    metrics: Array.isArray(spec.metrics) ? spec.metrics : [],
    batchMs: Number.isFinite(Number(spec.batchMs)) ? Number(spec.batchMs) : 2000,
    queueCapacity: Number(spec.queueCapacity) > 0 ? Number(spec.queueCapacity) : DEFAULT_QUEUE_CAPACITY,
    retry: {
      maxAttempts: Number((spec.retry && spec.retry.maxAttempts) ?? 5),
      backoffMs: Number((spec.retry && spec.retry.backoffMs) ?? 1000)
    }
  };
}

function postJson(url, body) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const isHttps = parsed.protocol === 'https:';
    const mod = isHttps ? require('https') : require('http');
    const data = Buffer.from(JSON.stringify(body), 'utf8');
    const req = mod.request(
      {
        protocol: parsed.protocol,
        hostname: parsed.hostname,
        port: parsed.port || (isHttps ? 443 : 80),
        path: `${parsed.pathname}${parsed.search}`,
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length },
        timeout: 10000
      },
      (res) => {
        res.resume();
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(res.statusCode);
        else reject(new Error(`HTTP ${res.statusCode}`));
      }
    );
    req.on('timeout', () => {
      req.destroy(new Error('请求超时'));
    });
    req.on('error', reject);
    req.end(data);
  });
}

class Forwarder {
  /**
   * @param {object} options
   * @param {import('./hub').Hub} options.hub
   * @param {object} options.config
   * @param {object} options.logger
   */
  constructor(options) {
    this.hub = options.hub;
    this.config = options.config;
    this.log = options.logger;
    this.storePath = options.config.forwardStorePath || path.join(__dirname, '..', 'forwards.json');
    /** @type {Map<string, ForwardTarget>} */
    this.targets = new Map();
    this.sentTotal = 0;

    this.hub.on('sample', (record) => this.dispatch(record));
    this._load();
  }

  dispatch(record) {
    for (const target of this.targets.values()) {
      if (!target.enabled) continue;
      if (!target.matches(record)) continue;
      target.enqueue(record);
      this.sentTotal++;
    }
  }

  list() {
    return Array.from(this.targets.values()).map((t) => t.toJSON());
  }

  get(id) {
    return this.targets.get(id) || null;
  }

  /** 新增或更新一个目标 */
  upsert(spec) {
    const normalized = normalizeSpec(spec);
    const existing = this.targets.get(normalized.id);
    const replacement = new ForwardTarget(normalized, this.log);

    if (existing) {
      // ★ 关键：更新配置**不能丢掉已经排队但还没发出去的数据**。
      //   踩过的坑：早期版本直接 destroy 旧目标，旧队列里的样本就永久消失了
      //   （只在日志里体现为 failed/dropped 计数），这与"断线不丢数据"的设计目标相矛盾。
      const carried = existing.queue.slice();
      existing.destroy();
      replacement.adoptQueue(carried);
      if (carried.length > 0) {
        this.log.info(`转发目标 ${normalized.id} 配置已更新，迁移未发送队列 ${carried.length} 条`);
      }
    }

    this.targets.set(normalized.id, replacement);
    replacement.start();
    this._save();
    return replacement;
  }

  remove(id) {
    const target = this.targets.get(id);
    if (!target) return false;
    target.destroy();
    this.targets.delete(id);
    this._save();
    return true;
  }

  stats() {
    let queued = 0;
    let sent = 0;
    let failed = 0;
    let dropped = 0;
    let enabled = 0;
    for (const t of this.targets.values()) {
      queued += t.queue.length;
      sent += t.sentTotal;
      failed += t.failedTotal;
      dropped += t.droppedTotal;
      if (t.enabled) enabled++;
    }
    return { total: this.targets.size, enabled, queuedTotal: queued, sentTotal: sent, failedTotal: failed, droppedTotal: dropped };
  }

  shutdown() {
    for (const t of this.targets.values()) t.destroy();
  }

  _load() {
    try {
      if (!fs.existsSync(this.storePath)) return;
      // stripBom：用户用 PowerShell/记事本编辑过这个文件时很容易带上 BOM，
      // 而 JSON.parse 不认 BOM。不处理的话转发目标会"莫名其妙全部消失"。
      const raw = JSON.parse(stripBom(fs.readFileSync(this.storePath, 'utf8')));
      const list = Array.isArray(raw) ? raw : raw.targets;
      if (!Array.isArray(list)) return;
      for (const spec of list) {
        try {
          const target = new ForwardTarget(spec, this.log);
          this.targets.set(target.id, target);
          target.start();
        } catch (err) {
          this.log.warn(`跳过非法的持久化转发目标: ${err.message}`);
        }
      }
      this.log.info(`已从 ${this.storePath} 载入 ${this.targets.size} 个转发目标`);
    } catch (err) {
      this.log.warn(`转发目标持久化文件读取失败: ${err.message}`);
    }
  }

  _save() {
    try {
      const dir = path.dirname(this.storePath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const payload = { targets: Array.from(this.targets.values()).map((t) => t.spec) };
      fs.writeFileSync(this.storePath, JSON.stringify(payload, null, 2) + '\n', 'utf8');
    } catch (err) {
      this.log.warn(`转发目标持久化失败: ${err.message}`);
    }
  }
}

module.exports = { Forwarder, ForwardTarget, postJson, normalizeSpec };
