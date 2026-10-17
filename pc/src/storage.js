'use strict';
/**
 * 样本环形缓冲。
 *
 * 为什么用环形缓冲而不是数组 + shift()：
 *   电脑端要求"断线重连后按 seq 补发"，所以必须能回答"seq > N 的所有消息"。
 *   用有界环形缓冲可以同时满足 O(1) 写入、O(log n) 定位、内存恒定不涨。
 *
 * 关键不变量：
 *   - 记录按 **到达顺序** 追加（不按 seq 排序），因为不同设备各自维护自己的 seq，
 *     全局混排后按 seq 排序没有意义。定位用的是"全局单调递增的 slot 序号"。
 *   - 每个 slot 记一个全局 `order`（从 1 开始，永不回退），二分查找按 `order` 进行。
 *   - 淘汰永远从最旧的一端开始，所以缓冲里的记录始终是"最近 capacity 条"。
 */

class SampleBuffer {
  /**
   * @param {number} capacity 最大保留条数
   */
  constructor(capacity = 20000) {
    this.capacity = Math.max(1, capacity);
    /** @type {object[]} 定长槽位 */
    this._slots = new Array(this.capacity).fill(null);
    /** @type {number[]} 每个槽位对应的全局 order，0 表示空槽 */
    this._orders = new Array(this.capacity).fill(0);
    /** 下一个写入位置 */
    this._next = 0;
    /** 已写入的总条数（= 最大 order） */
    this.size = 0;
  }

  get length() {
    return this.size;
  }

  /** 缓冲里最旧的全局 order；空缓冲返回 0 */
  get oldestOrder() {
    if (this.size === 0) return 0;
    return Math.max(1, this.size - this.capacity + 1);
  }

  /** 缓冲里最新的全局 order；空缓冲返回 0 */
  get newestOrder() {
    return this.size;
  }

  /**
   * 追加一条记录。
   * @param {object} record 至少包含 seq / deviceId / payload
   * @returns {object} 已带上 order 的记录
   */
  push(record) {
    const order = this.size + 1;
    const stored = { ...record, order };
    this._slots[this._next] = stored;
    this._orders[this._next] = order;
    this._next = (this._next + 1) % this.capacity;
    this.size = order;
    return stored;
  }

  /** 按全局 order 取一条；不存在返回 null */
  atOrder(order) {
    if (order < this.oldestOrder || order > this.size) return null;
    const idx = (order - 1) % this.capacity;
    return this._orders[idx] === order ? this._slots[idx] : null;
  }

