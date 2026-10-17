package com.healthlink.collector.source

import com.healthlink.collector.protocol.SamplePayload
import java.util.Random
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * 模拟数据源：不需要任何华为权限、不需要 SDK，用来**跑通并验证整条链路**
 * （采集 → 离线队列 → 协议 → 电脑端 → 面板）。
 *
 * 产生的数据形态与真实数据源一致，所以电脑端、面板、协议都无需区别对待。
 * 心率带一点随机游走，看起来像真实读数。
 */
class SimulatedSource : HealthSource {

    override val displayName = "模拟数据（无需权限）"
    override val needsDeviceConnection = false

    private var executor: ScheduledExecutorService? = null
    private var heartRate = 72
    private var spo2 = 97
    private var stress = 38
    private val random = Random()

    override suspend fun init(): SourceInitResult =
        SourceInitResult(true, "模拟数据源就绪")

    override fun start(
        intervalMs: Long,
        onSample: (SamplePayload) -> Unit,
        onLog: (String) -> Unit
    ) {
        stop()
        val period = if (intervalMs < 1000L) 1000L else intervalMs
        val ex = Executors.newSingleThreadScheduledExecutor()
        executor = ex
        onLog("模拟采集已启动，周期 ${period}ms")

        ex.scheduleWithFixedDelay({
            try {
                val now = System.currentTimeMillis()
                onSample(heartRateSample(now))
                // 每 5 个周期补一条血氧、每 10 个补一条压力，模拟不同频率的真实采集
                tick++
                if (tick % 5 == 0) onSample(spo2Sample(now))
                if (tick % 10 == 0) onSample(stressSample(now))
                if (tick % 30 == 0) onSample(restingHeartRateSample(now))
            } catch (e: Exception) {
                onLog("模拟采集异常: ${e.message}")
            }
        }, 0L, period, TimeUnit.MILLISECONDS)
    }

    private var tick = 0

    private fun heartRateSample(now: Long): SamplePayload {
        heartRate += random.nextInt(5) - 2
        if (heartRate < 55) heartRate = 55
        if (heartRate > 110) heartRate = 110
        return SamplePayload(
            metric = "heart_rate",
            value = heartRate.toDouble(),
            unit = "bpm",
            startTime = now - 1000,
            endTime = now,
            source = "mock"
        )
    }

    private fun restingHeartRateSample(now: Long): SamplePayload = SamplePayload(
        metric = "resting_heart_rate",
        value = 62.0,
        unit = "bpm",
        startTime = now - 1000,
        endTime = now,
        source = "mock"
    )

    private fun spo2Sample(now: Long): SamplePayload {
        spo2 += random.nextInt(3) - 1
        if (spo2 < 94) spo2 = 94
        if (spo2 > 100) spo2 = 100
        return SamplePayload(
            metric = "spo2",
            value = spo2.toDouble(),
            unit = "%",
            startTime = now - 1000,
            endTime = now,
            source = "mock"
        )
    }

    private fun stressSample(now: Long): SamplePayload {
        stress += random.nextInt(5) - 2
        if (stress < 10) stress = 10
        if (stress > 90) stress = 90
        return SamplePayload(
            metric = "stress",
            value = stress.toDouble(),
            unit = "score",
            startTime = now - 1000,
            endTime = now,
            source = "mock"
        )
    }

    override fun stop() {
        executor?.shutdownNow()
        executor = null
        tick = 0
    }

    override fun statusText(): String = "模拟数据源运行中（心率 $heartRate bpm）"
}

/** 供调试：构造一条睡眠复合数据（字段与契约 3.4 节一致）。 */
fun buildMockSleepSample(now: Long): SamplePayload {
    val sleep = JSONObject()
    val fallAsleep = now - 8 * 3600_000L
    val wakeup = now
    sleep.put("fallAsleepTime", fallAsleep)
    sleep.put("wakeupTime", wakeup)
    sleep.put("duration", 8 * 3600)
    sleep.put("sleepScore", 86)
    sleep.put("sleepEfficiency", 95)
    sleep.put("deepSleepContinuity", 60)
    sleep.put("respiratoryQualityScore", 82)
    sleep.put("deepDuration", 5400)
    sleep.put("shallowDuration", 14400)
    sleep.put("dreamDuration", 5400)
    sleep.put("wakeDuration", 900)
    sleep.put("wakeCount", 2)
    sleep.put("turnOverCount", 11)
    sleep.put("sleepType", 1)
    sleep.put("sleepEndReason", 1)
    // sleepStatus 官方语义：1=深睡 2=浅睡 3=REM 4=清醒（不要把 1/2 写反）
    val segs = org.json.JSONArray()
    segs.put(JSONObject().apply {
        put("startTime", fallAsleep)
        put("endTime", fallAsleep + 5400_000L)
        put("sleepStatus", 2)   // 浅睡
    })
    segs.put(JSONObject().apply {
        put("startTime", fallAsleep + 5400_000L)
        put("endTime", fallAsleep + 9000_000L)
        put("sleepStatus", 1)   // 深睡
    })
    segs.put(JSONObject().apply {
        put("startTime", fallAsleep + 9000_000L)
        put("endTime", wakeup)
        put("sleepStatus", 3)   // REM
    })
    sleep.put("sleepSegment", segs)
    return SamplePayload(
        metric = "sleep",
        value = null,
        unit = null,
        startTime = fallAsleep,
        endTime = wakeup,
        source = "mock",
        sleep = sleep
    )
}
