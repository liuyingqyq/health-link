package com.healthlink.collector.source

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import com.healthlink.collector.protocol.SamplePayload
import java.util.UUID

/**
 * BLE 心率数据源：连接**标准蓝牙心率设备**（心率带等）读取实时心率。
 *
 * ────────────────────────────────────────────────────────────────────────────
 * 适用与不适用
 * ────────────────────────────────────────────────────────────────────────────
 * ✅ 能用：心率带（Polar H10、迈欧、各种胸带）、暴露标准心率服务的运动表/手环
 * ❌ 不能用：**华为手表/手环**——它们只通过私有协议与"华为运动健康"通信，
 *            不向外广播标准 `0x180D` 服务。这是设备限制，不是代码问题。
 *            华为手表的数据请走 HUAWEI Research SensorPro（见 SensorProSource）。
 *
 * ────────────────────────────────────────────────────────────────────────────
 * 协议要点（蓝牙 SIG 官方定义）
 * ────────────────────────────────────────────────────────────────────────────
 * · 服务 UUID：`0000180D-0000-1000-8000-00805F9B34FB`（Heart Rate）
 * · 特征 UUID：`00002A37-0000-1000-8000-00805F9B34FB`（Heart Rate Measurement）
 * · 数据格式：第 1 字节是标志位(flags)，**bit0=0 表示心率是 uint8，bit0=1 表示 uint16**
 *   （小端）。很多实现写死读第二个字节，遇到 16 位设备就出错，这里按官方规范解析。
 * · 订阅方式：向 CCCD 描述符 `00002902-...` 写 `ENABLE_NOTIFICATION_VALUE`。
 *
 * ⚠️ Android 12(API 31) 起蓝牙改为运行时权限：BLUETOOTH_SCAN / BLUETOOTH_CONNECT，
 *    且定位权限对 BLE 扫描仍然必要。这些已在 AndroidManifest 声明并在主界面申请。
 */
class BleHeartRateSource(private val context: Context) : HealthSource {

    override val displayName = "BLE 心率带（标准 0x180D）"
    override val needsDeviceConnection = true

    @Volatile
    private var running = false
    private var onSample: ((SamplePayload) -> Unit)? = null
    private var onLog: ((String) -> Unit)? = null
    private var sampleHandler: Handler? = null

    private var adapter: BluetoothAdapter? = null
    private var scannerCallback: ScanCallback? = null
    private var gatt: BluetoothGatt? = null
    private var hrCharacteristic: BluetoothGattCharacteristic? = null

    @Volatile
    private var connectedAddress: String? = null

    @Volatile
    private var connectedName: String = ""

    /** 上一次上报时间：心率带通常每秒推一次，这里节流到 [MIN_REPORT_INTERVAL_MS] 以免刷爆面板 */
    @Volatile
    private var lastReportAt = 0L

    private val mainHandler = Handler(Looper.getMainLooper())

    override suspend fun init(): SourceInitResult {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val ad = manager?.adapter
            ?: return SourceInitResult(false, "这台设备没有蓝牙适配器")
        adapter = ad
        if (!ad.isEnabled) {
            return SourceInitResult(false, "蓝牙未打开，请先在系统设置里打开蓝牙")
        }
        return SourceInitResult(true, "BLE 心率数据源就绪（需先连接心率带）")
    }

    override fun start(
        intervalMs: Long,
        onSample: (SamplePayload) -> Unit,
        onLog: (String) -> Unit
    ) {
        this.onSample = onSample
        this.onLog = onLog
        running = true
        sampleHandler = Handler(Looper.getMainLooper())
        onLog("BLE 采集已启动：等待心率数据（请先连接心率带）")
    }

    override fun stop() {
        running = false
        sampleHandler?.removeCallbacksAndMessages(null)
        sampleHandler = null
        onSample = null
        onLog = null
    }

    override fun statusText(): String = when {
        !running -> "未启动"
        connectedAddress == null -> "未连接心率设备（点「连接设备」扫描）"
        else -> "已连接 $connectedName，心率 $lastBpm bpm"
    }

