'use strict';
/**
 * HealthLink 零依赖 WebSocket 服务端实现（RFC 6455 子集）
 *
 * 为什么自己写：需求要求在完全离线的环境里可运行，npm registry 不可达时
 * 装不了 ws 包。本项目只用到服务端方向的 WebSocket，实现量很小：
 *   - HTTP Upgrade 握手（含 Sec-WebSocket-Accept 计算）
 *   - 帧解析（文本/二进制/关闭/ping/pong，含分片续帧）
 *   - 帧编码（服务端发出的帧不掩码）
 *   - 掩码解码（客户端发来的帧必须掩码）
 *
 * 未实现（本项目不需要，遇到会明确报错而不是静默出错）：
 *   - permessage-deflate 扩展压缩
 *   - 客户端方向（掩码发送）
 *
 * 用法：
 *   const { createWebSocketServer } = require('./ws');
 *   const wss = createWebSocketServer();
 *   server.on('upgrade', (req, socket, head) => {
 *     const conn = wss.handleUpgrade(req, socket, head);
 *     if (!conn) return;                       // 握手不合法，已回 400
 *     conn.on('message', (text) => {...});
 *     conn.on('close', (code, reason) => {...});
 *     conn.send('hello');
 *     conn.close(1000, 'bye');
 *   });
 */

const crypto = require('crypto');
const { EventEmitter } = require('events');

/** RFC 6455 规定的魔法字符串 */
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const OPCODE = {
  CONTINUATION: 0x0,
  TEXT: 0x1,
  BINARY: 0x2,
  CLOSE: 0x8,
  PING: 0x9,
  PONG: 0xa
};

/** 默认上限：单帧载荷 1MB，重组后的消息 8MB。防止恶意客户端打爆内存。 */
const DEFAULT_MAX_FRAME_BYTES = 1024 * 1024;
const DEFAULT_MAX_MESSAGE_BYTES = 8 * 1024 * 1024;

/** 允许的应用层关闭码（RFC 6455 §7.4.2） */
function isValidCloseCode(code) {
  if (code === 1000 || code === 1001 || code === 1002 || code === 1003) return true;
  if (code >= 1007 && code <= 1011) return true;
  if (code >= 3000 && code <= 4999) return true;
  return false;
}

/**
 * 计算握手响应头里的 Sec-WebSocket-Accept。
 * @param {string} key 请求头 Sec-WebSocket-Key 的原值
 */
function computeAcceptKey(key) {
  return crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
}

/**
 * 把 HTTP 头解析成小写键的对象（同名头合并为数组用逗号连接）。
 *
 * ⚠️ 支持两种入参，因为这两种形式在 Node 里都会遇到：
 *   1. Node 的 `req.rawHeaders`：**扁平数组** `['Host','h','Upgrade','websocket', ...]`
 *      —— 注意不是 "Name: value" 字符串数组，这里踩过坑：按 ':' 切分会一个头都解析不出来，
 *      表现为"所有 WebSocket 握手都返回 400"。
 *   2. `'Name: value'` 字符串数组（自己解析原始报文时用）。
 */
function parseHeaders(rawHeaders) {
  const headers = {};
  if (!rawHeaders) return headers;

  const setHeader = (name, value) => {
    if (!name) return;
    const key = String(name).trim().toLowerCase();
    if (!key) return;
    const text = String(value === undefined ? '' : value).trim();
    if (Object.prototype.hasOwnProperty.call(headers, key)) {
      headers[key] = `${headers[key]}, ${text}`;
    } else {
      headers[key] = text;
    }
  };

  if (Array.isArray(rawHeaders)) {
    // 形式 1：扁平 [name, value, name, value, ...]
    if (rawHeaders.length > 0 && !String(rawHeaders[0]).includes(':')) {
      for (let i = 0; i + 1 < rawHeaders.length; i += 2) {
        setHeader(rawHeaders[i], rawHeaders[i + 1]);
      }
      return headers;
    }
    // 形式 2：'Name: value'
    for (const line of rawHeaders) {
      const idx = String(line).indexOf(':');
      if (idx <= 0) continue;
      setHeader(String(line).slice(0, idx), String(line).slice(idx + 1));
    }
    return headers;
  }

  if (typeof rawHeaders === 'object') {
    for (const [name, value] of Object.entries(rawHeaders)) {
      if (Array.isArray(value)) {
        for (const item of value) setHeader(name, item);
      } else {
        setHeader(name, value);
      }
    }
  }
  return headers;
}

