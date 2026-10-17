package com.healthlink.collector.protocol

/** 传输层抽象（对应契约第 6 节），便于日后替换为公网中继或测试桩。 */
interface Transport {
    /** 连接状态回调。 */
    fun setListener(listener: Listener)
    fun connect(url: String)
    fun send(text: String): Boolean
    fun close()
    val isOpen: Boolean

    interface Listener {
        fun onOpen()
        fun onMessage(text: String)
        fun onClosed(code: Int, reason: String)
        fun onFailure(message: String)
    }
}

/**
 * 连接状态机。
 */
enum class LinkState { OFFLINE, CONNECTING, ONLINE, BACKFILLING }

data class ClientStatus(
    val state: LinkState = LinkState.OFFLINE,
    val deviceId: String = "",
    val serverTime: Long = 0L,
    val accepted: Boolean = false,
    val needBackfillFrom: Long = -1L,
    val collectIntervalMs: Long = 60000L,
    val queueSize: Int = 0,
    val droppedTotal: Int = 0,
    val sentTotal: Long = 0L,
    val rejectedTotal: Long = 0L,
    val lastError: String? = null
)

/**
 * 协议客户端：把「信封怎么发」与「什么时候发」集中在这里。
 *
 * 严格按 docs/protocol/README.md 与电脑端 hub.js 的实际行为实现：
 *  - 首条消息必须是 `hello`（否则电脑端回 nack handshake_required）；
 *  - `hello.payload.lastSeq` 上报断电前已发出的最大 seq，电脑端据此算补传区间；
 *  - `seq` 只在上行数据消息（hello/sample/batch）上递增，控制消息固定 0；
 *  - 心跳 30 秒一次，连续 2 次无 `pong` 判定断线；
 *  - 断线退避 1/2/4/8/16/30 秒，上限 30 秒；
 *  - 收到 `hello_ack.needBackfillFrom > 0` 时用离线队列的 `batch` 补传。
 */
