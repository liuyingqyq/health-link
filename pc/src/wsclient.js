'use strict';
/**
 * WebSocket 客户端（仅本项目需要的最小子集）。
 *
 * 为什么服务端文件里没有它：服务端方向发出的帧不掩码、收到的帧必掩码；
 * 客户端方向刚好相反。两者共用帧解析逻辑会很别扭，所以客户端单独实现一份，
 * 但复用同一个 parseHeaders / 帧格式常量，避免出现两套不一致的解析。
 *
 * 不支持：wss://（TLS）、重定向、permessage-deflate。
 *   wss 的情况明确报错而不是静默降级成明文——健康数据即使在局域网内也不该明文发到公网。
 */

const net = require('net');
const crypto = require('crypto');
const { EventEmitter } = require('events');
const { parseHeaders, OPCODE } = require('./ws');

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

class WsClient extends EventEmitter {
  /**
   * @param {string} url ws://host:port/path?query
   * @param {object} [options]
   * @param {number} [options.connectTimeoutMs=5000]
   */
  constructor(url, options = {}) {
    super();
    this.url = url;
    this.options = options;
    this.state = 'idle';
    this.socket = null;
    this._buffer = Buffer.alloc(0);
    this._handshakeDone = false;
    this._handshakeBuffer = Buffer.alloc(0);
    this._fragments = [];
    this._fragmentOpcode = null;
    this._closedByUs = false;
  }

  static parseUrl(rawUrl) {
    const u = new URL(rawUrl);
    if (u.protocol === 'wss:') {
      throw new Error('不支持 wss://（未实现 TLS）。局域网内请用 ws://，跨公网请改用中继或自行加 TLS 反向代理。');
    }
    if (u.protocol !== 'ws:') throw new Error(`不支持的协议 ${u.protocol}`);
    return {
      host: u.hostname,
      port: Number(u.port || 80),
      path: `${u.pathname || '/'}${u.search || ''}`,
      origin: `http://${u.host}`
    };
  }