/**
 * 一条已建立的 WebSocket 连接。
 * 事件：message(text), binary(Buffer), ping(Buffer), pong(Buffer), close(code, reason), error(Error)
 */
class WebSocketConnection extends EventEmitter {
  constructor(socket, options = {}) {
    super();
    this.socket = socket;
    this.remoteAddress = socket.remoteAddress;
    this.remotePort = socket.remotePort;
    this.isAlive = true;
    /** 应用自定义挂载点，例如 deviceId / subscriberId */
    this.context = {};

    this._buffer = Buffer.alloc(0);
    this._fragments = [];
    this._fragmentOpcode = null;
    this._fragmentBytes = 0;
    this._closed = false;
    this._closeSent = false;
    /** 出现协议错误后置位，用来彻底停止后续帧解析（见 _onData） */
    this._protocolError = false;

    this._maxFrameBytes = options.maxFrameBytes || DEFAULT_MAX_FRAME_BYTES;
    this._maxMessageBytes = options.maxMessageBytes || DEFAULT_MAX_MESSAGE_BYTES;

    socket.setNoDelay(true);
    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('error', (err) => {
      // ECONNRESET 是客户端强杀进程的常态，不当作异常上报
      if (err && err.code !== 'ECONNRESET' && err.code !== 'EPIPE') this.emit('error', err);
      this._finalize(1006, 'socket error');
    });
    socket.on('close', () => this._finalize(1006, 'socket closed'));
    socket.on('end', () => this._finalize(1006, 'socket ended'));
  }

  /** 是否仍然可写 */
  get writable() {
    return !this._closed && this.socket.writable;
  }

  /** 发送一条文本消息（不掩码，服务端方向） */
  send(text) {
    if (!this.writable) return false;
    const payload = Buffer.isBuffer(text) ? text : Buffer.from(String(text), 'utf8');
    const opcode = Buffer.isBuffer(text) ? OPCODE.BINARY : OPCODE.TEXT;
    return this._writeFrame(opcode, payload);
  }

  /** 发送一条 JSON 消息 */
  sendJson(obj) {
    return this.send(JSON.stringify(obj));
  }

  /**
   * 主动关闭连接。
   * @param {number} code 关闭码，默认 1000
   * @param {string} reason 关闭原因，UTF-8 后不能超过 123 字节
   */
  close(code = 1000, reason = '') {
    if (this._closed) return;
    if (!isValidCloseCode(code)) code = 1000;
    // 记下我们自己发出的关闭码/原因：如果对端收到后直接 FIN 而没有回 CLOSE 帧，
    // 我们在 socket 'end' 时只能拿到 1006，那会把"我方以 1002 正常关闭"误记成"异常断开"。
    this._sentCloseCode = code;
    this._sentCloseReason = String(reason || '');
    let reasonBuf = Buffer.from(String(reason || ''), 'utf8');
    if (reasonBuf.length > 123) reasonBuf = reasonBuf.subarray(0, 123);
    const payload = Buffer.alloc(2 + reasonBuf.length);
    payload.writeUInt16BE(code, 0);
    reasonBuf.copy(payload, 2);
    this._closeSent = true;
    this._writeFrame(OPCODE.CLOSE, payload);
    // 给对端一点时间回 CLOSE，然后强制销毁
    this._closeTimer = setTimeout(() => {
      if (!this._closed) this.socket.destroy();
    }, 1000);
    // ⚠️ 不要 unref()：unref 之后，如果此时事件循环里已经没有别的句柄
    //    （例如服务正在关闭），Node 会在计时器触发前直接退出，
    //    结果是 socket 半开着、server.close() 的回调永远不触发、
    //    关闭流程静默卡死 —— 测试里表现为"打印到一半就没了，退出码还是 0"。
    //    这 1 秒的兜底本来就是为了保证连接一定被收掉，必须保持 ref。
  }

  /** 不加关闭码地硬断开（协议错误场景） */
  destroy() {
    this._finalize(1006, 'destroyed');
    this.socket.destroy();
  }

  // ---------------------------------------------------------------- 内部实现

  _writeFrame(opcode, payload) {
    try {
      const len = payload.length;
      let header;
      if (len < 126) {
        header = Buffer.alloc(2);
        header[1] = len;
      } else if (len < 65536) {
        header = Buffer.alloc(4);
        header[1] = 126;
        header.writeUInt16BE(len, 2);
      } else {
        header = Buffer.alloc(10);
        header[1] = 127;
        // 高 32 位必然为 0（8MB 上限远小于 4GB）
        header.writeUInt32BE(0, 2);
        header.writeUInt32BE(len, 6);
      }
      header[0] = 0x80 | opcode; // FIN=1, RSV=0
      this.socket.write(Buffer.concat([header, payload]));
      return true;
    } catch (err) {
      this.emit('error', err);
      this._finalize(1006, 'write failed');
      return false;
    }
  }

