'use strict';
/*!
 * HealthLink 面板图表模块（零依赖，纯 Canvas 2D 手写）
 *
 *  - SeriesChart      : 多设备折线图。时间窗口过滤 / Y 轴自适应 / 高 DPI(devicePixelRatio)
 *                       / 空数据不崩 / requestAnimationFrame 节流重绘 / 乱序样本(补传)二分插入
 *  - renderSleepBand  : 按 sleepSegment.sleepStatus 画睡眠分期色带（绝对定位按时间比例）
 *  - SLEEP_COLORS / SLEEP_NAMES : 协议 v1 官方 sleepStatus 取值（0..7）的配色与中文名
 *
 * 由 index.html 用 <script src> 引入，挂载到 window.HealthChart；重复引入无副作用。
 */
window.HealthChart = window.HealthChart || (function () {
  /* 多设备配色（不同设备自动取不同颜色，循环使用） */
  var PALETTE = ['#4dabf7', '#ffa94d', '#63e6be', '#b197fc', '#ffd43b', '#ff8787', '#74c0fc', '#a9e34b'];

  /* 协议 v1：sleepStatus 官方取值配色（严禁改动语义） */
  var SLEEP_COLORS = {
    0: '#dee2e6', 1: '#3b5bdb', 2: '#4dabf7', 3: '#b197fc', 4: '#ffa94d',
    5: '#63e6be', 6: '#adb5bd', 7: '#868e96'
  };
  var SLEEP_NAMES = {
    0: '未知', 1: '深睡', 2: '浅睡', 3: 'REM', 4: '清醒', 5: '小睡', 6: '卧床', 7: '手动记录'
  };

  var PAD = { l: 46, r: 12, t: 10, b: 22 };
  var MAX_POINTS = 20000;        /* 单设备单指标内存上限，超出丢最旧 */
  var FULL_WINDOW_MS = 3600000;  /* 面板可选的最大窗口（60 分钟）。裁点按最大窗口保留，
                                    这样 1 分钟 → 60 分钟切换时历史不会被提前丢掉 */

  function pad2(n) { return n < 10 ? '0' + n : String(n); }

  /** 本地时区 HH:mm:ss（契约第 7 节技术要求） */
  function hhmmss(ts) {
    var n = Number(ts);
    if (!isFinite(n) || n <= 0) return '—';
    var d = new Date(n);
    return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
  }

  /** deviceId 截断显示：8 位 + … + 末 3 位 */
  function shortId(id) {
    var s = id === null || id === undefined ? '?' : String(id);
    return s.length <= 14 ? s : s.slice(0, 8) + '…' + s.slice(-3);
  }

  function fmtNum(v) {
    if (!isFinite(v)) return '—';
    return Number.isInteger(v) ? String(v) : String(Math.round(v * 10) / 10);
  }

  /** 毫秒 → 「7 小时 12 分」 */
  function fmtDur(ms) {
    var n = Number(ms);
    if (!isFinite(n) || n < 0) return '—';
    var total = Math.round(n / 1000);
    var h = Math.floor(total / 3600), m = Math.round((total % 3600) / 60);
    return h ? h + ' 小时 ' + m + ' 分' : m + ' 分';
  }

  /** Y 轴自适应：把数据区间扩到「整齐」的上下界；单值/空数据也能返回可用区间 */
  function niceRange(min, max) {
    if (!isFinite(min) || !isFinite(max)) return [0, 1];
    if (min === max) {
      var d = Math.abs(min) > 1 ? Math.abs(min) * 0.05 : 1;
      min -= d; max += d;
    }
    var span = max - min;
    var step = Math.pow(10, Math.floor(Math.log(span) / Math.LN10));
    if (!isFinite(step) || step <= 0) step = 1;
    var lo = Math.floor(min / step) * step;
    var hi = Math.ceil(max / step) * step;
    if (hi <= lo) hi = lo + step;
    return [lo, hi];
  }

  /* ============================ 折线图 ============================ */
  function SeriesChart(canvas, opts) {
    opts = opts || {};
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.windowMs = opts.windowMs || 600000;
    this.unit = opts.unit || '';
    this.legendEl = opts.legendEl || null;
    this.latestEl = opts.latestEl || null;
    this.series = new Map();   /* deviceId -> { color, points:[{t,v}], last:{t,v} } */
    this.order = [];           /* 设备出现顺序，决定图例顺序 */
    this.colorCursor = 0;
    this._raf = 0;
    this._legendKey = '';
    this.invalidate();
  }

  /** 取（或创建）某设备的序列，并分配颜色 */
  SeriesChart.prototype.seriesFor = function (deviceId) {
    var s = this.series.get(deviceId);
    if (!s) {
      s = { color: PALETTE[this.colorCursor++ % PALETTE.length], points: [], last: null };
      this.series.set(deviceId, s);
      this.order.push(deviceId);
      this._legendKey = ''; /* 强制重建图例 */
    }
    return s;
  };

  /** 追加一个数据点；返回是否被接受（非有限值直接忽略，不会崩） */
  SeriesChart.prototype.addPoint = function (deviceId, t, v) {
    if (!isFinite(v) || !isFinite(t)) return false;
    var s = this.seriesFor(deviceId);
    var pts = s.points;
    if (!pts.length || t >= pts[pts.length - 1].t) {
      pts.push({ t: t, v: v });
    } else {
      /* 补传样本可能乱序：二分插入保持时间升序 */
      var lo = 0, hi = pts.length;
      while (lo < hi) {
        var mid = (lo + hi) >> 1;
        if (pts[mid].t <= t) lo = mid + 1; else hi = mid;
      }
      pts.splice(lo, 0, { t: t, v: v });
    }
    if (pts.length > MAX_POINTS) pts.splice(0, pts.length - MAX_POINTS);
    if (!s.last || t >= s.last.t) s.last = { t: t, v: v };
    this.invalidate();
    return true;
  };

  SeriesChart.prototype.setWindow = function (ms) {
    if (!isFinite(ms) || ms <= 0) return;
    this.windowMs = ms;
    this.invalidate();
  };

  SeriesChart.prototype.resize = function () { this.invalidate(); };

  /** rAF 节流：一帧内多次数据到达只重绘一次 */
  SeriesChart.prototype.invalidate = function () {
    if (this._raf) return;
    var self = this;
    this._raf = requestAnimationFrame(function () {
      self._raf = 0;
      try { self.draw(); } catch (e) { if (window.console) console.warn('[HealthChart] 绘制失败', e); }
    });
  };

  SeriesChart.prototype.draw = function () {
    var canvas = this.canvas, ctx = this.ctx;
    var cssW = canvas.clientWidth, cssH = canvas.clientHeight;
    if (!cssW || !cssH) { this.updateLegend(); this.updateLatest(); return; } /* 隐藏/未布局：不崩 */

    /* 高 DPI：位图尺寸 = CSS 尺寸 * devicePixelRatio */
    var dpr = window.devicePixelRatio || 1;
    var w = Math.max(1, Math.round(cssW * dpr)), h = Math.max(1, Math.round(cssH * dpr));
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);

    var plotW = Math.max(1, cssW - PAD.l - PAD.r);
    var plotH = Math.max(1, cssH - PAD.t - PAD.b);
    var t1 = Date.now();
    var t0 = t1 - this.windowMs;

    /* 时间窗口过滤 + 顺手裁掉早已出窗口的点（按最大可选窗口保留，切换窗口不丢历史） */
    var cut = t1 - Math.max(this.windowMs, FULL_WINDOW_MS) * 1.1;
    var vis = [], min = Infinity, max = -Infinity, newest = null, visible = 0;
    this.series.forEach(function (s, id) {
      var k = 0, pts = s.points;
      while (k < pts.length && pts[k].t < cut) k++;
      if (k) pts.splice(0, k);
      var arr = [];
      for (var i = 0; i < pts.length; i++) {
        var p = pts[i];
        if (p.t < t0) continue;
        if (p.t > t1) break;
        arr.push(p);
        visible++;
        if (p.v < min) min = p.v;
        if (p.v > max) max = p.v;
        if (!newest || p.t >= newest.t) newest = { t: p.t, v: p.v, id: id };
      }
      if (arr.length) vis.push({ color: s.color, pts: arr });
    });

    ctx.font = '11px Consolas, monospace';
    ctx.lineWidth = 1;
    var range = niceRange(min, max);
    var lo = range[0], hi = range[1];

    /* 横向网格 + Y 轴刻度（自适应） */
    ctx.strokeStyle = 'rgba(148,163,184,0.16)';
    ctx.fillStyle = '#8b98ab';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    for (var g = 0; g <= 3; g++) {
      var gy = PAD.t + (plotH * g) / 3;
      ctx.beginPath();
      ctx.moveTo(PAD.l, gy + 0.5);
      ctx.lineTo(PAD.l + plotW, gy + 0.5);
      ctx.stroke();
      ctx.fillText(fmtNum(hi - ((hi - lo) * g) / 3), PAD.l - 6, gy);
    }

    /* 纵向网格 + 时间轴（本地时区 HH:mm:ss） */
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    for (var x = 0; x <= 2; x++) {
      var gx = PAD.l + (plotW * x) / 2;
      ctx.beginPath();
      ctx.moveTo(gx + 0.5, PAD.t);
      ctx.lineTo(gx + 0.5, PAD.t + plotH);
      ctx.stroke();
      var xLabel = x === 0 ? hhmmss(t0) : (x === 1 ? hhmmss((t0 + t1) / 2) : hhmmss(t1));
      ctx.fillText(xLabel, gx === PAD.l ? gx + 16 : (x === 2 ? gx - 16 : gx), PAD.t + plotH + 5);
    }

    /* 空数据：画提示文字，绝不抛错 */
    if (!visible) {
      ctx.fillStyle = '#6b7688';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('该窗口内暂无数据', PAD.l + plotW / 2, PAD.t + plotH / 2);
      this.updateLegend();
      this.updateLatest();
      return;
    }

    /* 逐设备折线（不同设备不同颜色） */
    for (var s = 0; s < vis.length; s++) {
      var pts2 = vis[s].pts, color = vis[s].color;
      ctx.strokeStyle = color;
      ctx.fillStyle = color;
      ctx.lineWidth = 1.6;
      ctx.lineJoin = 'round';
      ctx.beginPath();
      var px = 0, py = 0;
      for (var i2 = 0; i2 < pts2.length; i2++) {
        px = PAD.l + ((pts2[i2].t - t0) / this.windowMs) * plotW;
        py = PAD.t + plotH - ((pts2[i2].v - lo) / (hi - lo)) * plotH;
        if (i2 === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      }
      if (pts2.length === 1) { ctx.beginPath(); ctx.arc(px, py, 2.4, 0, Math.PI * 2); ctx.fill(); }
      else ctx.stroke();
    }

    if (newest) {
      var nx = PAD.l + ((newest.t - t0) / this.windowMs) * plotW;
      var ny = PAD.t + plotH - ((newest.v - lo) / (hi - lo)) * plotH;
      ctx.strokeStyle = 'rgba(255,255,255,0.55)';
      ctx.beginPath();
      ctx.arc(nx, ny, 2.6, 0, Math.PI * 2);
      ctx.stroke();
    }

    this.updateLegend();
    this.updateLatest();
  };

  /** 图例：设备短 id + 颜色（只有变化时才重建 DOM） */
  SeriesChart.prototype.updateLegend = function () {
    var el = this.legendEl;
    if (!el) return;
    var self = this;
    var key = this.order.map(function (id) { return id + ':' + self.series.get(id).color; }).join('|');
    if (key === this._legendKey) return;
    this._legendKey = key;
    el.textContent = '';
    if (!this.order.length) {
      var t = document.createElement('span');
      t.className = 'legend-item';
      t.textContent = '等待数据…';
      el.appendChild(t);
      return;
    }
    this.order.forEach(function (id) {
      var item = document.createElement('span');
      item.className = 'legend-item';
      var dot = document.createElement('i');
      dot.style.background = self.series.get(id).color;
      var txt = document.createElement('span');
      txt.textContent = shortId(id);
      item.appendChild(dot);
      item.appendChild(txt);
      el.appendChild(item);
    });
  };

  /** 最新值读数：取所有设备里时间最新的一个点 */
  SeriesChart.prototype.updateLatest = function () {
    var el = this.latestEl;
    if (!el) return;
    var newest = null;
    this.series.forEach(function (s, id) {
      if (s.last && (!newest || s.last.t >= newest.t)) newest = { t: s.last.t, v: s.last.v, id: id };
    });
    var text = newest
      ? fmtNum(newest.v) + (this.unit ? ' ' + this.unit : '') + ' · ' + shortId(newest.id)
      : '—';
    if (el.textContent !== text) el.textContent = text;
  };

  /* ======================= 睡眠分期色带 ======================= */
  /**
   * 把 sleepSegment 画成色带并按时间比例定位。
   * @param {HTMLElement} host 容器
   * @param {object} sleep sample.payload.sleep
   * @returns {{stats:Array,segments:number,t0:number,t1:number}} 供面板做统计展示
   */
  function renderSleepBand(host, sleep) {
    host.textContent = '';
    var raw = sleep && Array.isArray(sleep.sleepSegment) ? sleep.sleepSegment : [];
    var segs = [];
    for (var i = 0; i < raw.length; i++) {
      var s = raw[i];
      if (!s) continue;
      var st = Number(s.startTime), et = Number(s.endTime);
      if (isFinite(st) && isFinite(et) && et > st) segs.push({ startTime: st, endTime: et, sleepStatus: s.sleepStatus });
    }
    segs.sort(function (a, b) { return a.startTime - b.startTime; });

    var stats = new Map();
    if (!segs.length) {
      /* 缺失 sleepSegment：优雅降级，不报错 */
      var empty = document.createElement('div');
      empty.className = 'sleep-empty muted';
      empty.textContent = '该记录未提供 sleepSegment 分期明细，无法绘制色带（已优雅降级）。';
      host.appendChild(empty);
      return { stats: [], segments: 0, t0: 0, t1: 0 };
    }

    var t0 = segs[0].startTime, t1 = segs[segs.length - 1].endTime;
    var span = Math.max(1, t1 - t0);
    var band = document.createElement('div');
    band.className = 'sleep-band';
    for (var k = 0; k < segs.length; k++) {
      var seg = segs[k];
      var status = SLEEP_COLORS[seg.sleepStatus] !== undefined ? Number(seg.sleepStatus) : 0;
      var box = document.createElement('div');
      box.className = 'sleep-seg';
      /* 相对整段睡眠做比例定位（百分比），宽度保底可见 */
      box.style.left = (((seg.startTime - t0) / span) * 100).toFixed(3) + '%';
      box.style.width = Math.max(0.2, ((seg.endTime - seg.startTime) / span) * 100).toFixed(3) + '%';
      box.style.background = SLEEP_COLORS[status];
      box.title = SLEEP_NAMES[status] + ' ' + hhmmss(seg.startTime) + ' → ' + hhmmss(seg.endTime) +
        '（' + fmtDur(seg.endTime - seg.startTime) + '）';
      band.appendChild(box);

      var acc = stats.get(status) || { status: status, ms: 0, count: 0 };
      acc.ms += seg.endTime - seg.startTime;
      acc.count += 1;
      stats.set(status, acc);
    }
    host.appendChild(band);

    var axis = document.createElement('div');
    axis.className = 'sleep-axis';
    var left = document.createElement('span');
    left.textContent = hhmmss(t0);
    var right = document.createElement('span');
    right.textContent = hhmmss(t1);
    axis.appendChild(left);
    axis.appendChild(right);
    host.appendChild(axis);

    return {
      stats: Array.from(stats.values()).sort(function (a, b) { return a.status - b.status; }),
      segments: segs.length,
      t0: t0,
      t1: t1
    };
  }

  return {
    SeriesChart: SeriesChart,
    renderSleepBand: renderSleepBand,
    SLEEP_COLORS: SLEEP_COLORS,
    SLEEP_NAMES: SLEEP_NAMES,
    PALETTE: PALETTE,
    hhmmss: hhmmss,
    shortId: shortId,
    fmtNum: fmtNum,
    fmtDur: fmtDur
  };
})();