  connect() {
    if (this.state === 'connecting' || this.state === 'open') return this;
    const target = WsClient.parseUrl(this.url);
    this.state = 'connecting';

    const key = crypto.randomBytes(16).toString('base64');
    this._expectedAccept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');

    const socket = net.connect({ host: target.host, port: target.port });
    this.socket = socket;
    socket.setNoDelay(true);

    const timeout = setTimeout(() => {
      if (this.state !== 'open') {
        this.emit('error', new Error(`连接超时 ${target.host}:${target.port}`));
        this.destroy();
      }
    }, this.options.connectTimeoutMs || 5000);
    if (timeout.unref) timeout.unref();
    this._connectTimer = timeout;

    socket.on('connect', () => {
      const req =
        `GET ${target.path} HTTP/1.1\r\n` +
        `Host: ${target.host}:${target.port}\r\n` +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Key: ${key}\r\n` +
        'Sec-WebSocket-Version: 13\r\n' +
        `Origin: ${target.origin}\r\n` +
        '\r\n';
      socket.write(req);
    });

    socket.on('data', (chunk) => {
      if (!this._handshakeDone) this._consumeHandshake(chunk);
      else this._consumeFrames(chunk);
    });

    socket.on('error', (err) => {
      this.emit('error', err);
    });

    socket.on('close', () => {
      clearTimeout(this._connectTimer);
      const wasOpen = this.state === 'open';
      this.state = 'closed';
      this.emit('close', this._closeCode || 1006, this._closeReason || (wasOpen ? '' : 'connect failed'));
    });

    return this;
  }

  _consumeHandshake(chunk) {
    this._handshakeBuffer = Buffer.concat([this._handshakeBuffer, chunk]);
    const idx = this._handshakeBuffer.indexOf('\r\n\r\n');
    if (idx < 0) {
      if (this._handshakeBuffer.length > 64 * 1024) {
        this.emit('error', new Error('握手响应头过大'));
        this.destroy();
      }
      return;
    }
    const headRaw = this._handshakeBuffer.subarray(0, idx).toString('latin1');
    const rest = this._handshakeBuffer.subarray(idx + 4);
    this._handshakeBuffer = Buffer.alloc(0);

    const lines = headRaw.split('\r\n');
    const statusLine = lines[0] || '';
    const status = Number((/^HTTP\/1\.1 (\d{3})/.exec(statusLine) || [])[1]);
    const headers = parseHeaders(lines.slice(1));

    if (status !== 101) {
      this.emit('error', new Error(`握手失败 HTTP ${status || '?'} (${statusLine})`));
      this.destroy();
      return;
    }
    if (headers['sec-websocket-accept'] !== this._expectedAccept) {
      this.emit('error', new Error('Sec-WebSocket-Accept 校验失败'));
      this.destroy();
      return;
    }

    this._handshakeDone = true;
    clearTimeout(this._connectTimer);
    this.state = 'open';
    this.emit('open');
    if (rest.length) this._consumeFrames(rest);
  }

  _consumeFrames(chunk) {
    this._buffer = this._buffer.length === 0 ? chunk : Buffer.concat([this._buffer, chunk]);
    try {
      while (this._parseFrame()) {
        /* 继续 */
      }
    } catch (err) {
      this.emit('error', err);
      this.destroy();
    }
  }

  _parseFrame() {
    const buf = this._buffer;
    if (buf.length < 2) return false;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;

    let off = 2;
    if (len === 126) {
      if (buf.length < off + 2) return false;
      len = buf.readUInt16BE(off);
      off += 2;
    } else if (len === 127) {
      if (buf.length < off + 8) return false;
      const high = buf.readUInt32BE(off);
      if (high !== 0) throw new Error('帧过大');
      len = buf.readUInt32BE(off + 4);
      off += 8;
    }

    let maskKey = null;
    if (masked) {
      if (buf.length < off + 4) return false;
      maskKey = buf.subarray(off, off + 4);
      off += 4;
    }
    if (buf.length < off + len) return false;

    const payload = Buffer.allocUnsafe(len);
    if (maskKey) {
      for (let i = 0; i < len; i++) payload[i] = buf[off + i] ^ maskKey[i & 3];
    } else {
      buf.copy(payload, 0, off, off + len);
    }
    this._buffer = buf.subarray(off + len);

    switch (opcode) {
      case OPCODE.PING:
        this._writeFrame(OPCODE.PONG, payload);
        this.emit('ping', payload);
        break;
      case OPCODE.PONG:
        this.emit('pong', payload);
        break;
      case OPCODE.CLOSE: {
        this._closeCode = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        this._closeReason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
        if (!this._closedByUs) {
          const echo = Buffer.alloc(2);
          echo.writeUInt16BE(1000, 0);
          this._closedByUs = true;
          this._writeFrame(OPCODE.CLOSE, echo);
        }
        this.socket.end();
        break;
      }
      case OPCODE.TEXT:
      case OPCODE.BINARY:
        if (fin) {
          this.emit(opcode === OPCODE.TEXT ? 'message' : 'binary', opcode === OPCODE.TEXT ? payload.toString('utf8') : payload);
        } else {
          this._fragmentOpcode = opcode;
          this._fragments = [payload];
        }
        break;
      case OPCODE.CONTINUATION: {
        this._fragments.push(payload);
        if (fin) {
          const full = Buffer.concat(this._fragments);
          const op = this._fragmentOpcode;
          this._fragments = [];
          this._fragmentOpcode = null;
          this.emit(op === OPCODE.TEXT ? 'message' : 'binary', op === OPCODE.TEXT ? full.toString('utf8') : full);
        }
        break;
      }
      default:
        throw new Error(`不支持的 opcode 0x${opcode.toString(16)}`);
    }
    return true;
  }

  /** 客户端发出的帧必须掩码（RFC 6455 §5.3） */
  _writeFrame(opcode, payload) {
    if (!this.socket || !this.socket.writable) return false;
    const mask = crypto.randomBytes(4);
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.alloc(2);
      header[1] = 0x80 | len;
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[1] = 0x80 | 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[1] = 0x80 | 127;
      header.writeUInt32BE(0, 2);
      header.writeUInt32BE(len, 6);
    }
    header[0] = 0x80 | opcode;
    const masked = Buffer.allocUnsafe(len);
    for (let i = 0; i < len; i++) masked[i] = payload[i] ^ mask[i & 3];
    this.socket.write(Buffer.concat([header, mask, masked]));
    return true;
  }

  send(text) {
    if (this.state !== 'open') return false;
    const payload = Buffer.from(typeof text === 'string' ? text : JSON.stringify(text), 'utf8');
    return this._writeFrame(OPCODE.TEXT, payload);
  }

  close(code = 1000, reason = '') {
    if (this.state !== 'open') {
      this.destroy();
      return;
    }
    const reasonBuf = Buffer.from(String(reason), 'utf8').subarray(0, 123);
    const payload = Buffer.alloc(2 + reasonBuf.length);
    payload.writeUInt16BE(code, 0);
    reasonBuf.copy(payload, 2);
    this._closedByUs = true;
    this._writeFrame(OPCODE.CLOSE, payload);
    setTimeout(() => this.destroy(), 500).unref?.();
  }

  destroy() {
    clearTimeout(this._connectTimer);
    if (this.socket) {
      this.socket.removeAllListeners('error');
      this.socket.destroy();
    }
    if (this.state !== 'closed') {
      this.state = 'closed';
      this.emit('close', this._closeCode || 1006, this._closeReason || 'destroyed');
    }
  }
}

module.exports = { WsClient };
