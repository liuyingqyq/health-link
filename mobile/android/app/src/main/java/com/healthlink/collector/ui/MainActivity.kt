package com.healthlink.collector.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.widget.Button
import android.widget.EditText
import android.widget.RadioButton
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.healthlink.collector.R
import com.healthlink.collector.protocol.ClientStatus
import com.healthlink.collector.protocol.LinkState
import com.healthlink.collector.service.CollectorService

/**
 * 主界面：填写电脑地址 → 连接 → 选择数据源 → 开始采集 → 看状态与日志。
 *
 * 与 HarmonyOS 端的界面职责一致，只是把那一套 ArkUI 换成最朴素的 View，
 * 便于你自己改（不引入 Compose，减少版本兼容问题）。
 */
class MainActivity : AppCompatActivity() {

    private var service: CollectorService? = null
    private var bound = false

    private lateinit var urlInput: EditText
    private lateinit var btnConnect: Button
    private lateinit var btnCollect: Button
    private lateinit var radioSim: RadioButton
    private lateinit var radioBle: RadioButton
    private lateinit var radioSdk: RadioButton
    private lateinit var btnScanBle: Button
    private lateinit var stateText: TextView
    private lateinit var statsText: TextView
    private lateinit var logText: TextView

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val b = binder as? CollectorService.LocalBinder ?: return
            val svc = b.service()
            service = svc
            bound = true
            svc.setStatusListener { status, logs, collecting -> render(status, logs, collecting) }
            render(svc.currentStatus(), svc.currentLogs(), svc.isCollecting())
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            bound = false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        urlInput = findViewById(R.id.inputUrl)
        btnConnect = findViewById(R.id.btnConnect)
        btnCollect = findViewById(R.id.btnCollect)
        radioSim = findViewById(R.id.radioSim)
        radioBle = findViewById(R.id.radioBle)
        radioSdk = findViewById(R.id.radioSdk)
        btnScanBle = findViewById(R.id.btnScanBle)
        stateText = findViewById(R.id.textState)
        statsText = findViewById(R.id.textStats)
        logText = findViewById(R.id.textLog)

        requestPermissionsIfNeeded()

        // 默认地址与电脑端启动器打印的一致（端口 18787），令牌要填启动器给的那串
        urlInput.setText("ws://192.168.1.100:18787/ingest?token=")

        btnConnect.setOnClickListener {
            val url = urlInput.text.toString().trim()
            if (!url.startsWith("ws")) {
                toast("地址必须以 ws:// 开头（照抄电脑端启动器打印的那一行）")
                return@setOnClickListener
            }
            if (service == null) {
                toast("服务尚未就绪，稍后再试")
                return@setOnClickListener
            }
            val kind = when {
                radioSdk.isChecked -> CollectorService.SourceKind.SENSOR_PRO
                radioBle.isChecked -> CollectorService.SourceKind.BLE_HEART_RATE
                else -> CollectorService.SourceKind.SIMULATED
            }
            service?.connect(url, kind)
            startForegroundServiceIfNeeded()
        }

        // 扫描 BLE 心率设备：列出找到的设备，点一个即连接
        btnScanBle.setOnClickListener {
            if (!radioBle.isChecked) {
                toast("请先把数据源选为「BLE 心率带」")
                return@setOnClickListener
            }
            startForegroundServiceIfNeeded()
            // 服务刚启动需要一点时间绑定，扫描放在短暂延迟后执行
            window.decorView.postDelayed({ startBleScan() }, 600)
        }

