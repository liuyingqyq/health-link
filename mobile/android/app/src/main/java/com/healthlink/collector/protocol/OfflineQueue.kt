package com.healthlink.collector.protocol

import android.content.Context
import org.json.JSONArray
import java.io.File

/**
 * 离线队列：断线期间采集的数据先落盘，重连后按 `batch` 补传。
 *
 * 设计要点（对应契约 3.3 节与 7 节）：
 *  - 落盘为 JSON 文件，进程被杀也不丢；
 *  - 有容量上限（默认 20000 条），超限**丢最旧**并计入 [droppedTotal]，与电脑端
 *    relay 队列的策略保持一致（不丢最新数据）；
 *  - `drain(limit)` 取出待发数据但**不删除**，等电脑端回了 ack 再 [commit]，
 *    避免"发出去但电脑没收到"时数据凭空消失；
 *  - 电脑端单批上限 5000 条（hub.js `_handleBatch`），所以 [MAX_BATCH] 取 500。
 */
class OfflineQueue(
    context: Context,
    private val maxCapacity: Int = DEFAULT_CAPACITY,
    fileName: String = "healthlink_queue.json"
) {

    private val file = File(context.applicationContext.filesDir, fileName)
    private val lock = Any()
    private val items = ArrayList<SamplePayload>()

    /** 因超限被丢弃的累计条数（可在界面显示，便于用户知道有缺口）。 */
    var droppedTotal: Int = 0
        private set

    init {
        load()
    }

    val size: Int get() = synchronized(lock) { items.size }

    fun isEmpty(): Boolean = size == 0

    /** 入队一条。超出容量时丢最旧的一条。 */
    fun offer(sample: SamplePayload) {
        synchronized(lock) {
            items.add(sample)
            while (items.size > maxCapacity) {
                items.removeAt(0)
                droppedTotal++
            }
            persistLocked()
        }
    }

    fun offerAll(list: List<SamplePayload>) {
        synchronized(lock) {
            items.addAll(list)
            while (items.size > maxCapacity) {
                items.removeAt(0)
                droppedTotal++
            }
            persistLocked()
        }
    }

    /** 取队首最多 [limit] 条用于发送（不删除）。 */
    fun peek(limit: Int = MAX_BATCH): List<SamplePayload> = synchronized(lock) {
        if (items.isEmpty()) return emptyList()
        val n = minOf(limit, items.size)
        ArrayList(items.subList(0, n))
    }

    /**
     * 确认已成功送达：删除队首 [count] 条。
     * 电脑端 `batch` 的 ack 里带 accepted/rejected，只要整批被处理即可提交；
     * 个别被拒的条目由 ProtocolClient 记日志，不再重试（避免死循环重发）。
     */
    fun commit(count: Int) {
        synchronized(lock) {
            if (count <= 0) return
            val n = minOf(count, items.size)
            repeat(n) { items.removeAt(0) }
            persistLocked()
        }
    }

    fun clear() {
        synchronized(lock) {
            items.clear()
            persistLocked()
        }
    }

    // ------------------------------------------------------------ 持久化

    private fun persistLocked() {
        try {
            val arr = JSONArray()
            for (s in items) arr.put(s.toJson())
            // 先写临时文件再改名，避免写入中途被杀导致文件截断
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(arr.toString())
            if (file.exists()) file.delete()
            tmp.renameTo(file)
        } catch (e: Exception) {
            // 落盘失败不应让采集崩溃：内存队列仍然可用
        }
    }

    private fun load() {
        try {
            if (!file.exists()) return
            val text = file.readText()
            if (text.isBlank()) return
            val arr = JSONArray(text)
            synchronized(lock) {
                items.clear()
                items.addAll(SamplePayload.listFromJson(arr))
                // 载入后可能超过上限（例如上限被调小）
                while (items.size > maxCapacity) {
                    items.removeAt(0)
                    droppedTotal++
                }
            }
        } catch (e: Exception) {
            // 文件损坏则丢弃，避免反复抛错
        }
    }

    companion object {
        const val DEFAULT_CAPACITY = 20000
        /** 每批最多发送条数（电脑端硬上限 5000，这里取更保守的值）。 */
        const val MAX_BATCH = 500
    }
}
