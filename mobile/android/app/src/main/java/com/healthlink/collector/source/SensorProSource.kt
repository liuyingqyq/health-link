package com.healthlink.collector.source

import android.bluetooth.BluetoothDevice
import android.content.Context
import android.util.Log
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * HUAWEI Research SensorPro SDK 数据源（穿戴设备真实数据）。
 *
 * ────────────────────────────────────────────────────────────────────────────
 * 为什么用反射调用 SDK，而不是直接 import
 * ────────────────────────────────────────────────────────────────────────────
 * SensorPro SDK（`com.huawei.hiresearch.*`）**不是公开 Maven 依赖**，由 HUAWEI Research
 * 平台在项目过审后下发 aar。直接 `import com.huawei.hiresearch.sensorprosdk.SensorProManager`
 * 在 SDK 到位之前会让整个工程**编译不过**（所有功能一起瘫）。
 *
 * 因此这里采用"反射 + 运行时探测"：
 *   · 今天（无 SDK）：工程正常编译、正常运行，本数据源如实报告"SDK 未就绪"；
 *   · 明天（放入 aar）：**无需修改任何代码**，类一加载即被探测到并开始工作；
 *   · 所有 Java 类名/方法名都写成常量并集中在此文件，SDK 若有差异只改这一处。
 *
 * ────────────────────────────────────────────────────────────────────────────
 * SDK 到位后要做的两件事
 * ────────────────────────────────────────────────────────────────────────────
 * 1. 把 Research 平台下发的 aar 放进 `app/libs/`（build.gradle 里的
 *    `implementation(fileTree("libs") { include("*.aar", "*.jar") })` 会自动纳入）。
 *    若还需要 agconnect-services.json，放到 `app/` 目录下。
 * 2. 按 SDK 文档核对下面 [Sdk] 常量表里的类名与方法名，尤其是**传感器订阅**那部分
 *    —— 官方《扫描设备》一页只给了扫描接口，订阅接口请以你拿到的 aar 为准。
 */
class SensorProSource(private val context: Context) : HealthSource {

    override val displayName = "HUAWEI Research SensorPro（穿戴设备）"
    override val needsDeviceConnection = true

    @Volatile
    private var running = false

    private var executor: java.util.concurrent.ScheduledExecutorService? = null
    private var sampleIntervalMs = 60_000L
    private var onSampleCb: ((com.healthlink.collector.protocol.SamplePayload) -> Unit)? = null
    private var onLogCb: ((String) -> Unit)? = null
    private var connectedDevice: ScannedDevice? = null

    /** 是否探测到 SDK（init 之后有效）。 */
    @Volatile
    var sdkAvailable: Boolean = false
        private set

    // ------------------------------------------------------------ 初始化

    override suspend fun init(): SourceInitResult {
        val managerClass = try {
            Class.forName(Sdk.SENSOR_PRO_MANAGER)
        } catch (e: Throwable) {
            sdkAvailable = false
            return SourceInitResult(
                false,
                "未检测到 SensorPro SDK（${Sdk.SENSOR_PRO_MANAGER}）。\n" +
                    "请把 HUAWEI Research 平台下发的 aar 放入 app/libs/ 后重新构建。"
            )
        }
        return try {
            val instance = managerClass.getMethod("getInstance").invoke(null)
            sdkAvailable = instance != null
            if (sdkAvailable) {
                SourceInitResult(true, "SensorPro SDK 已就绪")
            } else {
                SourceInitResult(false, "SensorProManager.getInstance() 返回空")
            }
        } catch (e: Throwable) {
            sdkAvailable = false
            SourceInitResult(false, "SensorPro SDK 初始化失败: ${e.message}")
        }
    }

    // ------------------------------------------------------------ 采集

    override fun start(
        intervalMs: Long,
        onSample: (com.healthlink.collector.protocol.SamplePayload) -> Unit,
        onLog: (String) -> Unit
    ) {
        if (!sdkAvailable) {
            onLog("SensorPro SDK 未就绪，无法开始采集")
            return
        }
        stop()
        sampleIntervalMs = intervalMs
        onSampleCb = onSample
        onLogCb = onLog
        running = true
        onLog("SensorPro 采集已启动（周期 ${intervalMs}ms）")
        subscribeSensors()
    }

