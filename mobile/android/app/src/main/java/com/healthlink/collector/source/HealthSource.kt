package com.healthlink.collector.source

import com.healthlink.collector.protocol.SamplePayload

/**
 * 数据源抽象 —— 这是整个工程最重要的一个接口。
 *
 * 与 HarmonyOS 端 `HealthSource` 同样的思路：采集编排（长时任务、离线队列、
 * 断线重传、协议）只认这个接口，**换数据源不影响任何其他代码**。
 *
 * 已规划的两种实现：
 *  - [SensorProSource]  ：HUAWEI Research SensorPro SDK（穿戴设备真实数据）
 *  - [SimulatedSource]  ：模拟源，用于在没有 SDK / 没有批件时跑通全链路
 *
 * 若要接标准 BLE 心率带，只需再加一个 [BleHeartRateSource] 实现本接口。
 */
interface HealthSource {

    /** 数据源显示名，用于界面。 */
    val displayName: String

    /** 是否需要"扫描/连接设备"这一前置步骤（模拟源不需要）。 */
    val needsDeviceConnection: Boolean

    /**
     * 初始化数据源（例如 SDK 初始化、权限检查）。
     * @return 初始化结果；失败时 [SourceInitResult.message] 给出原因。
     */
    suspend fun init(): SourceInitResult

    /**
     * 开始产出数据。
     * @param intervalMs 采样周期；来源可能是电脑端下发的值（契约 4.1）。
     * @param onSample 每产出一条数据回调一次
     * @param onLog 运行日志回调（直接展示给用户，便于排查）
     */
    fun start(
        intervalMs: Long,
        onSample: (SamplePayload) -> Unit,
        onLog: (String) -> Unit
    )

    /** 停止产出并释放资源。 */
    fun stop()

    /** 供界面展示的状态描述。 */
    fun statusText(): String

    /** 若数据源支持设备扫描，返回它；否则 null。 */
    fun deviceScanner(): DeviceScanner? = null
}

data class SourceInitResult(val ok: Boolean, val message: String)

/** 设备扫描/连接能力（SensorPro 与 BLE 数据源会实现它）。 */
interface DeviceScanner {
    /** 开始扫描。 */
    fun startScan(onFound: (ScannedDevice) -> Unit, onLog: (String) -> Unit, onFinished: () -> Unit)

    fun stopScan()

    /** 连接指定设备。 */
    fun connect(device: ScannedDevice, onLog: (String) -> Unit, onResult: (Boolean, String) -> Unit)

    fun disconnect()
}

data class ScannedDevice(
    val name: String,
    /** 设备地址（Android 上是 MAC，注意是虚拟地址）。 */
    val address: String,
    /** 额外信息，例如设备类型、信号强度。 */
    val detail: String = ""
)