  /**
   * 找到第一个 order >= target 的槽位下标。
   * @returns {number} 槽位下标；若 target 超过最新则返回 -1
   */
  _indexOfFirstOrderAtLeast(target) {
    if (this.size === 0) return -1;
    let lo = this.oldestOrder;
    let hi = this.size;
    if (target > hi) return -1;
    if (target <= lo) return (lo - 1) % this.capacity;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (mid < target) lo = mid + 1;
      else hi = mid;
    }
    return (lo - 1) % this.capacity;
  }

  /**
   * 遍历 [fromOrder, toOrder] 区间（闭区间）的记录，按插入顺序回调。
   * 区间会自动裁剪到缓冲实际保留范围内。
   * @returns {number} 实际回调条数
   */
  forEachInRange(fromOrder, toOrder, visitor) {
    if (this.size === 0) return 0;
    const start = Math.max(fromOrder, this.oldestOrder);
    const end = Math.min(toOrder, this.size);
    if (start > end) return 0;
    const startIdx = this._indexOfFirstOrderAtLeast(start);
    if (startIdx < 0) return 0;
    const count = end - start + 1;
    let visited = 0;
    for (let i = 0; i < count; i++) {
      const idx = (startIdx + i) % this.capacity;
      const slot = this._slots[idx];
      if (!slot) break;
      if (slot.order > end) break;
      visitor(slot);
      visited++;
    }
    return visited;
  }

  /**
   * 条件查询。
   * @param {object} filter
   * @param {string[]} [filter.deviceIds] 空数组或省略表示不限
   * @param {string[]} [filter.metrics] 空数组或省略表示不限
   * @param {number} [filter.startTime] 按 payload.endTime 过滤，含边界
   * @param {number} [filter.endTime]
   * @param {number} [filter.sinceOrder] 只要 order > 该值
   * @param {number} [filter.limit=100]
   * @param {'asc'|'desc'} [filter.order='desc']
   * @returns {{samples: object[], truncated: boolean, scanned: number}}
   */
  query(filter = {}) {
    const limit = Math.max(1, Math.min(filter.limit || 100, 100000));
    const descending = (filter.order || 'desc') === 'desc';
    const deviceSet = filter.deviceIds && filter.deviceIds.length ? new Set(filter.deviceIds) : null;
    const metricSet = filter.metrics && filter.metrics.length ? new Set(filter.metrics) : null;

    const fromOrder = filter.sinceOrder ? filter.sinceOrder + 1 : 0;
    const out = [];
    let scanned = 0;
    let truncated = false;

    // 从最新往旧扫，才能在 desc 模式下提前停止
    const newest = this.size;
    const oldest = this.oldestOrder;
    for (let order = newest; order >= Math.max(1, fromOrder, oldest); order--) {
      const rec = this.atOrder(order);
      if (!rec) continue;
      scanned++;
      const p = rec.payload || {};
      if (deviceSet && !deviceSet.has(rec.deviceId)) continue;
      if (metricSet && !metricSet.has(p.metric)) continue;
      const t = p.endTime !== undefined ? p.endTime : rec.ts;
      if (filter.startTime !== undefined && filter.startTime > 0 && t < filter.startTime) continue;
      if (filter.endTime !== undefined && filter.endTime > 0 && t > filter.endTime) continue;
      out.push(rec);
      if (out.length >= limit) {
        // 还有没有更多匹配项？只要还有没扫完的更旧记录就算截断
        truncated = order - 1 >= Math.max(1, fromOrder, oldest);
        break;
      }
    }

    if (!descending) out.reverse();
    return { samples: out, truncated, scanned };
  }

  /**
   * 按**业务 seq** 重放（供下游订阅者断线续传使用）。
   *
   * 为什么不能直接用 forEachInRange：那个方法走的是"全局插入序号 order"，
   * 而协议里订阅者的 `since` 是**发送方（手机）自己的 seq**，两者是不同空间。
   * 用 order 去比较 seq，只有在"每设备 seq 恰好等于全局计数"时才对，
   * 多设备或存在补传时会重放错数据。
   *
   * 这里的语义（与 docs/protocol/README.md 5.2 一致）：
   *   找到缓冲里**最后一条 seq <= since 的记录**（锚点），把它之后的记录按插入顺序全部回调。
   *   单设备场景下，这正好等于"该设备 seq > since 的所有消息"，因为同一设备的记录
   *   在缓冲里天然按 seq 递增排列；多设备场景下会多带回一些其他设备的消息，
   *   属于安全的方向（宁可多给，不可漏给），且下游可用 subscribe_filter 再筛。
   *
   *   **缺口判定**：找不到锚点，说明缓冲里所有记录的 seq 都 > since，
   *   即 since 之后、缓冲最旧记录之前的那段已经被淘汰掉了 —— 这时必须发 gap。
   *   （注意别写成"since 比最旧的 seq 小就算缺口"：那样 since 恰好等于
   *     oldestSeq-1 时也会误报一个根本不存在的缺口。）
   *
   * @param {number} since 业务 seq 游标
   * @param {(record: object) => void} visitor
   * @param {(gap: object) => void} [onGap] 游标太旧、缓冲里已没有对应位置时回调
   * @returns {{replayed: number, gap: object|null}}
   */
  replaySinceSeq(since, visitor, onGap) {
    if (this.size === 0) {
      // 缓冲还是空的：如果 since=0 说明下游只是要"从现在开始"，不是丢数据；
      // 只有 since>0 时才是"想要历史但一条都没有"，那才是真的缺口。
      const gap = since > 0 ? buildGap(since, 0, 0) : null;
      if (gap && onGap) onGap(gap);
      return { replayed: 0, gap };
    }
    // 从最新往旧扫，找到第一条 seq <= since 的位置
    let anchorOrder = 0; // 0 表示"since 早于缓冲内所有记录"
    let anchorSeq = null;
    let oldestSeq = null;
    let newestSeq = null;
    for (let order = this.size; order >= this.oldestOrder; order--) {
      const rec = this.atOrder(order);
      if (!rec) continue;
      const seq = Number(rec.seq) || 0;
      if (newestSeq === null) newestSeq = seq;
      oldestSeq = seq;
      if (seq <= since) {
        anchorOrder = order;
        anchorSeq = seq;
        break;
      }
    }

    let gap = null;
    if (anchorSeq === null) {
      // 缓冲里所有记录的 seq 都 > since：since 对应的位置已被淘汰，
      // 中间有一段永远补不回来了，必须如实告知下游。
      gap = buildGap(since, oldestSeq === null ? 0 : oldestSeq, 0);
    } else if (anchorOrder < this.oldestOrder) {
      // 锚点存在但**已经被淘汰出缓冲**。此时无法确定 since 之后、
      // 缓冲最旧记录之前的那段有没有发过，出于"宁可说缺、不可谎报完整"的原则，
      // 保守地按缺口处理（锚点位置视同缓冲起点之前一格）。
      anchorOrder = this.oldestOrder - 1;
      gap = buildGap(since, oldestSeq === null ? 0 : oldestSeq, 0);
    }

    // gap 必须在重放数据之前送达下游，所以这里先回调 gap，再遍历数据
    if (gap && onGap) onGap(gap);

    let replayed = 0;
    const from = anchorOrder + 1;
    this.forEachInRange(Math.max(from, this.oldestOrder), this.size, (rec) => {
      visitor(rec);
      replayed++;
    });
    if (gap) gap.lost = replayed;
    return { replayed, gap };
  }
  /** 清空（测试用） */
  clear() {
    this._slots.fill(null);
    this._orders.fill(0);
    this._next = 0;
    this.size = 0;
  }

  /** 粗略内存占用（字节），用于 /api/stats */
  estimateBytes() {
    return this.size * 320;
  }
}

/** 构造 gap 描述对象（协议 5.2 节） */
function buildGap(requestedSince, oldestAvailable, lost) {
  return { requestedSince, oldestAvailable, lost };
}

module.exports = { SampleBuffer };