        btnCollect.setOnClickListener {
            val svc = service ?: return@setOnClickListener
            if (svc.isCollecting()) {
                svc.stopCollecting()
                btnCollect.text = getString(R.string.start_collect)
            } else {
                svc.startCollecting()
                btnCollect.text = getString(R.string.stop_collect)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        bindService(Intent(this, CollectorService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    override fun onStop() {
        super.onStop()
        if (bound) {
            service?.setStatusListener(null)
            unbindService(connection)
            bound = false
        }
    }

    // ------------------------------------------------------------ BLE 扫描

    /**
     * 扫描标准心率设备（0x180D），把结果列进对话框供选择。
     * 说明：选择「BLE 心率」数据源时，底层用 BleHeartRateSource 的扫描器；
     *      华为手表不走这里（它不广播标准心率服务）。
     */
    private fun startBleScan() {
        val svc = service
        if (svc == null) {
            toast("服务未就绪，稍后再试")
            return
        }
        // 确保数据源已创建
        if (!svc.isCollecting()) svc.startCollecting()

        val scanner = svc.deviceScanner()
        if (scanner == null) {
            toast("当前数据源不支持扫描（请选「BLE 心率带」）")
            return
        }

        val found = LinkedHashMap<String, com.healthlink.collector.source.ScannedDevice>()
        val dialog = androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("扫描心率设备中…")
            .setNegativeButton("停止扫描") { _, _ -> scanner.stopScan() }
            .create()

        scanner.startScan(
            onFound = { dev ->
                found[dev.address] = dev
                runOnUiThread {
                    dialog.setTitle("发现 ${found.size} 个设备（点一个即连接）")
                }
            },
            onLog = { msg -> runOnUiThread { dialog.setTitle(if (msg.length > 40) msg.take(40) + "…" else msg) } },
            onFinished = {
                runOnUiThread {
                    if (found.isEmpty()) {
                        dialog.setTitle("没找到心率设备")
                        dialog.setMessage(
                            "可能原因：\n" +
                                "· 心率带没电 / 没佩戴（很多心率带佩戴后才有信号）\n" +
                                "· 已被系统蓝牙或其他 App 占用（先断开系统蓝牙里的连接）\n" +
                                "· 蓝牙没打开\n\n" +
                                "注意：华为手表不广播标准心率服务，扫不到是正常的——" +
                                "手表数据请用 SensorPro 数据源。"
                        )
                    } else {
                        val list = found.values.toList()
                        val names = list.map { "${it.name}\n${it.address}  ${it.detail}" }.toTypedArray()
                        dialog.dismiss()
                        androidx.appcompat.app.AlertDialog.Builder(this)
                            .setTitle("选择要连接的心率设备")
                            .setItems(names) { _, which ->
                                val dev = list[which]
                                scanner.connect(
                                    dev,
                                    onLog = { m -> runOnUiThread { toast(m) } },
                                    onResult = { ok, msg -> runOnUiThread { toast(msg); if (ok) btnCollect.text = getString(R.string.stop_collect) } }
                                )
                            }
                            .setNegativeButton("取消", null)
                            .show()
                    }
                }
            }
        )
        dialog.show()
    }

    // ------------------------------------------------------------ 渲染

    private fun render(status: ClientStatus, logs: List<String>, collecting: Boolean) {
        // 双保险：所有 UI 更新强制在主线程执行。
        // 采集线程 / OkHttp 回调线程直接改 View 会抛
        // CalledFromWrongThreadException 并崩溃（v1.0.0 踩过一次）。
        if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            runOnUiThread { render(status, logs, collecting) }
            return
        }
        val stateLabel = when (status.state) {
            LinkState.OFFLINE -> "未连接"
            LinkState.CONNECTING -> "连接中…"
            LinkState.ONLINE -> "已连接"
            LinkState.BACKFILLING -> "补传中…"
        }
        stateText.text = getString(R.string.state_fmt, stateLabel, if (collecting) "采集中" else "未采集")

        val sb = StringBuilder()
        sb.append("设备 ID：").append(shortId(status.deviceId)).append('\n')
        sb.append("已发送：").append(status.sentTotal).append(" 条\n")
        sb.append("离线缓存：").append(status.queueSize).append(" 条")
        if (status.droppedTotal > 0) sb.append("（超限丢弃 ").append(status.droppedTotal).append("）")
        sb.append('\n')
        sb.append("采集周期：").append(status.collectIntervalMs).append(" ms\n")
        if (status.needBackfillFrom > 0) {
            sb.append("电脑要求补传自 seq ").append(status.needBackfillFrom).append('\n')
        }
        status.lastError?.let { sb.append("最近错误：").append(it).append('\n') }
        statsText.text = sb.toString()

        logText.text = logs.joinToString("\n")
        // 自动滚动到底部
        val scroll = findViewById<androidx.core.widget.NestedScrollView>(R.id.logScroll)
        scroll.post { scroll.fullScroll(android.view.View.FOCUS_DOWN) }
    }

    private fun shortId(id: String): String =
        if (id.length > 12) id.substring(0, 12) + "…" else id.ifEmpty { "（生成中）" }

    // ------------------------------------------------------------ 权限

    private fun requestPermissionsIfNeeded() {
        val need = ArrayList<String>()
        // 华为官方要求：扫描设备必须授予位置权限，否则 SDK 无法工作
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) need.add(Manifest.permission.ACCESS_FINE_LOCATION)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN)
                != PackageManager.PERMISSION_GRANTED
            ) need.add(Manifest.permission.BLUETOOTH_SCAN)
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED
            ) need.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) need.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (need.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_PERMS)
        }
    }

    private fun startForegroundServiceIfNeeded() {
        val intent = Intent(this, CollectorService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    companion object {
        private const val REQ_PERMS = 1001
    }
}
