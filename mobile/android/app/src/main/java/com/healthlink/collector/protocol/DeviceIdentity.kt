package com.healthlink.collector.protocol

import android.content.Context
import java.security.SecureRandom

/**
 * 设备稳定标识。
 *
 * 契约（docs/protocol/README.md 2.1 节）要求：**应用自己持久化的随机 ID**，
 * 首次启动生成 16 字节随机数 → 32 个小写十六进制字符，之后复用。
 * 不使用任何系统设备标识（ANDROID_ID / IMEI / 序列号），因此无需敏感权限，
 * 也不会因刷机或换机而泄露硬件信息。
 *
 * ⚠️ 电脑端 hub.js `_handleHello` 会拒绝 `deviceId.length < 8` 的 hello，
 *    这里保证恒为 32 个字符。
 */
object DeviceIdentity {

    private const val PREFS = "healthlink_prefs"
    private const val KEY_DEVICE_ID = "device_id"
    private const val ID_BYTES = 16

    /** 读取，必要时生成并落盘。线程安全（synchronized）。 */
    @Synchronized
    fun get(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = prefs.getString(KEY_DEVICE_ID, null)
        if (existing != null && existing.length >= 8) return existing

        val bytes = ByteArray(ID_BYTES)
        SecureRandom().nextBytes(bytes)
        val hex = StringBuilder(ID_BYTES * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            hex.append(HEX[v ushr 4])
            hex.append(HEX[v and 0x0F])
        }
        val id = hex.toString()
        prefs.edit().putString(KEY_DEVICE_ID, id).apply()
        return id
    }

    /** 仅供测试/调试：清除已持久化的 ID（下次调用 [get] 会重新生成）。 */
    @Synchronized
    fun reset(context: Context) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_DEVICE_ID).apply()
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