    override fun deviceScanner(): DeviceScanner = object : DeviceScanner {
        override fun startScan(
            onFound: (ScannedDevice) -> Unit,
            onLog: (String) -> Unit,
            onFinished: () -> Unit
        ) = scanDevices(onFound, onLog, onFinished)

        override fun stopScan() = stopScanInternal()
        override fun connect(device: ScannedDevice, onLog: (String) -> Unit, onResult: (Boolean, String) -> Unit) =
            connectDevice(device, onLog, onResult)

        override fun disconnect() = disconnectDevice()
    }

    // ------------------------------------------------------------ 扫描

    @SuppressLint("MissingPermission")
    private fun scanDevices(
        onFound: (ScannedDevice) -> Unit,
        onLog: (String) -> Unit,
        onFinished: () -> Unit
    ) {
        val ad = adapter
        if (ad == null) {
            onLog("蓝牙适配器不可用")
            return
        }
        stopScanInternal()

        // ⚠️ serviceUuid 必须是 **128 位完整 UUID**。这是本项目在 OpenHarmony 端踩过的坑：
        //    传短格式 "180D" 会直接报参数错误；Android 的 ParcelUuid 同样要求完整 UUID。
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(UUID.fromString(HR_SERVICE)))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val name = try {
                    result.device.name ?: "(未命名心率设备)"
                } catch (se: SecurityException) {
                    "(需要蓝牙权限)"
                }
                onFound(
                    ScannedDevice(
                        name = name,
                        address = result.device.address ?: "",
                        detail = "信号 ${result.rssi} dBm · 标准心率服务"
                    )
                )
            }

            override fun onScanFailed(errorCode: Int) {
                val hint = when (errorCode) {
                    1 -> "蓝牙未授权或参数不合法"
                    2 -> "蓝牙未打开"
                    3 -> "系统内部错误"
                    else -> "未知原因"
                }
                onLog("扫描失败（错误码 $errorCode：$hint）")
                onFinished()
            }
        }
        scannerCallback = cb
        val scanner = ad.bluetoothLeScanner
        if (scanner == null) {
            onLog("蓝牙扫描器不可用")
            return
        }
        scanner.startScan(listOf(filter), settings, cb)
        onLog("开始扫描标准心率设备（过滤 0x180D）…")
    }

    @SuppressLint("MissingPermission")
    private fun stopScanInternal() {
        val cb = scannerCallback ?: return
        try {
            adapter?.bluetoothLeScanner?.stopScan(cb)
            onLog?.invoke("已停止扫描")
        } catch (e: Exception) {
            Log.w(TAG, "停止扫描异常", e)
        }
        scannerCallback = null
    }

    // ------------------------------------------------------------ 连接与订阅

    /**
     * 连接设备。
     * ⚠️ Android 的 `connectGatt` 里**顺序很关键**：不传 autoConnect、
     *    用 `TRANSPORT_LE`，并且在 `onConnectionStateChange` 里才调 `discoverServices()`。
     */
    @SuppressLint("MissingPermission")
    private fun connectDevice(
        device: ScannedDevice,
        onLog: (String) -> Unit,
        onResult: (Boolean, String) -> Unit
    ) {
        val ad = adapter
        if (ad == null) {
            onResult(false, "蓝牙不可用")
            return
        }
        try {
            val remote = ad.getRemoteDevice(device.address)
            connectedName = device.name
            gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                remote.connectGatt(context, false, gattCallback, android.bluetooth.BluetoothDevice.TRANSPORT_LE)
            } else {
                remote.connectGatt(context, false, gattCallback)
            }
            onLog("正在连接 ${device.name}（${device.address}）…")
            onResult(true, "已发起连接")
        } catch (e: Exception) {
            Log.w(TAG, "连接失败", e)
            onResult(false, "连接失败: ${e.message}")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    onLog?.invoke("设备已连接，正在发现服务…")
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    connectedAddress = null
                    onLog?.invoke("设备已断开（status=$status）")
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                onLog?.invoke("服务发现失败 status=$status")
                return
            }
            val service = g.getService(UUID.fromString(HR_SERVICE))
            if (service == null) {
                onLog?.invoke("该设备没有标准心率服务（0x180D）——很可能不是标准心率设备")
                return
            }
            val ch = service.getCharacteristic(UUID.fromString(HR_MEASUREMENT))
            if (ch == null) {
                onLog?.invoke("有 0x180D 服务但缺少 0x2A37 特征")
                return
            }
            hrCharacteristic = ch
            connectedAddress = g.device.address
            g.setCharacteristicNotification(ch, true)

            // 必须写 CCCD 才能真正收到通知
            val cccd = ch.getDescriptor(UUID.fromString(CCCD))
            if (cccd != null) {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
                onLog?.invoke("已订阅心率通知（0x2A37），等待数据…")
            } else {
                onLog?.invoke("特征缺少 CCCD 描述符，可能收不到通知")
            }
        }

        // Android 13(API 33) 起推荐用带 value 参数的重载
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            handleHeartRate(ch.value)
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            handleHeartRate(value)
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                onLog?.invoke("订阅成功，开始接收心率数据")
            } else {
                onLog?.invoke("CCCD 写入失败 status=$status")
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun disconnectDevice() {
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            Log.w(TAG, "断开异常", e)
        }
        gatt = null
        hrCharacteristic = null
        connectedAddress = null
    }

    // ------------------------------------------------------------ 数据解析

    private var lastBpm = 0

    /**
     * 解析 Heart Rate Measurement（官方规范）：
     *   byte0 = flags
     *      bit0: 0 → 心率为 uint8（byte1）；1 → 心率为 uint16 小端（byte1+byte2）
     *      bit3: 1 → 存在能量消耗字段
     *      bit4: 1 → 存在 RR 间期
     * 只取心率值；解析失败或越界则忽略，宁可丢点也不要污染曲线。
     */
    private fun handleHeartRate(value: ByteArray?) {
        if (value == null || value.size < 2) return
        try {
            val flags = value[0].toInt() and 0xFF
            val isUint16 = (flags and 0x01) == 0x01
            val bpm = if (isUint16) {
                if (value.size < 3) return
                (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
            } else {
                value[1].toInt() and 0xFF
            }

            // 未佩戴时很多设备上报 0，直接忽略
            if (bpm < HR_MIN || bpm > HR_MAX) {
                onLog?.invoke("心率 $bpm 超出合理范围，忽略（可能未佩戴）")
                return
            }
            lastBpm = bpm

            // 节流：心率带常 1Hz 上报，按最小间隔上报，避免刷爆电脑端
            val now = System.currentTimeMillis()
            if (now - lastReportAt < MIN_REPORT_INTERVAL_MS) return
            lastReportAt = now

            val payload = SamplePayload(
                metric = "heart_rate",
                value = bpm.toDouble(),
                unit = "bpm",
                startTime = now - 1000,
                endTime = now,
                source = "ble"
            )
            val handler = sampleHandler
            if (handler != null) handler.post { onSample?.invoke(payload) }
            else onSample?.invoke(payload)
        } catch (e: Exception) {
            onLog?.invoke("心率解析异常: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "BleHeartRateSource"

        /** 标准心率服务（蓝牙 SIG 定义，128 位完整 UUID） */
        const val HR_SERVICE = "0000180D-0000-1000-8000-00805F9B34FB"
        /** 心率测量特征 */
        const val HR_MEASUREMENT = "00002A37-0000-1000-8000-00805F9B34FB"
        /** 客户端特征配置描述符，必须写它才能收到通知 */
        const val CCCD = "00002902-0000-1000-8000-00805F9B34FB"

        private const val HR_MIN = 25
        private const val HR_MAX = 250
        /** 最小上报间隔（毫秒）：5 秒一个点，与 HarmonyOS 端 BLE 数据源的节流一致 */
        private const val MIN_REPORT_INTERVAL_MS = 5000L
    }
}
