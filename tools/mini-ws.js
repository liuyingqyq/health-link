'use strict';
/**
 * 迷你 WebSocket 客户端（浏览器风格 API 的垫片）
 *
 * 为什么需要它：
 *   仓库里的验证脚本原先用的是 **Node 内置的全局 WebSocket**，
 *   但那是 Node **21+** 才有的（22 才稳定）。CI 在 Node 18/20 上会直接
 *   报 `ReferenceError: WebSocket is not defined` —— 本地（Node 24）却是好的，
 *   于是就出现"我这里明明通过，CI 却红"的假象。
 *
 *   这里用项目自己的 WebSocket 实现（`pc/src/wsclient.js`，零依赖、已被
 *   phone-sim / e2e 测试长期使用）包一层浏览器风格 API：
 *     onopen / onmessage / onclose / onerror  +  send() / close()
 *   这样测试脚本不用改逻辑，也能在 Node 18 及以上任何版本跑。
 */

const { WsClient } = require('../pc/src/wsclient');

class MiniWebSocket {
  /**
   * @param {string} url ws://host:port/path?query
   * @param {object} [options] 透传给 WsClient（如 connectTimeoutMs）
   */
  constructor(url, options = {}) {
    this.url = url;
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;

    this._client = new WsClient(url, options);
    this._client.on('open', () => {
      if (typeof this.onopen === 'function') this.onopen({ type: 'open' });
    });
    this._client.on('message', (text) => {
      // 浏览器里 e.data 是字符串（服务端发的是文本帧）
      if (typeof this.onmessage === 'function') this.onmessage({ data: text });
    });
    this._client.on('close', (code, reason) => {
      if (typeof this.onclose === 'function') this.onclose({ code, reason });
    });
    this._client.on('error', (err) => {
      if (typeof this.onerror === 'function') this.onerror(err);
    });

    this._client.connect();
  }

  send(text) {
    this._client.send(text);
  }

  close(code = 1000, reason = '') {
    try { this._client.close(code, reason); } catch (_) { /* 忽略 */ }
  }
}

/**
 * 取一个可用的 WebSocket 构造器：
 *   · Node 22+ 有全局 WebSocket（真实浏览器行为）→ 直接用，测试更贴近现实
 *   · Node 18/20 没有 → 退回上面的垫片
 * 两条路径都由 CI 的 Node 18/20/22 矩阵覆盖，所以都不会烂掉。
 */
function getWebSocketCtor() {
  return typeof WebSocket === 'function' ? WebSocket : MiniWebSocket;
}

module.exports = { MiniWebSocket, getWebSocketCtor };