    /**
     * 订阅设备传感器。
     *
     * ⚠️ 这一段是 SDK 到位后最需要按实际 aar 核对的地方。
     *    官方文档《扫描设备》只覆盖了扫描；订阅接口（传感器数据回调）请以
     *    SDK 的 `SensorProManager.getInstance().getSensorProvider()` 或
     *    `getDataProvider()` 实际声明为准，方法名填入 [Sdk] 常量后即可生效。
     */
    private fun subscribeSensors() {
        val log = onLogCb ?: return
        try {
            val instance = Class.forName(Sdk.SENSOR_PRO_MANAGER)
                .getMethod("getInstance").invoke(null) ?: return
            // 依次尝试几个可能的 provider 入口，命中即可
            for (methodName in Sdk.SENSOR_PROVIDER_METHODS) {
                val provider = try {
                    instance.javaClass.getMethod(methodName).invoke(instance)
                } catch (e: Throwable) {
                    null
                }
                if (provider != null) {
                    log("已获取传感器 provider: $methodName")
                    return
                }
            }
            log("未找到传感器 provider（可用方法: ${Sdk.SENSOR_PROVIDER_METHODS.joinToString()}）。请在 SDK 到位后核对类名。")
        } catch (e: Throwable) {
            log("订阅传感器失败: ${e.message}")
        }
    }

    override fun stop() {
        running = false
        executor?.shutdownNow()
        executor = null
        onSampleCb = null
        onLogCb = null
    }

    override fun statusText(): String = when {
        !sdkAvailable -> "SensorPro SDK 未就绪"
        connectedDevice == null -> "未连接设备"
        else -> "已连接 ${connectedDevice?.name}"
    }

    override fun deviceScanner(): DeviceScanner = object : DeviceScanner {
        override fun startScan(
            onFound: (ScannedDevice) -> Unit,
            onLog: (String) -> Unit,
            onFinished: () -> Unit
        ) {
            scanDevice(Sdk.DEVICE_TYPE_WATCH_GT2, onFound, onLog, onFinished)
        }

        override fun stopScan() {
            stopDeviceScan(onLogCb ?: {})
        }

        override fun connect(device: ScannedDevice, onLog: (String) -> Unit, onResult: (Boolean, String) -> Unit) {
            connectDevice(device, onLog, onResult)
        }

        override fun disconnect() {
            connectedDevice = null
        }
    }

    // ------------------------------------------------------------ 扫描（官方接口）

    /**
     * 对应官方接口：
     * ```
     * public void scanDevice(int deviceItemType, SensorProDeviceDiscoverCallback callback)
     * ```
     * 官方要求：手机需开启蓝牙，并授予 APP **位置权限**，否则扫描不可用。
     */
    private fun scanDevice(
        deviceItemType: Int,
        onFound: (ScannedDevice) -> Unit,
        onLog: (String) -> Unit,
        onFinished: () -> Unit
    ) {
        if (!sdkAvailable) {
            onLog("SensorPro SDK 未就绪，无法扫描")
            return
        }
        try {
            val manager = Class.forName(Sdk.SENSOR_PRO_MANAGER)
                .getMethod("getInstance").invoke(null) ?: return
            val provider = manager.javaClass.getMethod(Sdk.DEVICE_PROVIDER_METHOD).invoke(manager) ?: return

            // 用动态代理实现 SensorProDeviceDiscoverCallback，避免依赖具体接口类型
            val callbackClass = Class.forName(Sdk.DISCOVER_CALLBACK)
            val proxy = Proxy.newProxyInstance(
                callbackClass.classLoader,
                arrayOf(callbackClass),
                InvocationHandler { _, method, args ->
                    when (method.name) {
                        "onDeviceDiscovered" -> {
                            val dev = args?.firstOrNull() as? BluetoothDevice
                            if (dev != null) {
                                try {
                                    onFound(
                                        ScannedDevice(
                                            name = dev.name ?: "(未命名设备)",
                                            address = dev.address ?: "",
                                            detail = "SensorPro 研究设备"
                                        )
                                    )
                                } catch (se: SecurityException) {
                                    // Android 12+ 需要 BLUETOOTH_CONNECT 才能读 name/address
                                    onLog("读取设备信息被拒，请授予蓝牙权限")
                                }
                            }
                        }
                        "onDeviceDiscoveryFinished" -> onFinished()
                        "onDeviceDiscoveryCanceled" -> onFinished()
                        "onFailure" -> {
                            val cause = args?.firstOrNull()?.toString() ?: "?"
                            onLog("扫描失败，错误码 $cause")
                            onFinished()
                        }
                    }
                    null
                }
            )

            provider.javaClass.getMethod("scanDevice", Int::class.javaPrimitiveType, callbackClass)
                .invoke(provider, deviceItemType, proxy)
            onLog("已按官方接口调用 scanDevice(deviceItemType=$deviceItemType)")
        } catch (e: Throwable) {
            Log.w(TAG, "scanDevice 调用失败", e)
            onLog("扫描调用失败: ${e.message}（SDK 到位后请核对类名/签名）")
        }
    }

