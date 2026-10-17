package com.healthlink.collector.protocol

import org.json.JSONArray
import org.json.JSONObject

/** 协议版本，必须与电脑端 hub.js 的 PROTOCOL_VERSION 一致。 */
const val PROTOCOL_VERSION = 1

/**
 * 电脑端 hub.js 的 KNOWN_METRICS 白名单。
 * 发送白名单之外的 metric 会被回 nack(unknown_metric)，所以这里也做同一份约束。
 */
val KNOWN_METRICS: Set<String> = setOf(
    "heart_rate",
    "resting_heart_rate",
    "hrv",
    "spo2",
    "stress",
    "sleep",
    "sleep_nap",
    "body_temperature",
    "heart_rate_series"
)

/** 复合指标（value 必须为 null，且必须带 sleep 对象）。 */
val COMPOSITE_METRICS: Set<String> = setOf("sleep", "sleep_nap")

/**
 * 消息信封。字段与 docs/protocol/README.md 第 2 节一一对应。
 *
 * 注意：`seq` 只在**需要计数的上行数据**（hello / sample / batch）里用真实序号；
 * ack / nack / ping / pong 这类控制消息按契约固定为 0，表示"不占序号"。
 */
data class Envelope(
    val type: String,
    val seq: Long,
    val ts: Long,
    val deviceId: String,
    val payload: JSONObject
) {
    fun toJson(): String {
        val o = JSONObject()
        o.put("v", PROTOCOL_VERSION)
        o.put("type", type)
        o.put("seq", seq)
        o.put("ts", ts)
        o.put("deviceId", deviceId)
        o.put("payload", payload)
        return o.toString()
    }

    companion object {
        /** 解析下行消息；字段缺失或不是对象时返回 null（调用方按 nack/malformed 处理）。 */
        fun parse(text: String): Envelope? {
            val o = try {
                JSONObject(text)
            } catch (e: Exception) {
                return null
            }
            val type = o.optString("type", "")
            if (type.isEmpty()) return null
            return Envelope(
                type = type,
                seq = o.optLong("seq", 0L),
                ts = o.optLong("ts", 0L),
                deviceId = o.optString("deviceId", ""),
                payload = o.optJSONObject("payload") ?: JSONObject()
            )
        }
    }
}

/**
 * 一条采样数据（对应 sample.payload）。
 *
 * 构造后请调用 [validate] 自查——把电脑端的校验规则前置到发送端，
 * 避免发出去只换来一个 nack。
 */
data class SamplePayload(
    val metric: String,
    /** 复合指标（sleep/sleep_nap）必须为 null。 */
    val value: Double?,
    val unit: String?,
    val startTime: Long,
    val endTime: Long,
    val source: String,
    /** 仅 metric=sleep / sleep_nap 时非空。 */
    val sleep: JSONObject? = null,
    val extra: JSONObject? = null
) {
    /** 返回错误原因；null 表示合法。规则与电脑端 hub.js `_normalizeSample` 一致。 */
    fun validate(): String? {
        if (!KNOWN_METRICS.contains(metric)) return "未知指标 $metric"
        val composite = COMPOSITE_METRICS.contains(metric)
        if (composite) {
            if (sleep == null) return "$metric 必须带 sleep 对象"
        } else {
            if (value == null) return "value 不能为空（非复合指标）"
            if (!value.isFinite()) return "value 不是数值: $value"
        }
        if (startTime <= 0L) return "startTime 必须为正的 Unix 毫秒"
        if (endTime < startTime) return "endTime 不能早于 startTime"
        return null
    }

    fun toJson(): JSONObject {
        val o = JSONObject()
        o.put("metric", metric)
        // 复合指标的 value 显式写 null，与契约一致
        o.put("value", value ?: JSONObject.NULL)
        o.put("unit", unit ?: JSONObject.NULL)
        o.put("startTime", startTime)
        o.put("endTime", endTime)
        o.put("source", source)
        o.put("sleep", sleep ?: JSONObject.NULL)
        o.put("extra", extra ?: JSONObject())
        return o
    }

    companion object {
        fun fromJson(o: JSONObject): SamplePayload? {
            val metric = o.optString("metric", "")
            if (metric.isEmpty()) return null
            val hasValue = o.has("value") && !o.isNull("value")
            return SamplePayload(
                metric = metric,
                value = if (hasValue) o.optDouble("value") else null,
                unit = if (o.has("unit") && !o.isNull("unit")) o.optString("unit") else null,
                startTime = o.optLong("startTime", 0L),
                endTime = o.optLong("endTime", 0L),
                source = o.optString("source", "unknown"),
                sleep = o.optJSONObject("sleep"),
                extra = o.optJSONObject("extra")
            )
        }

        /** 从 JSON 数组批量解析（BatchQueue 持久化用）。 */
        fun listFromJson(arr: JSONArray): List<SamplePayload> {
            val out = ArrayList<SamplePayload>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                fromJson(o)?.let { out.add(it) }
            }
            return out
        }
    }
}