class ProtocolClient(
    private val deviceId: String,
    private val queue: OfflineQueue,
    private val transport: Transport,
    private val appVersion: String,
    private val model: String,
    private val osVersion: String,
    private val onStatus: (ClientStatus) -> Unit,
    private val onLog: (String) -> Unit
) {

    @Volatile
    private var seq: Long = 0L

    @Volatile
    private var url: String = ""

    @Volatile
    private var state: LinkState = LinkState.OFFLINE

    @Volatile
    private var shouldRun: Boolean = false

    @Volatile
    private var lastSeqSent: Long = 0L

    private var status = ClientStatus(deviceId = deviceId)

    private val lock = Any()
    private var retryIndex = 0
    private var missedPongs = 0
    private var backfilling = false

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val pingRunnable = Runnable { sendPing() }

    private val listener = object : Transport.Listener {
        override fun onOpen() {
            synchronized(lock) {
                retryIndex = 0
                missedPongs = 0
            }
            log("连接已建立，发送 hello")
            sendHello()
        }

        override fun onMessage(text: String) {
            handleIncoming(text)
        }

        override fun onClosed(code: Int, reason: String) {
            log("连接关闭 code=$code ${if (reason.isNotEmpty()) reason else ""}")
            onDisconnected("连接已关闭")
        }

        override fun onFailure(message: String) {
            log("连接失败: $message")
            onDisconnected(message)
        }
    }

    // ------------------------------------------------------------ 对外控制

    fun start(serverUrl: String) {
        url = serverUrl
        shouldRun = true
        synchronized(lock) { retryIndex = 0 }
        updateState(LinkState.CONNECTING)
        transport.connect(url)
    }

    fun stop() {
        shouldRun = false
        handler.removeCallbacks(pingRunnable)
        transport.close()
        updateState(LinkState.OFFLINE)
    }

    fun isOnline(): Boolean = state == LinkState.ONLINE

    fun currentStatus(): ClientStatus = status

    /**
     * 采集到一条数据时的入口。
     *
     * 在线且没有积压 → 直接发 `sample`（实时性好）；
     * 离线或已有积压 → 先入队，等连接恢复后按 `batch` 顺序补传，避免乱序。
     */
    fun submit(sample: SamplePayload) {
        val err = sample.validate()
        if (err != null) {
            log("丢弃非法样本: $err")
            return
        }
        val backlog = queue.size
        if (shouldRun && transport.isOpen && !backfilling && backlog == 0) {
            nextSeq()
            transport.send(Protocol.sample(seq, deviceId, sample).toJson())
        } else {
            queue.offer(sample)
            publishStatus()
        }
    }

    // ------------------------------------------------------------ 上行

    private fun nextSeq(): Long {
        seq += 1
        lastSeqSent = seq
        return seq
    }

    private fun sendHello() {
        nextSeq()
        val permissions = org.json.JSONObject()
        permissions.put("source", "sensorpro")
        val env = Protocol.hello(
            seq = seq,
            deviceId = deviceId,
            model = model,
            osVersion = osVersion,
            appVersion = appVersion,
            collectIntervalMs = status.collectIntervalMs,
            // 契约：上报断电前已发出的最大 seq，电脑端据此判断是否需要补传
            lastSeq = lastSeqSent - 1,
            backgroundMode = listOf("bluetoothInteraction", "dataTransfer"),
            sourceReady = true,
            permissions = permissions
        )
        transport.send(env.toJson())
    }

    private fun sendPing() {
        if (!shouldRun) return
        if (!transport.isOpen) return
        missedPongs += 1
        if (missedPongs >= MAX_MISSED_PONGS) {
            log("连续 $missedPongs 次未收到 pong，判定断线并重连")
            onDisconnected("心跳超时")
            return
        }
        transport.send(Protocol.ping(deviceId).toJson())
        handler.postDelayed(pingRunnable, PING_INTERVAL_MS)
    }

    private fun schedulePing() {
        handler.removeCallbacks(pingRunnable)
        handler.postDelayed(pingRunnable, PING_INTERVAL_MS)
    }

    /** 补传：把离线队列按批发出去；每批等 ack 提交后再发下一批。 */
    private fun startBackfill(reason: String) {
        if (backfilling) return
        if (queue.isEmpty()) {
            log("无需补传（离线队列为空）")
            finishedBackfill()
            return
        }
        backfilling = true
        updateState(LinkState.BACKFILLING)
        sendNextBatch(reason)
    }

    private fun sendNextBatch(reason: String) {
        val batch = queue.peek(OfflineQueue.MAX_BATCH)
        if (batch.isEmpty()) {
            finishedBackfill()
            return
        }
        nextSeq()
        log("补传 ${batch.size} 条（reason=$reason，剩余 ${queue.size}）")
        transport.send(Protocol.batch(seq, deviceId, batch, reason).toJson())
    }

    private fun finishedBackfill() {
        backfilling = false
        updateState(LinkState.ONLINE)
    }

    // ------------------------------------------------------------ 下行

    private fun handleIncoming(text: String) {
        val env = Envelope.parse(text)
        if (env == null) {
            log("收到非 JSON 消息，回 nack")
            transport.send(Protocol.nack(deviceId, "malformed", "JSON 解析失败").toJson())
            return
        }
        when (env.type) {
            "hello_ack" -> handleHelloAck(env)
            "pong" -> {
                missedPongs = 0
                schedulePing()
            }
            "ack" -> handleAck(env)
            "nack" -> {
                val reason = env.payload.optString("reason", "unknown")
                val detail = env.payload.optString("detail", "")
                log("电脑端回 nack: $reason $detail")
                status = status.copy(lastError = "nack: $reason")
                if (reason == "handshake_required" || reason == "bad_device_id") {
                    // 握手被拒：重来一次握手而不是干等
                    onDisconnected("握手被拒: $reason")
                }
                publishStatus()
            }
            "ping" -> {
                transport.send(Protocol.pong(deviceId, env.ts).toJson())
            }
            else -> {
                // 向前兼容：未知类型忽略，不回错也不崩
                log("忽略未知下行类型: ${env.type}")
            }
        }
    }

    private fun handleHelloAck(env: Envelope) {
        val p = env.payload
        val accepted = p.optBoolean("accepted", false)
        val needBackfillFrom = p.optLong("needBackfillFrom", -1L)
        val interval = p.optLong("collectIntervalMs", status.collectIntervalMs)

        status = status.copy(
            state = LinkState.ONLINE,
            accepted = accepted,
            needBackfillFrom = needBackfillFrom,
            serverTime = p.optLong("serverTime", 0L),
            collectIntervalMs = interval,
            lastError = if (accepted) null else status.lastError
        )
        updateState(LinkState.ONLINE)
        log("hello_ack: accepted=$accepted needBackfillFrom=$needBackfillFrom collectIntervalMs=$interval")

        if (!accepted) return

        // 契约：collectIntervalMs 由电脑端下发，手机端必须尊重
        onServerInterval(interval)

        val hasLocalBacklog = !queue.isEmpty()
        if (needBackfillFrom > 0 || hasLocalBacklog) {
            val reason = if (needBackfillFrom > 0) BackfillReason.RECONNECT else BackfillReason.APP_RESUME
            startBackfill(reason)
        }
    }

    private fun handleAck(env: Envelope) {
        // batch 的 ack 带 accepted/rejected；sample 的 ack 只有 ackSeq
        val acceptedCount = env.payload.optInt("accepted", -1)
        val rejected = env.payload.optInt("rejected", 0)
        if (backfilling && acceptedCount >= 0) {
            if (rejected > 0) {
                status = status.copy(rejectedTotal = status.rejectedTotal + rejected)
                log("本批有 $rejected 条被电脑端拒绝（不再重试，避免死循环）")
            }
            queue.commit(acceptedCount + rejected)
            status = status.copy(sentTotal = status.sentTotal + acceptedCount)
            publishStatus()
            if (queue.isEmpty()) {
                finishedBackfill()
            } else {
                sendNextBatch(BackfillReason.RECONNECT)
            }
        } else {
            status = status.copy(sentTotal = status.sentTotal + 1)
            publishStatus()
        }
    }

    // ------------------------------------------------------------ 连接生命周期

    private fun onDisconnected(reason: String) {
        handler.removeCallbacks(pingRunnable)
        synchronized(lock) {
            backfilling = false
        }
        updateState(LinkState.OFFLINE)
        status = status.copy(lastError = reason)
        publishStatus()
        if (!shouldRun) return
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        val delayIndex = synchronized(lock) {
            val i = retryIndex.coerceAtMost(BACKOFF_MS.lastIndex)
            retryIndex += 1
            i
        }
        val delay = BACKOFF_MS[delayIndex]
        log("${delay}ms 后重连（第 ${delayIndex + 1} 次）")
        handler.postDelayed({
            if (shouldRun) {
                updateState(LinkState.CONNECTING)
                transport.connect(url)
            }
        }, delay)
    }

    private fun updateState(next: LinkState) {
        state = next
        status = status.copy(state = next, queueSize = queue.size, droppedTotal = queue.droppedTotal)
        publishStatus()
    }

    private fun publishStatus() {
        status = status.copy(queueSize = queue.size, droppedTotal = queue.droppedTotal, deviceId = deviceId)
        onStatus(status)
    }

    private fun log(msg: String) = onLog(msg)

    /** 电脑端下发的采集周期回调（默认空实现，由上层决定是否调整）。 */
    var onServerInterval: (Long) -> Unit = {}

    companion object {
        const val PING_INTERVAL_MS = 30_000L
        const val MAX_MISSED_PONGS = 2
        val BACKOFF_MS = longArrayOf(1_000, 2_000, 4_000, 8_000, 16_000, 30_000)
    }
}
