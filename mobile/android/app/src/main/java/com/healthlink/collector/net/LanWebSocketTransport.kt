package com.healthlink.collector.net

import com.healthlink.collector.protocol.Transport
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/**
 * 局域网 WebSocket 传输（契约第 1 节）。
 *
 * 用 OkHttp 而非手写 RFC 6455：Android 上它是标准依赖、经过大规模验证，
 * 且自带 ping/pong 之外的完整帧处理。电脑端那边是自写实现（因为 Node 端要零依赖），
 * 两端各自选最稳的方案即可 —— 线缆上跑的都是标准 RFC 6455。
 */
class LanWebSocketTransport(
    private val log: (String) -> Unit
) : Transport {

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)   // 0 = 不因读超时断开长连接
        .writeTimeout(10, TimeUnit.SECONDS)
        .pingInterval(0, TimeUnit.MILLISECONDS)  // 心跳由协议层自己管（30s ping）
        .retryOnConnectionFailure(true)
        .build()

    @Volatile
    private var socket: WebSocket? = null

    @Volatile
    private var listener: Transport.Listener? = null

    override val isOpen: Boolean
        get() = socket != null && opened

    @Volatile
    private var opened = false

    override fun setListener(listener: Transport.Listener) {
        this.listener = listener
    }

    override fun connect(url: String) {
        close()
        opened = false
        val request = Request.Builder().url(url).build()
        socket = client.newWebSocket(request, object : WebSocketListener() {

            override fun onOpen(webSocket: WebSocket, response: Response) {
                opened = true
                log("WebSocket 已连接: ${response.request.url}")
                listener?.onOpen()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                listener?.onMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                opened = false
                listener?.onClosed(code, reason)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                opened = false
                val detail = response?.let { " HTTP ${it.code}" } ?: ""
                listener?.onFailure((t.message ?: t.javaClass.simpleName) + detail)
            }
        })
    }

    override fun send(text: String): Boolean {
        val s = socket ?: return false
        if (!opened) return false
        return s.send(text)
    }

    override fun close() {
        try {
            socket?.close(1000, "client closing")
        } catch (ignored: Exception) {
        }
        socket = null
        opened = false
    }
}