/** 协议工厂：集中构造各类消息，避免各处手写 JSON 出现字段偏差。 */
object Protocol {

    fun hello(
        seq: Long,
        deviceId: String,
        model: String,
        osVersion: String,
        appVersion: String,
        collectIntervalMs: Long,
        lastSeq: Long,
        backgroundMode: List<String>,
        sourceReady: Boolean,
        permissions: JSONObject?
    ): Envelope {
        val p = JSONObject()
        p.put("protocol", PROTOCOL_VERSION)
        p.put("model", model)
        p.put("osVersion", osVersion)
        p.put("appVersion", appVersion)
        p.put("collectIntervalMs", collectIntervalMs)
        p.put("lastSeq", lastSeq)
        p.put("backgroundMode", JSONArray(backgroundMode))
        // 契约里这个字段叫 healthStoreReady（HarmonyOS 时代的命名）。
        // Android 端数据源是可插拔的，这里语义等价地表示"数据源是否就绪"。
        p.put("healthStoreReady", sourceReady)
        p.put("permissions", permissions ?: JSONObject())
        return Envelope("hello", seq, System.currentTimeMillis(), deviceId, p)
    }

    fun sample(seq: Long, deviceId: String, sample: SamplePayload): Envelope =
        Envelope("sample", seq, System.currentTimeMillis(), deviceId, sample.toJson())

    fun batch(seq: Long, deviceId: String, samples: List<SamplePayload>, reason: String): Envelope {
        val arr = JSONArray()
        for (s in samples) arr.put(s.toJson())
        val p = JSONObject()
        p.put("samples", arr)
        p.put("count", samples.size)
        p.put("reason", reason)
        return Envelope("batch", seq, System.currentTimeMillis(), deviceId, p)
    }

    fun ping(deviceId: String): Envelope {
        val p = JSONObject()
        p.put("rtt", JSONObject.NULL)
        return Envelope("ping", 0L, System.currentTimeMillis(), deviceId, p)
    }

    fun pong(deviceId: String, echo: Long): Envelope {
        val p = JSONObject()
        p.put("echo", echo)
        return Envelope("pong", 0L, System.currentTimeMillis(), deviceId, p)
    }

    fun ack(deviceId: String, ackSeq: Long): Envelope {
        val p = JSONObject()
        p.put("ackSeq", ackSeq)
        return Envelope("ack", 0L, System.currentTimeMillis(), deviceId, p)
    }

    fun nack(deviceId: String, reason: String, detail: String?): Envelope {
        val p = JSONObject()
        p.put("reason", reason)
        if (detail != null) p.put("detail", detail)
        return Envelope("nack", 0L, System.currentTimeMillis(), deviceId, p)
    }
}

/** 补传原因枚举，取值与契约 3.3 节一致。 */
object BackfillReason {
    const val RECONNECT = "reconnect_backfill"
    const val MANUAL = "manual"
    const val APP_RESUME = "app_resume"
}
