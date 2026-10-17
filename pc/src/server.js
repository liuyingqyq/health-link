'use strict';
/**
 * HealthLink 电脑端 HTTP + WebSocket 服务器。
 *
 * 路由总览（完整字段见 docs/HTTP接口契约.md）：
 *   GET  /                       面板 HTML（无需令牌）
 *   GET  /assets/*               面板静态资源（无需令牌）
 *   GET  /api/health             存活探测（无需令牌）
 *   GET  /api/stats              运行统计
 *   GET  /api/devices            设备列表
 *   GET  /api/samples            历史样本查询
 *   GET  /api/latest             各设备各指标最新值
 *   GET  /api/export             导出 json / csv
 *   GET|POST|DELETE /api/forward 转发目标管理
 *   POST /api/forward/test       转发目标连通性测试
 *   WS   /ingest                 手机上行
 *   WS   /subscribe              下游订阅（面板 / 第三方）
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { createWebSocketServer } = require('./ws');
const { Hub, makeEnvelope, PROTOCOL_VERSION } = require('./hub');
const { Forwarder, ForwardTarget } = require('./relay');
const { PcBleSource } = require('./pcBleSource');

const WEB_ROOT = path.join(__dirname, '..', 'web');
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8'
};

class HealthLinkServer {
  constructor(options) {
    this.config = options.config;
    this.log = options.logger;
    this.hub = options.hub || new Hub({ config: this.config, logger: this.log });
    this.forwarder = options.forwarder || new Forwarder({ hub: this.hub, config: this.config, logger: this.log });

    // PC 蓝牙桥：让电脑直接连心率设备（默认关闭，见 pc/src/pcBleSource.js 顶部说明）
    this.pcBle = new PcBleSource({ hub: this.hub, config: this.config, logger: this.log });

    this.wss = createWebSocketServer({
      heartbeatMs: this.config.heartbeatMs,
      maxFrameBytes: this.config.maxFrameBytes,
      maxMessageBytes: this.config.maxMessageBytes
    });
    this.server = http.createServer((req, res) => this._onRequest(req, res));
    this.server.on('upgrade', (req, socket, head) => this._onUpgrade(req, socket, head));
    this._archiveStream = null;
    this._archiveDay = null;
    if (this.config.archive && this.config.archive.enabled) {
      this.hub.on('sample', (record) => this._archive(record));
    }
  }

  listen() {
    return new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.config.port, this.config.host, () => {
        const actual = this.server.address();
        // 通配地址在 URL 里要写成 [::] / 0.0.0.0，直接拼 '::' 会得到 http://:::18787/ 这种坏 URL
        const shownHost = this.config.host === '::' ? '[::]' : this.config.host;
        const family = this.config.host === '::' ? 'IPv4+IPv6 双栈' : 'IPv4';
        this.log.info(`HealthLink 电脑端已启动: http://${shownHost}:${actual.port}/  （监听 ${family}）`);
        this.log.info(`访问令牌: ${this.config.authToken}${this.config.tokenGenerated ? ' （本次自动生成并写入 config.json）' : ''}`);
        this.log.info(`手机上行地址: ws://<本机IP>:${actual.port}/ingest?token=${this.config.authToken}`);
        // 服务就绪后再启动蓝牙桥（避免它先报错干扰启动日志）
        try { this.pcBle.start(); } catch (err) { this.log.warn(`PC 蓝牙桥启动异常: ${err.message}`); }
        resolve(actual);
      });
    });
  }

  async close() {
    // 先停蓝牙桥：它会 kill 子进程并注销本机设备（否则设备会一直显示在线）
    try { this.pcBle.stop(); } catch (e) { /* 忽略 */ }
    this.forwarder.shutdown();
    this.wss.close();
    // ⚠️ server.close() 的回调**只有在所有连接都结束后**才触发：
    //    HTTP keep-alive 连接、对端半关闭的 TCP、以及已升级成 WebSocket 的 socket，
    //    任何一个没断，回调就永远不来 —— 于是 await 卡死，进程却因事件循环空了而"正常退出"。
    //    所以这里加兜底：超时就强制断开剩余连接，保证 close() 一定会返回。
    await new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        resolve();
      };
      this.server.close(finish);
      setTimeout(() => {
        this.log && this.log.warn && this.log.warn('关闭服务超时，强制断开剩余连接');
        try { if (typeof this.server.closeAllConnections === 'function') this.server.closeAllConnections(); } catch (e) { /* 老版本 Node 没有这个 API */ }
        try { this.server.closeIdleConnections && this.server.closeIdleConnections(); } catch (e) { /* 忽略 */ }
        finish();
      }, 3000);
      // 保持 ref：这个兜底必须真的执行到，否则关闭流程会在事件循环空掉时被静默掐断
    });
  }

  // ============================================================ HTTP

  _onRequest(req, res) {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = decodeURIComponent(url.pathname);

    if (req.method === 'OPTIONS') {
      res.writeHead(204, corsHeaders());
      return res.end();
    }

    if (pathname === '/api/health') return this._json(res, 200, { ok: true, data: this._health(), ts: Date.now() });

    // /api/ingest：让不支持 WebSocket 的对端也能把数据推进来（转发器 http 模式用）
    if (pathname === '/api/ingest' && req.method === 'POST') return this._handleHttpIngest(req, res, url);

    if (pathname.startsWith('/api/')) {
      if (!this._authorized(req, url)) {
        return this._error(res, 401, 'unauthorized', '缺少或错误的访问令牌');
      }
      return this._routeApi(req, res, url, pathname);
    }

    return this._serveStatic(req, res, pathname);
  }

  _health() {
    return {
      service: 'healthlink-hub',
      version: '1.0.0',
      protocol: PROTOCOL_VERSION,
      uptimeMs: Date.now() - this.hub.startedAt,
      startedAt: this.hub.startedAt
    };
  }

  _routeApi(req, res, url, pathname) {
    // 去掉结尾斜杠，避免 /api/forward/test/ 这类写法落到 404
    const route = pathname.length > 1 && pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
    try {
      switch (route) {
        case '/api/stats': {
          const stats = this.hub.statsSnapshot();
          stats.forwards = this.forwarder.stats();
          return this._json(res, 200, { ok: true, data: stats, ts: Date.now() });
        }
        case '/api/devices':
          return this._json(res, 200, { ok: true, data: this.hub.listDevices(), ts: Date.now() });
        case '/api/pcble':
          // PC 蓝牙桥状态：设备名、连接状态、电量、最近心率、已入库条数
          return this._json(res, 200, { ok: true, data: this.pcBle.getStatus(), ts: Date.now() });
        case '/api/latest':
          return this._json(res, 200, { ok: true, data: this.hub.getLatestMap(), ts: Date.now() });
        case '/api/samples':
          return this._handleSamples(res, url);
        case '/api/export':
          return this._handleExport(req, res, url);
        case '/api/forward':
          return this._handleForward(req, res, url);
        case '/api/forward/test':
          return this._handleForwardTest(req, res);
        default:
          return this._error(res, 404, 'not_found', `未知接口 ${pathname}`);
      }
    } catch (err) {
      this.log.error(`接口 ${pathname} 处理失败: ${err.stack || err.message}`);
      return this._error(res, 500, 'internal', err.message);
    }
  }

  /** POST /api/forward/test —— 立刻探测一次转发目标是否可达 */
  _handleForwardTest(req, res) {
    if (req.method !== 'POST') {
      return this._error(res, 405, 'bad_request', `不支持的方法 ${req.method}，请用 POST`);
    }
    return this._readJson(req, (err, body) => {
      if (err) return this._error(res, 400, 'bad_request', err.message);
      let target = body && body.id ? this.forwarder.get(body.id) : null;
      if (!target && body && body.url) {
        // 允许直接测试一个还没保存的目标
        try {
          target = new ForwardTarget(body, this.log);
        } catch (e) {
          return this._error(res, 400, 'bad_request', e.message);
        }
      }
      if (!target) return this._error(res, 400, 'bad_request', '需要提供已存在的 id 或完整的 url');
      Promise.resolve(target.test())
        .then((result) => this._json(res, 200, { ok: true, data: result, ts: Date.now() }))
        .catch((e) => this._error(res, 500, 'internal', e.message));
    });
  }

  _handleSamples(res, url) {
    const limitRaw = url.searchParams.get('limit');
    const limit = limitRaw === null ? 100 : Number(limitRaw);
    if (!Number.isFinite(limit) || limit < 1) {
      return this._error(res, 400, 'bad_request', 'limit 必须是 >= 1 的数字');
    }
    if (limit > this.config.maxQueryLimit) {
      return this._error(res, 400, 'bad_request', `limit 不能超过 ${this.config.maxQueryLimit}`);
    }
    const deviceParam = url.searchParams.get('deviceId');
    const metricParam = url.searchParams.get('metric');
    const since = Number(url.searchParams.get('since') || 0);
    const result = this.hub.querySamples({
      deviceIds: deviceParam ? deviceParam.split(',').filter(Boolean) : [],
      metrics: metricParam ? metricParam.split(',').filter(Boolean) : [],
      startTime: Number(url.searchParams.get('startTime') || 0),
      endTime: Number(url.searchParams.get('endTime') || 0),
      sinceOrder: since > 0 ? since : 0,
      limit,
      order: url.searchParams.get('order') === 'asc' ? 'asc' : 'desc'
    });
    const samples = result.samples.map(toWireSample);
    return this._json(res, 200, {
      ok: true,
      data: { samples, count: samples.length, truncated: result.truncated },
      ts: Date.now()
    });
  }

  _handleExport(req, res, url) {
    const format = (url.searchParams.get('format') || 'json').toLowerCase();
    const limit = Math.min(Number(url.searchParams.get('limit') || 10000), 1000000);
    const deviceParam = url.searchParams.get('deviceId');
    const metricParam = url.searchParams.get('metric');
    const result = this.hub.querySamples({
      deviceIds: deviceParam ? deviceParam.split(',').filter(Boolean) : [],
      metrics: metricParam ? metricParam.split(',').filter(Boolean) : [],
      startTime: Number(url.searchParams.get('startTime') || 0),
      endTime: Number(url.searchParams.get('endTime') || 0),
      limit,
      order: 'asc'
    });
    const samples = result.samples.map(toWireSample);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');

    if (format === 'csv') {
      const header = 'seq,deviceId,metric,value,unit,startTime,endTime,source,receivedAt,metricJson';
      const lines = [header];
      for (const s of samples) {
        lines.push(
          [
            s.seq,
            s.deviceId,
            s.payload.metric,
            s.payload.value === null || s.payload.value === undefined ? '' : s.payload.value,
            s.payload.unit || '',
            s.payload.startTime ?? '',
            s.payload.endTime ?? '',
            s.payload.source || '',
            s.receivedAt,
            csvEscape(JSON.stringify(s.payload))
          ].join(',')
        );
      }
      const body = Buffer.from('\uFEFF' + lines.join('\r\n') + '\r\n', 'utf8');
      res.writeHead(200, {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="healthlink-export-${stamp}.csv"`,
        'Content-Length': body.length,
        ...corsHeaders()
      });
      return res.end(body);
    }

    if (format !== 'json') return this._error(res, 400, 'bad_request', `不支持的 format=${format}`);

    const body = Buffer.from(
      JSON.stringify({ exportedAt: Date.now(), service: 'healthlink-hub', protocol: PROTOCOL_VERSION, count: samples.length, samples }, null, 2),
      'utf8'
    );
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Disposition': `attachment; filename="healthlink-export-${stamp}.json"`,
      'Content-Length': body.length,
      ...corsHeaders()
    });
    return res.end(body);
  }

  _handleForward(req, res, url) {
    if (req.method === 'GET') {
      return this._json(res, 200, { ok: true, data: this.forwarder.list(), ts: Date.now() });
    }
    if (req.method === 'POST') {
      return this._readJson(req, (err, body) => {
        if (err) return this._error(res, 400, 'bad_request', err.message);
        try {
          const target = this.forwarder.upsert(body);
          this.log.info(`转发目标已保存: ${target.id} -> ${target.spec.url}`);
          return this._json(res, 200, { ok: true, data: target.toJSON(), ts: Date.now() });
        } catch (e) {
          return this._error(res, 400, 'bad_request', e.message);
        }
      });
    }
    if (req.method === 'DELETE') {
      const id = url.searchParams.get('id');
      if (!id) return this._error(res, 400, 'bad_request', '缺少 id 查询参数');
      const removed = this.forwarder.remove(id);
      if (!removed) return this._error(res, 404, 'not_found', `没有 id=${id} 的转发目标`);
      return this._json(res, 200, { ok: true, data: { removed: true }, ts: Date.now() });
    }
    return this._error(res, 405, 'bad_request', `不支持的方法 ${req.method}`);
  }

  /** HTTP 形式的接收端，供 relay 的 http 模式对端使用 */
  _handleHttpIngest(req, res, url) {
    if (!this._authorized(req, url)) return this._error(res, 401, 'unauthorized', '缺少或错误的访问令牌');
    return this._readJson(req, (err, body) => {
      if (err) return this._error(res, 400, 'bad_request', err.message);
      const samples = body && body.payload && Array.isArray(body.payload.samples) ? body.payload.samples : [];
      this.log.info(`HTTP 入站收到 ${samples.length} 条（来自 ${req.socket.remoteAddress}）`);
      return this._json(res, 200, { ok: true, data: { accepted: samples.length, note: 'HTTP 入站仅统计，未落库；请使用 WebSocket /ingest' }, ts: Date.now() });
    });
  }

  // ============================================================ WebSocket 升级

  _onUpgrade(req, socket, head) {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    if (!this._authorized(req, url)) {
      const conn = this.wss.handleUpgrade(req, socket, head);
      if (conn) {
        this.hub && this.log.warn(`WebSocket ${pathname} 鉴权失败，来自 ${socket.remoteAddress}`);
        conn.sendJson(makeEnvelope('nack', 0, '*', { reason: 'unauthorized' }));
        conn.close(4401, 'unauthorized');
      }
      return;
    }

    if (pathname === '/ingest') {
      const conn = this.wss.handleUpgrade(req, socket, head);
      if (!conn) return;
      const session = this.hub.attachIngest(conn, socket.remoteAddress);
      // ⚠️ 必须挂 error 监听：ws.js 遇到协议错误（例如超过单帧上限）会 emit('error')，
      // Node 的 EventEmitter 在没有任何 error 监听时会抛出未捕获异常并**杀掉整个进程**。
      conn.on('error', (err) => {
        this.log.warn(`上行连接协议错误（连接将被关闭，服务继续运行）: ${err.message}`);
      });
      conn.on('message', (text) => {
        this.hub.stats.bytesReceived += Buffer.byteLength(text, 'utf8');
        let envelope;
        try {
          envelope = JSON.parse(text);
        } catch (err) {
          conn.sendJson(makeEnvelope('nack', 0, session.deviceId, { reason: 'malformed', detail: 'JSON 解析失败' }));
          this.hub.stats.rejected++;
          return;
        }
        this.hub.handleIngestMessage(session, envelope);
      });
      conn.on('close', (code, reason) => this.hub.detachIngest(session, code, reason));
      return;
    }

    if (pathname === '/subscribe') {
      const conn = this.wss.handleUpgrade(req, socket, head);
      if (!conn) return;
      const sub = this.hub.attachSubscriber(conn, {
        since: Number(url.searchParams.get('since') || 0),
        topic: url.searchParams.get('topic') || 'health'
      });
      conn.on('error', (err) => {
        this.log.warn(`订阅连接协议错误（连接将被关闭，服务继续运行）: ${err.message}`);
      });
      conn.on('message', (text) => {
        let envelope;
        try {
          envelope = JSON.parse(text);
        } catch (err) {
          conn.sendJson(makeEnvelope('nack', 0, '*', { reason: 'malformed', detail: 'JSON 解析失败' }));
          return;
        }
        this.hub.handleSubscriberMessage(sub, envelope);
      });
      conn.on('close', () => this.hub.detachSubscriber(sub));
      return;
    }

    // 未知路径：直接回 404 并断开，不要伪装成握手成功
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    socket.destroy();
  }

  // ============================================================ 静态资源

  _serveStatic(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { Allow: 'GET, HEAD' });
      return res.end();
    }
    let rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/assets\//, '').replace(/^\//, '');
    // 防路径穿越：解析后必须仍在 WEB_ROOT 内
    const resolved = path.resolve(WEB_ROOT, rel);
    const rootWithSep = WEB_ROOT.endsWith(path.sep) ? WEB_ROOT : WEB_ROOT + path.sep;
    if (resolved !== WEB_ROOT && !resolved.startsWith(rootWithSep)) {
      this.log.warn(`拦截路径穿越尝试: ${pathname}`);
      return this._error(res, 403, 'not_found', 'forbidden');
    }
    fs.stat(resolved, (err, stat) => {
      if (err || !stat.isFile()) {
        if (rel === 'index.html') return this._serveFallbackIndex(res);
        return this._error(res, 404, 'not_found', `找不到 ${pathname}`);
      }
      const ext = path.extname(resolved).toLowerCase();
      res.writeHead(200, {
        'Content-Type': MIME[ext] || 'application/octet-stream',
        'Content-Length': stat.size,
        'Cache-Control': 'no-cache',
        ...corsHeaders()
      });
      if (req.method === 'HEAD') return res.end();
      fs.createReadStream(resolved).pipe(res);
    });
  }

  _serveFallbackIndex(res) {
    const body = Buffer.from(
      `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>HealthLink</title>` +
        `<body style="font-family:system-ui;padding:2rem;line-height:1.7">` +
        `<h2>面板资源尚未部署</h2>` +
        `<p>服务端已正常运行，但 <code>pc/web/index.html</code> 不存在。</p>` +
        `<p>REST 接口可直接访问，例如：<a href="/api/devices">/api/devices</a>、` +
        `<a href="/api/stats">/api/stats</a>（需要 <code>?token=</code>）。</p>` +
        `</body></html>`,
      'utf8'
    );
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': body.length });
    res.end(body);
  }

  // ============================================================ 工具

  _authorized(req, url) {
    const headerToken = req.headers['x-auth-token'];
    const queryToken = url.searchParams.get('token');
    const bearer = /^Bearer\s+(.+)$/i.exec(req.headers.authorization || '');
    const provided = headerToken || queryToken || (bearer && bearer[1]);
    if (!provided) return false;
    // 定长比较，避免通过响应时间差推断令牌
    return timingSafeEqualStr(String(provided), this.config.authToken);
  }

  _readJson(req, callback) {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 1024 * 1024) {
        req.destroy();
        callback(new Error('请求体超过 1MB'));
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (size === 0) return callback(null, {});
      try {
        callback(null, JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (err) {
        callback(new Error(`请求体不是合法 JSON: ${err.message}`));
      }
    });
    req.on('error', (err) => callback(err));
  }

  _json(res, status, body) {
    const buf = Buffer.from(JSON.stringify(body), 'utf8');
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': buf.length,
      ...corsHeaders()
    });
    res.end(buf);
  }

  _error(res, status, code, message) {
    return this._json(res, status, { ok: false, error: { code, message }, ts: Date.now() });
  }

  _archive(record) {
    const day = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    if (this._archiveDay !== day) {
      if (this._archiveStream) this._archiveStream.end();
      const pattern = (this.config.archive.file || 'archive/healthlink-YYYYMMDD.jsonl').replace('YYYYMMDD', day);
      const file = path.isAbsolute(pattern) ? pattern : path.join(path.dirname(this.config.configFile), pattern);
      try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        this._archiveStream = fs.createWriteStream(file, { flags: 'a' });
        this._archiveDay = day;
        this.log.info(`归档文件: ${file}`);
      } catch (err) {
        this.log.warn(`归档文件创建失败，已关闭归档: ${err.message}`);
        this.config.archive.enabled = false;
        this._archiveStream = null;
      }
    }
    if (this._archiveStream) this._archiveStream.write(JSON.stringify(record) + '\n');
  }
}

function toWireSample(record) {
  return {
    seq: record.seq,
    ts: record.ts,
    deviceId: record.deviceId,
    receivedAt: record.receivedAt,
    payload: record.payload
  };
}

function csvEscape(value) {
  const s = String(value);
  if (/[",\r\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Auth-Token, Authorization'
  };
}

function timingSafeEqualStr(a, b) {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) return false;
  let diff = 0;
  for (let i = 0; i < bufA.length; i++) diff |= bufA[i] ^ bufB[i];
  return diff === 0;
}

module.exports = { HealthLinkServer, WEB_ROOT };