  _onData(chunk) {
    // 出现协议错误后必须停止继续解析，否则同一帧会被反复解析。
    // ⚠️ 这里踩过一个严重的坑：早期版本在协议错误后只 emit('error') + close()，
    //    没有停止解析。由于出错的那一帧**一个字节都没被消费**，
    //    下一次 data 事件带来更多字节后又会重新解析并再次抛错，
    //    形成死循环 —— 表现为 error 事件刷屏、CLOSE 帧发不出去、
    //    对端只看到 1006 异常断开。
    //
    // 注意：**不能用 `_closeSent` 当这个开关**。我方主动 close() 之后，
    // 仍然必须继续处理对端回过来的 CLOSE 帧，否则会丢掉对端确认的关闭码
    // （曾经因此把"我方发 4401"错误地上报成 1006）。
    if (this._closed || this._protocolError) return;
    this._buffer = this._buffer.length === 0 ? chunk : Buffer.concat([this._buffer, chunk]);
    let sawProtocolError = false;
    try {
      while (this._parseOneFrame()) {
        /* 继续解析直到缓冲不足 */
      }
    } catch (err) {
      sawProtocolError = true;
      this._protocolError = true;
      this.emit('error', err);
    }
    if (sawProtocolError) {
      // 按 RFC 6455 §7.4.1 用 1002 明确告知对端。
      // 这里**不能立刻 destroy**：那会让对端只看到 1006（异常断开）。
      // close() 内部有 1 秒兜底销毁，不会泄漏连接。
      this.close(1002, 'protocol error');
    }
  }

  /** @returns {boolean} 是否消费掉了一帧 */
  _parseOneFrame() {
    const buf = this._buffer;
    if (buf.length < 2) return false;

    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) !== 0;
    const rsv = b0 & 0x70;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let payloadLen = b1 & 0x7f;

    if (rsv !== 0) throw new Error('RSV bits set but no extension negotiated');
    if (!masked) throw new Error('client frame must be masked');

    let offset = 2;
    if (payloadLen === 126) {
      if (buf.length < offset + 2) return false;
      payloadLen = buf.readUInt16BE(offset);
      offset += 2;
    } else if (payloadLen === 127) {
      if (buf.length < offset + 8) return false;
      const high = buf.readUInt32BE(offset);
      const low = buf.readUInt32BE(offset + 4);
      if (high !== 0) throw new Error('frame too large');
      payloadLen = low;
      offset += 8;
    }

    if (payloadLen > this._maxFrameBytes) throw new Error(`frame exceeds ${this._maxFrameBytes} bytes`);
    if (buf.length < offset + 4) return false; // 掩码键还没到齐

    const maskKey = buf.subarray(offset, offset + 4);
    offset += 4;
    if (buf.length < offset + payloadLen) return false; // 载荷还没到齐

    const payload = Buffer.allocUnsafe(payloadLen);
    for (let i = 0; i < payloadLen; i++) {
      payload[i] = buf[offset + i] ^ maskKey[i & 3];
    }
    this._buffer = buf.subarray(offset + payloadLen);