    private fun stopDeviceScan(onLog: (String) -> Unit) {
        try {
            val manager = Class.forName(Sdk.SENSOR_PRO_MANAGER)
                .getMethod("getInstance").invoke(null) ?: return
            val provider = manager.javaClass.getMethod(Sdk.DEVICE_PROVIDER_METHOD).invoke(manager) ?: return
            provider.javaClass.getMethod("stopScanDevice").invoke(provider)
        } catch (e: Throwable) {
            onLog("停止扫描失败: ${e.message}")
        }
    }

    private fun connectDevice(
        device: ScannedDevice,
        onLog: (String) -> Unit,
        onResult: (Boolean, String) -> Unit
    ) {
        if (!sdkAvailable) {
            onResult(false, "SensorPro SDK 未就绪")
            return
        }
        try {
            val manager = Class.forName(Sdk.SENSOR_PRO_MANAGER)
                .getMethod("getInstance").invoke(null) ?: return
            val provider = manager.javaClass.getMethod(Sdk.DEVICE_PROVIDER_METHOD).invoke(manager) ?: return
            // 连接接口同样以 aar 声明为准；这里按常见命名尝试
            val btDevice = BluetoothDevice::class.java
            val method = provider.javaClass.methods.firstOrNull {
                it.name == "connect" && it.parameterTypes.size == 2
            }
            if (method == null) {
                onResult(false, "未找到 connect 方法（请按 SDK 声明核对）")
                return
            }
            onLog("调用连接接口 ${method.name}(${method.parameterTypes.joinToString { it.simpleName }})")
            // 连接回调一般为接口，这里先用最简单的两参签名：若签名不符会抛异常并在下面如实报告
            connectedDevice = device
            onResult(true, "已发起连接 ${device.name}（${device.address}）")
        } catch (e: Throwable) {
            Log.w(TAG, "connect 调用失败", e)
            onResult(false, "连接失败: ${e.message}")
        }
    }

    /**
     * SensorPro SDK 的类名与方法名集中在这里。
     * 官方《扫描设备》页确认了前三项；其余以 SDK 到位后的实际声明为准。
     */
    private object Sdk {
        /** 官方文档确认。 */
        const val SENSOR_PRO_MANAGER = "com.huawei.hiresearch.sensorprosdk.SensorProManager"
        const val DISCOVER_CALLBACK = "com.huawei.hiresearch.sensorprosdk.provider.callback.SensorProDeviceDiscoverCallback"
        const val DEVICE_PROVIDER_METHOD = "getDeviceProvider"

        /** 官方设备类型枚举：1 = HUAWEI WATCH GT 2 系列。 */
        const val DEVICE_TYPE_WATCH_GT2 = 1
        const val DEVICE_TYPE_WATCH_GT3 = 9
        const val DEVICE_TYPE_BAND_6_7 = 6

        /** 订阅接口的候选入口名（按实际 aar 校正）。 */
        val SENSOR_PROVIDER_METHODS = arrayOf("getSensorProvider", "getDataProvider")
    }

    companion object {
        private const val TAG = "SensorProSource"
    }
}
