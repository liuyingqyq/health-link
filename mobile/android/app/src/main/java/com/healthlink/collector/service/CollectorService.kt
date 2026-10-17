package com.healthlink.collector.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.healthlink.collector.R
import com.healthlink.collector.net.LanWebSocketTransport
import com.healthlink.collector.protocol.ClientStatus
import com.healthlink.collector.protocol.DeviceIdentity
import com.healthlink.collector.protocol.LinkState
import com.healthlink.collector.protocol.OfflineQueue
import com.healthlink.collector.protocol.ProtocolClient
import com.healthlink.collector.protocol.SamplePayload
import com.healthlink.collector.source.BleHeartRateSource
import com.healthlink.collector.source.HealthSource
import com.healthlink.collector.source.SensorProSource
import com.healthlink.collector.source.SimulatedSource
import com.healthlink.collector.ui.MainActivity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 采集前台服务。
 *
 * 这是 HarmonyOS 端「长时任务（Continuous Task）」在 Android 上的等价物：
 *  · 前台服务 + 常驻通知（Android 的硬性要求，删掉通知系统会停止服务）；
 *  · 持有协议客户端与数据源，退后台、锁屏后继续采集上传；
 *  · 是 UI 与采集逻辑之间的唯一桥梁（UI 通过 Binder 读状态、发指令）。
 */
class CollectorService : Service() {

    /** 数据源类型，由 UI 启动时指定。 */
    enum class SourceKind { SIMULATED, BLE_HEART_RATE, SENSOR_PRO }

    private val binder = LocalBinder()
    /** 主线程 Handler：UI 回调必须回到主线程（见 notifyUi 的说明）。 */
    private val uiHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private lateinit var queue: OfflineQueue
    private var protocol: ProtocolClient? = null
    private var source: HealthSource? = null
    private var sourceKind = SourceKind.SIMULATED
    private var serverUrl = ""
    private var collecting = false

    private val logs = ArrayDeque<String>()
    private var status = ClientStatus()
    private var statusListener: ((ClientStatus, List<String>, Boolean) -> Unit)? = null

    inner class LocalBinder : Binder() {
        fun service(): CollectorService = this@CollectorService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        queue = OfflineQueue(applicationContext)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification("正在准备…"))
        return START_STICKY
    }

    override fun onDestroy() {
        stopCollecting()
        protocol?.stop()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 对外 API（UI 调用）

    fun setStatusListener(l: ((ClientStatus, List<String>, Boolean) -> Unit)?) {
        statusListener = l
    }

    fun currentStatus(): ClientStatus = status
    fun currentLogs(): List<String> = synchronized(logs) { logs.toList() }
    fun isCollecting(): Boolean = collecting

    /**
     * 把当前数据源的设备扫描能力暴露给界面（BLE 心率 / SensorPro 支持）。
     * 数据源尚未创建时先创建，保证点「扫描」就能用。
     */
    fun deviceScanner(): com.healthlink.collector.source.DeviceScanner? {
        val src = source ?: buildSource().also { source = it }
        return src.deviceScanner()
    }

    /** 连接电脑端（不影响是否在采集）。 */
    fun connect(url: String, kind: SourceKind) {
        serverUrl = url
        sourceKind = kind
        protocol?.stop()
        val deviceId = DeviceIdentity.get(applicationContext)
        val p = ProtocolClient(
            deviceId = deviceId,
            queue = queue,
            transport = LanWebSocketTransport { msg -> log(msg) },
            appVersion = appVersion(),
            model = "${Build.MANUFACTURER} ${Build.MODEL}",
            osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            onStatus = { s ->
                status = s
                notifyUi()
                updateNotification(s)
            },
            onLog = { msg -> log(msg) }
        )
        p.onServerInterval = { ms ->
            log("电脑端要求采集周期为 ${ms}ms")
            if (collecting) restartSourceWithInterval(ms)
        }
        protocol = p
        p.start(url)
        log("已发起连接: $url")
    }

    fun disconnect() {
        protocol?.stop()
        protocol = null
        log("已断开连接")
        notifyUi()
    }

    /** 开始采集（会自动确保数据源已就绪）。 */
    fun startCollecting() {
        if (collecting) return
        collecting = true
        val src = source ?: buildSource()
        source = src
        // 数据源 init 是 suspend，用简单线程执行，避免引入 lifecycleScope 依赖
        Thread {
            val result = try {
                kotlinx.coroutines.runBlocking { src.init() }
            } catch (e: Exception) {
                com.healthlink.collector.source.SourceInitResult(false, "初始化异常: ${e.message}")
            }
            log("数据源初始化: ok=${result.ok} ${result.message}")
            if (!result.ok) {
                collecting = false
                notifyUi()
                return@Thread
            }
            val interval = if (status.collectIntervalMs > 0) status.collectIntervalMs else 60_000L
            src.start(interval, onSample = { sample -> onSampleProduced(sample) }, onLog = { m -> log(m) })
            notifyUi()
        }.start()
        updateNotification(status)
    }

    fun stopCollecting() {
        source?.stop()
        collecting = false
        updateNotification(status)
        notifyUi()
    }

    // ------------------------------------------------------------ 内部

    private fun buildSource(): HealthSource = when (sourceKind) {
        SourceKind.SENSOR_PRO -> SensorProSource(applicationContext)
        SourceKind.BLE_HEART_RATE -> BleHeartRateSource(applicationContext)
        SourceKind.SIMULATED -> SimulatedSource()
    }

    private fun restartSourceWithInterval(ms: Long) {
        source?.stop()
        source = null
        collecting = false
        startCollecting()
    }

    private fun onSampleProduced(sample: SamplePayload) {
        val p = protocol
        if (p == null) {
            queue.offer(sample)
            notifyUi()
            return
        }
        p.submit(sample)
        notifyUi()
    }

    private fun log(message: String) {
        val line = "${timeNow()}  $message"
        synchronized(logs) {
            logs.addLast(line)
            while (logs.size > MAX_LOGS) logs.removeFirst()
        }
        Log.i(TAG, message)
        notifyUi()
    }

    private fun notifyUi() {
        // ⚠️ 关键：采集线程、OkHttp 回调线程都是后台线程，而监听者会直接改 UI 控件。
        //    Android 只允许创建视图的线程（主线程）操作 View，否则抛
        //    CalledFromWrongThreadException 直接崩溃。所以这里统一切回主线程再回调。
        uiHandler.post {
            statusListener?.invoke(status, currentLogs(), collecting)
        }
    }

    private fun timeNow(): String =
        SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())

    // ------------------------------------------------------------ 通知（常驻）

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "HealthLink 采集",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "采集健康数据并上传到电脑端"
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(s: ClientStatus) {
        if (!collecting && s.state == LinkState.OFFLINE) return
        val text = when {
            collecting && s.state == LinkState.ONLINE -> "采集中 · 已连接电脑端"
            collecting -> "采集中 · 等待连接电脑端（离线缓存 ${s.queueSize} 条）"
            s.state == LinkState.ONLINE -> "已连接电脑端"
            else -> "未采集"
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun appVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "1.0.0"
    } catch (e: Exception) {
        "1.0.0"
    }

    companion object {
        private const val TAG = "CollectorService"
        const val CHANNEL_ID = "healthlink_collect"
        const val NOTIFICATION_ID = 1001
        private const val MAX_LOGS = 200
    }
}