    this._handleFrame(fin, opcode, payload);
    return true;
  }

  _handleFrame(fin, opcode, payload) {
    switch (opcode) {
      case OPCODE.PING:
        this._writeFrame(OPCODE.PONG, payload);
        this.emit('ping', payload);
        return;
      case OPCODE.PONG:
        this.isAlive = true;
        this.emit('pong', payload);
        return;
      case OPCODE.CLOSE: {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        const reason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
        if (!this._closeSent) {
          // 回一个 CLOSE，然后关闭
          const echo = Buffer.alloc(2);
          echo.writeUInt16BE(isValidCloseCode(code) ? code : 1000, 0);
          this._closeSent = true;
          this._writeFrame(OPCODE.CLOSE, echo);
        }
        this._finalize(code, reason);
        try {
          this.socket.end();
        } catch (err) {
          this.socket.destroy();
        }
        return;
      }
      case OPCODE.TEXT:
      case OPCODE.BINARY:
        if (this._fragmentOpcode !== null) throw new Error('new data frame while fragmented message in progress');
        if (fin) {
          this._deliver(opcode, payload);
        } else {
          this._fragmentOpcode = opcode;
          this._fragments = [payload];
          this._fragmentBytes = payload.length;
        }
        return;
      case OPCODE.CONTINUATION:
        if (this._fragmentOpcode === null) throw new Error('continuation frame without initial frame');
        this._fragmentBytes += payload.length;
        if (this._fragmentBytes > this._maxMessageBytes) throw new Error('fragmented message too large');
        this._fragments.push(payload);
        if (fin) {
          const full = Buffer.concat(this._fragments, this._fragmentBytes);
          const op = this._fragmentOpcode;
          this._fragmentOpcode = null;
          this._fragments = [];
          this._fragmentBytes = 0;
          this._deliver(op, full);
        }
        return;
      default:
        throw new Error(`unsupported opcode 0x${opcode.toString(16)}`);
    }
  }

  _deliver(opcode, payload) {
    if (opcode === OPCODE.TEXT) this.emit('message', payload.toString('utf8'));
    else this.emit('binary', payload);
  }

  _finalize(code, reason) {
    if (this._closed) return;
    this._closed = true;
    if (this._closeTimer) clearTimeout(this._closeTimer);
    // 若 1006（无关闭码）且我方已经发过关闭帧，则以我方发出的码/原因上报，
    // 否则日志里会把"我方以 1002 正常关闭"误记成"异常断开"。
    if (code === 1006 && this._sentCloseCode !== undefined) {
      this.emit('close', this._sentCloseCode, this._sentCloseReason);
      return;
    }
    this.emit('close', code, reason);
  }
}

/**
 * WebSocket 服务端：只负责握手与连接管理，不绑定 HTTP 服务器的业务路由。
 */
class WebSocketServer extends EventEmitter {
  constructor(options = {}) {
    super();
    this.options = options;
    this.connections = new Set();
    /** 心跳间隔（毫秒）。0 表示不启用自动心跳。 */
    this.heartbeatMs = options.heartbeatMs === undefined ? 30000 : options.heartbeatMs;
    if (this.heartbeatMs > 0) {
      this._heartbeat = setInterval(() => this._sweep(), this.heartbeatMs);
      if (this._heartbeat.unref) this._heartbeat.unref();
    }
  }

  /**
   * 处理一个 HTTP Upgrade 请求。
   * @returns {WebSocketConnection|null} 握手失败时返回 null（已回复错误响应）
   */
  handleUpgrade(req, socket, head, options = {}) {
    const headers = parseHeaders(req.rawHeaders || []);
    const key = headers['sec-websocket-key'];
    const version = headers['sec-websocket-version'];
    const upgrade = (headers.upgrade || '').toLowerCase();

    if (upgrade !== 'websocket' || !key || version !== '13') {
      socket.write(
        'HTTP/1.1 400 Bad Request\r\n' +
          'Connection: close\r\n' +
          'Content-Type: text/plain; charset=utf-8\r\n' +
          'Content-Length: 42\r\n\r\n' +
          'Bad Request: not a valid WebSocket upgrade'
      );
      socket.destroy();
      return null;
    }

    const responseHeaders = [
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${computeAcceptKey(key)}`
    ];
    if (options.protocol) responseHeaders.push(`Sec-WebSocket-Protocol: ${options.protocol}`);
    socket.write(responseHeaders.join('\r\n') + '\r\n\r\n');

    const conn = new WebSocketConnection(socket, this.options);
    this.connections.add(conn);
    conn.on('close', () => this.connections.delete(conn));
    if (head && head.length) conn._onData(head);
    this.emit('connection', conn, req);
    return conn;
  }

  /** 给所有连接发 ping，把上一轮没回 pong 的踢掉 */
  _sweep() {
    for (const conn of this.connections) {
      if (conn.isAlive === false) {
        conn.close(1001, 'heartbeat timeout');
        conn.socket.destroy();
        continue;
      }
      conn.isAlive = false;
      if (conn.writable) conn._writeFrame(OPCODE.PING, Buffer.alloc(0));
    }
  }

  close() {
    if (this._heartbeat) clearInterval(this._heartbeat);
    for (const conn of this.connections) conn.close(1001, 'server shutting down');
  }
}

module.exports = {
  createWebSocketServer: (options) => new WebSocketServer(options),
  WebSocketServer,
  WebSocketConnection,
  computeAcceptKey,
  parseHeaders,
  OPCODE
};
