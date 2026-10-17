'use strict';
/*!
 * HealthLink 电脑端可视化面板 —— 主逻辑（零依赖 / ES2020 / 可离线运行）。
 * 接口来源：docs/HTTP接口契约.md（协议 v1 冻结）+ docs/protocol/README.md。
 * 鉴权：REST 用请求头 X-Auth-Token；WebSocket 与导出用 ?token=。
 */
(() => {
  if (window.__HL_BOOT__) return;                    // 同一脚本被重复引入时只启动一次
  window.__HL_BOOT__ = true;
  const HC = window.HealthChart, $ = (id) => document.getElementById(id);
  const el = (tag, name, text) => { const n = document.createElement(tag); if (name) n.className = name; if (text !== undefined) n.textContent = text; return n; };
  const txt = (node, text) => { if (node && node.textContent !== text) node.textContent = text; };
  const cls = (node, name) => { if (node && node.className !== name) node.className = name; };

  /* ===== 常量（全部对齐契约） ===== */
  const METRICS = [
    { key: 'heart_rate', name: '动态心率', unit: 'bpm' }, { key: 'resting_heart_rate', name: '静息心率', unit: 'bpm' }, { key: 'hrv', name: '心率变异性', unit: 'ms' },
    { key: 'spo2', name: '血氧饱和度', unit: '%' }, { key: 'stress', name: '压力得分', unit: 'score' }];
  const CARD_METRICS = METRICS.concat([{ key: 'body_temperature', name: '体温', unit: '°C' }, { key: 'sleep', name: '睡眠', unit: '' }]);
  const METRIC_NAMES = { heart_rate: '心率', resting_heart_rate: '静息心率', hrv: 'HRV', spo2: '血氧', stress: '压力', sleep: '睡眠', body_temperature: '体温', heart_rate_series: '心率序列' };
  const BG_LABELS = { bluetoothInteraction: '蓝牙交互', dataTransfer: '数据传输', location: '定位', audioPlayback: '音频播放', taskKeeping: '任务保活', wifiInteraction: 'WLAN 交互' };
  const SLEEP_TYPES = { 1: 'TruSleep 科学睡眠', 2: '普通睡眠', 3: '手动记录', 4: '手机记录' };
  const FWD_STATES = { disabled: '已停用', connecting: '连接中', connected: '已连接', backoff: '退避重试', error: '错误' };
  const LEGACY = [['snoreFreq', '鼾声频率', '次/时'], ['avgHeartRate', '平均心率', 'bpm'], ['avgOxygenSaturation', '平均血氧', '%'], ['avgBreathRate', '平均呼吸率', '次/分'], ['avgHrv', '平均 HRV', 'ms']];
  const WINDOW_LABELS = { 60000: '1 分钟', 600000: '10 分钟', 3600000: '60 分钟' };
  const MAX_EVENTS = 50;                                            // 验收点 5：事件流上限 50 条
  const RECONNECT_DELAYS = [1000, 2000, 4000, 8000, 16000, 30000];  // 验收点 8：指数退避序列
  const state = { token: '', ws: null, lastSeq: 0, attempts: 0, reconnectTimer: null, stopped: false, devicesSoon: null,
    windowMs: 600000, charts: new Map(), devices: new Map(), forwards: new Map(), events: [], eventFlush: false, unauthorized: false };

  /* ===== 小工具 ===== */
  const clock = (ts) => HC.hhmmss(ts), shortId = (id) => HC.shortId(id), pad2 = (n) => (n < 10 ? '0' + n : String(n));
  const fmtNum = (n) => (isFinite(n) ? Number(n).toLocaleString('zh-CN') : '—');
  const notice = (text) => { const n = $('notice'); if (n) { txt(n, text || ''); n.hidden = !text; } };
  const numOr = (...vals) => { for (const v of vals) { if (v === null || v === undefined || v === '') continue; const n = Number(v); if (isFinite(n)) return n; } return null; };
  const fmtUptime = (ms) => { if (!isFinite(ms) || ms < 0) return '—'; const s = Math.floor(ms / 1000), d = Math.floor(s / 86400); return (d ? d + ' 天 ' : '') + pad2(Math.floor((s % 86400) / 3600)) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60); };
  const fmtSeconds = (sec) => { if (!isFinite(sec)) return '—'; const s = Math.max(0, Math.round(sec)), h = Math.floor(s / 3600); return h ? `${h} 小时 ${Math.round((s % 3600) / 60)} 分` : `${Math.round(s / 60)} 分`; };
  const fmtInterval = (ms) => (!isFinite(ms) || ms <= 0 ? '未上报' : (ms % 1000 === 0 ? `${ms / 1000} 秒` : `${(ms / 1000).toFixed(1)} 秒`));

  /* ===== REST：统一响应信封 + 401 处理（契约 1、2 节） ===== */
  async function rest(path, options = {}) {
    const headers = Object.assign({}, options.headers || {});
    if (state.token) headers['X-Auth-Token'] = state.token;
    if (options.body !== undefined) headers['Content-Type'] = 'application/json';
    const res = await fetch(path, { method: options.method || 'GET', headers, cache: 'no-store', body: options.body === undefined ? undefined : JSON.stringify(options.body) });
    const body = await res.json().catch(() => null);
    if (res.ok && body && body.ok === true) return body.data;
    const code = (body && body.error && body.error.code) || '';
    if (res.status === 401 || code === 'unauthorized') onUnauthorized();
    const err = new Error((body && body.error && body.error.message) || `HTTP ${res.status}`);
    err.status = res.status; err.code = code; throw err;
  }

  /* ===== 验收点 1：状态条（服务在线 / 协议版本 / 运行时长 / 设备在线数 / 订阅者数 / 入站样本总数） ===== */
  async function refreshStatus() {
    try {
      const h = await rest('/api/health');
      txt($('st-svc'), '在线'); cls($('st-svc'), 'ok');
      txt($('st-version'), `v${h && h.protocol != null ? h.protocol : '?'} · ${(h && h.version) || 'healthlink-hub'}`);
      if (state.unauthorized) { state.unauthorized = false; notice(''); }
    } catch { txt($('st-svc'), '离线'); cls($('st-svc'), 'bad'); txt($('st-version'), '—'); }
    try {
      const s = await rest('/api/stats'), dv = s.devices || {}, sb = s.subscribers || {}, ig = s.ingest || {};
      txt($('st-uptime'), fmtUptime(s.uptimeMs));                                    // 运行时长
      txt($('st-devices'), s.devices ? `${dv.online} / ${dv.total}` : '—');          // 设备在线数
      txt($('st-subs'), s.subscribers ? String(sb.total) : '—');                      // 订阅者数
      txt($('st-samples'), s.ingest ? fmtNum(ig.samples) + (s.buffer ? `（缓冲 ${fmtNum(s.buffer.size)}/${fmtNum(s.buffer.capacity)}）` : '') : '—');
    } catch { for (const id of ['st-uptime', 'st-devices', 'st-subs', 'st-samples']) txt($(id), '—'); }
  }

  /* ===== 验收点 2：设备卡片（按 deviceId 增量更新，不整块重建 DOM） ===== */
  const tag = (text, extra) => el('span', `tag${extra ? ' ' + extra : ''}`, text);

  function createDeviceCard(deviceId) {
    const idEl = el('b', 'device-id', shortId(deviceId));               // deviceId 截断显示
    idEl.title = `完整 deviceId：${deviceId}`;
    const badge = el('span', 'badge', '—'), head = el('div', 'device-head'); head.append(idEl, badge);
    const lastSeen = el('span', '', '—'), interval = el('span', '', '—'), seqInfo = el('span', '', '—');
    const meta = el('div', 'device-meta'); meta.append(lastSeen, interval, seqInfo);
    const bg = el('div', 'tags'), grid = el('div', 'metric-grid'), cells = {};
    for (const m of CARD_METRICS) {                                     // 指标单元格只创建一次
      const val = el('span', '', '—'), box = el('div', 'metric');
      box.append(el('i', '', m.name), val); grid.appendChild(box); cells[m.key] = val;
    }
    const model = el('div', 'device-model', '—'), card = el('article', 'device-card');
    card.append(head, model, meta, bg, grid); $('device-list').appendChild(card);
    return { el: card, badge, model, lastSeen, interval, seqInfo, bg, bgKey: null, cells };
  }

  function upsertDevice(d) {
    let rec = state.devices.get(d.deviceId);
    if (!rec) { rec = createDeviceCard(d.deviceId); state.devices.set(d.deviceId, rec); }
    const hello = d.hello || {}, modes = Array.isArray(hello.backgroundMode) ? hello.backgroundMode.filter(Boolean) : [];
    txt(rec.badge, d.online ? '在线' : '离线'); cls(rec.badge, `badge ${d.online ? 'badge-on' : 'badge-off'}`); // 在线徽标
    txt(rec.model, hello.model || '机型未上报'); txt(rec.lastSeen, `最后活跃 ${clock(d.lastSeen || d.connectedAt)}`); // 机型 / 最后活跃
    txt(rec.interval, `采集周期 ${fmtInterval(hello.collectIntervalMs)}`);           // 采集周期
    txt(rec.seqInfo, `lastSeq ${d.lastSeq == null ? '—' : d.lastSeq} · 样本 ${fmtNum(d.samplesReceived)}`);
    if (rec.bgKey !== modes.join('|')) {                                // 长时任务模式标签：仅变化时重建
      rec.bgKey = modes.join('|'); rec.bg.textContent = '';
      if (modes.length) modes.forEach((m) => rec.bg.appendChild(tag(`长时任务·${BG_LABELS[m] || m}`)));
      else rec.bg.appendChild(tag('长时任务模式未上报', 'tag-plain')); }
    for (const m of CARD_METRICS) {                                     // 各指标最新值
      const cell = rec.cells[m.key], s = (d.latest || {})[m.key];
      if (cell) txt(cell, !s ? '—' : (m.key === 'sleep' ? '有记录' : (s.value == null ? '—' : `${s.value}${s.unit ? ' ' + s.unit : ''}`)));
    }
  }

  async function refreshDevices() {
    let list; try { list = await rest('/api/devices'); } catch { return; } // 服务未就绪：静默（状态条显示离线）
    if (!Array.isArray(list)) return;
    const seen = new Set();
    for (const d of list) if (d && d.deviceId) { seen.add(d.deviceId); upsertDevice(d); }
    for (const [id, rec] of Array.from(state.devices)) if (!seen.has(id)) { rec.el.remove(); state.devices.delete(id); }
    txt($('device-count'), `${list.length} 台`); const empty = $('device-empty'); if (empty) empty.hidden = list.length > 0;
  }
  // WS 先到、卡片尚未建立时去抖补齐一次 GET /api/devices
  const refreshDevicesSoon = () => { if (!state.devicesSoon) state.devicesSoon = setTimeout(() => { state.devicesSoon = null; refreshDevices(); }, 500); };

  /* ===== 验收点 3：曲线数据投喂（Canvas 绘制在 chart.js） ===== */
  function feedSample(payload, deviceId) {
    const metric = payload.metric;
    let ts = numOr(payload.endTime, payload.startTime); if (ts === null || ts <= 0) ts = Date.now(); // 数据点时间，兜底本地时间
    const value = (payload.value === null || payload.value === undefined || payload.value === '') ? NaN : Number(payload.value);
    const chart = state.charts.get(metric);
    if (chart && isFinite(value)) chart.addPoint(deviceId, ts, value);
    const rec = state.devices.get(deviceId);
    if (!rec) refreshDevicesSoon();
    else if (rec.cells[metric]) txt(rec.cells[metric], metric === 'sleep' ? '有记录' : (isFinite(value) ? `${value}${payload.unit ? ' ' + payload.unit : ''}` : '—'));
    if (metric === 'sleep') renderSleep(payload);
  }
  function setWindow(ms) {                                              // 窗口切换：1 / 10 / 60 分钟
    state.windowMs = ms; txt($('window-label'), WINDOW_LABELS[ms] || `${ms / 60000} 分钟`);
    state.charts.forEach((c) => c.setWindow(ms));
    document.querySelectorAll('#window-switch [data-window]').forEach((b) => b.classList.toggle('active', Number(b.dataset.window) === ms));
  }
  function initCharts() {
    for (const m of METRICS) {
      const canvas = $(`chart-${m.key}`);
      if (canvas) state.charts.set(m.key, new HC.SeriesChart(canvas, { unit: m.unit, windowMs: state.windowMs, legendEl: $(`legend-${m.key}`), latestEl: $(`latest-${m.key}`) }));
    }
    setInterval(() => state.charts.forEach((c) => c.invalidate()), 1000); // 每秒推动时间轴（rAF 节流，最多 1fps/图）
  }

  /* ===== 验收点 5：实时事件流（增量 DOM，最多 50 条） ===== */
  function eventRow(item) {
    const time = el('span', 'ev-time', clock(item.ts || Date.now()));
    const kind = el('span', 'ev-kind'), body = el('span', 'ev-body'), row = el('li', `event-row ev-${item.kind || 'system'}`);
    if (item.kind === 'sample') {
      const p = item.payload || {}, v = p.metric === 'sleep' ? '睡眠记录' : (p.value == null ? '无值' : `${p.value}${p.unit ? ' ' + p.unit : ''}`);
      kind.textContent = '样本'; body.textContent = `${shortId(item.deviceId)} · ${METRIC_NAMES[p.metric] || p.metric || '未知指标'} = ${v}${p.source ? `（${p.source}）` : ''}`;
      if (item.seq) row.title = `seq=${item.seq}`;
    } else if (item.kind === 'device') {
      kind.textContent = '设备'; body.textContent = `${shortId(item.deviceId)} ${item.text || ''}`;
    } else {
      kind.textContent = item.kind === 'bad' ? '错误' : (item.kind === 'warn' ? '警告' : '系统'); body.textContent = item.text || '';
    }
    row.append(time, kind, body); return row;
  }
  function pushEvent(item) {                                            // 同一帧内多条事件合并成一次 DOM 插入
    state.events.push(item);
    if (state.eventFlush) return;
    state.eventFlush = true;
    requestAnimationFrame(() => {
      state.eventFlush = false;
      const queue = state.events, list = $('event-list'); state.events = [];
      if (!list || !queue.length) return;
      const frag = document.createDocumentFragment();
      for (let i = queue.length - 1; i >= 0; i--) frag.appendChild(eventRow(queue[i]));   // 最新在最上
      list.insertBefore(frag, list.firstChild);
      while (list.children.length > MAX_EVENTS) list.removeChild(list.lastChild);         // 只保留最新 50 条
      txt($('event-count'), String(list.children.length)); const empty = $('event-empty'); if (empty) empty.hidden = true;
    });
  }

  /* ===== 验收点 4：睡眠卡片（分期色带 + 得分/时长/效率 + legacy 降级） ===== */
  function renderSleepStages(res) {
    const host = $('sleep-stages'); if (!host) return; host.textContent = '';
    if (!res.stats.length) { host.appendChild(el('p', 'muted', '该记录没有可用的 sleepSegment 分期数据（色带与统计已优雅降级）。')); return; }
    for (const st of res.stats) {
      const chip = el('span', 'chip'), dot = el('i');
      dot.style.background = HC.SLEEP_COLORS[st.status] || HC.SLEEP_COLORS[0];
      chip.append(dot, document.createTextNode(`${HC.SLEEP_NAMES[st.status] || '未知'} ${HC.fmtDur(st.ms)} · ${st.count} 段`));
      host.appendChild(chip);
    }
    host.appendChild(el('p', 'muted', `共 ${res.segments} 段分期，覆盖 ${clock(res.t0)} → ${clock(res.t1)}。`));
  }
  function renderSleepLegacy(legacy) {                                  // legacy 缺失时优雅降级，不报错
    const host = $('sleep-legacy'); if (!host) return; host.textContent = '';
    const has = legacy && typeof legacy === 'object';
    for (const [key, name, unit] of LEGACY) {
      const v = has ? numOr(legacy[key]) : null, box = el('div', 'kv');
      box.append(el('i', '', name), el('b', v === null ? 'muted' : '', v === null ? '—' : `${v}${unit ? ' ' + unit : ''}`));
      host.appendChild(box);
    }
    txt($('sleep-legacy-note'), has
      ? 'legacy 是可选扩展字段（新版 healthFields.Sleep 不提供 snoreFreq/avgHeartRate 等），缺失项显示为 —，属正常降级。'
      : 'legacy 字段整体缺失：新版 SDK 的正常情况，面板已优雅降级，不视为错误。');
  }
  function renderSleep(payload) {
    const s = payload && payload.sleep;
    if (!s || typeof s !== 'object') { txt($('sleep-legacy-note'), '该 metric=sleep 样本未包含 sleep 明细（payload.sleep 为空），已忽略。'); return; }
    const emptyEl = $('sleep-empty'), bodyEl = $('sleep-body'); if (emptyEl) emptyEl.hidden = true; if (bodyEl) bodyEl.hidden = false;
    txt($('sleep-score'), s.sleepScore == null ? '—' : `${s.sleepScore} 分`);              // sleepScore
    txt($('sleep-efficiency'), s.sleepEfficiency == null ? '—' : `${s.sleepEfficiency}%`); // sleepEfficiency
    txt($('sleep-wakecount'), s.wakeCount == null ? '—' : `${s.wakeCount} 次`);
    const dur = numOr(s.duration, s.sleepDuration);                                        // sleepDuration（秒）
    txt($('sleep-duration'), dur === null ? '—' : fmtSeconds(dur));
    txt($('sleep-range'), `${clock(s.fallAsleepTime)} → ${clock(s.wakeupTime)}`);
    txt($('sleep-type'), SLEEP_TYPES[s.sleepType] || (s.sleepType == null ? '未上报' : `类型 ${s.sleepType}`));
    renderSleepStages(HC.renderSleepBand($('sleep-band'), s));          // 色带：绝对定位 div，按时间比例
    renderSleepLegacy(s.legacy);
  }

  /* ===== 验收点 8：WebSocket + 指数退避重连（重连带 since=最后收到的 seq） ===== */
  function wsUrl() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';      // 不写死 localhost
    return `${proto}//${location.host}/subscribe?token=${encodeURIComponent(state.token)}&topic=health` +
      (state.lastSeq > 0 ? `&since=${encodeURIComponent(String(state.lastSeq))}` : '');   // 断线续传
  }
  const setWsBadge = (text, name) => { txt($('st-ws'), text); cls($('st-ws'), name || ''); };

  function connect() {
    if (state.stopped) return;
    setWsBadge('连接中…', 'warn'); let ws;
    try { ws = new WebSocket(wsUrl()); state.ws = ws; } catch (e) { notice(`WebSocket 地址无效：${e.message}`); scheduleReconnect(); return; }
    ws.onopen = () => { state.attempts = 0; setWsBadge('已连接', 'ok');
      pushEvent({ kind: 'system', text: `实时连接已建立${state.lastSeq > 0 ? `（since=${state.lastSeq}，等待重放）` : ''}` }); };
    ws.onmessage = (ev) => { let msg = null; try { msg = JSON.parse(ev.data); } catch { return; } if (msg && typeof msg === 'object') handleMessage(msg); };
    ws.onclose = (ev) => {
      state.ws = null; const code = (ev && ev.code) || 0;
      if (code === 4401) {                                              // 契约 4 节：鉴权失败 nack + 关闭码 4401
        state.stopped = true; setWsBadge('鉴权失败 4401', 'bad');
        pushEvent({ kind: 'bad', text: 'WebSocket 鉴权失败（关闭码 4401）' }); onUnauthorized(); return;
      }
      setWsBadge('已断开', 'bad'); pushEvent({ kind: 'system', text: `实时连接断开（关闭码 ${code}），将指数退避重连` });
      scheduleReconnect();
    };
    ws.onerror = () => { /* onerror 后必然触发 onclose，统一在 onclose 里重连 */ };
  }

  function scheduleReconnect() {                                        // 1s/2s/4s/8s/16s/30s，上限 30s
    if (state.stopped || state.reconnectTimer) return;
    const delay = RECONNECT_DELAYS[Math.min(state.attempts, RECONNECT_DELAYS.length - 1)]; state.attempts += 1;
    setWsBadge(`重连中 ${Math.round(delay / 1000)}s（第 ${state.attempts} 次）`, 'warn');
    state.reconnectTimer = setTimeout(() => { state.reconnectTimer = null; connect(); }, delay);
  }

  function handleMessage(msg) {                                         // 契约 4 节的全部消息类型
    if (isFinite(msg.seq) && msg.seq > 0 && msg.seq > state.lastSeq) state.lastSeq = msg.seq; // 重连游标
    const p = msg.payload || {};
    switch (msg.type) {
      case 'subscribed': pushEvent({ kind: 'system', ts: msg.ts, text: `订阅成功：topic=${p.topic || 'health'}，重放 ${p.replayed || 0} 条${p.live ? '，已转入实时' : ''}` }); break;
      case 'sample': feedSample(p, msg.deviceId); pushEvent({ kind: 'sample', payload: p, deviceId: msg.deviceId, seq: msg.seq, ts: msg.ts }); break;
      case 'device_event': pushEvent({ kind: 'device', deviceId: msg.deviceId, ts: msg.ts, text: `设备${p.event === 'online' ? '上线' : '下线'}${p.model ? '：' + p.model : ''}` }); refreshDevicesSoon(); break;
      case 'gap': pushEvent({ kind: 'warn', ts: msg.ts, text: `历史缺口：请求 since=${p.requestedSince}，缓冲最旧 ${p.oldestAvailable}，丢失 ${p.lost} 条` }); break;
      case 'nack': pushEvent({ kind: 'bad', ts: msg.ts, text: `服务端拒绝（nack）：${p.reason || '未知原因'}` }); if (p.reason === 'unauthorized') { state.stopped = true; onUnauthorized(); } break;
      case 'query_result': pushEvent({ kind: 'system', ts: msg.ts, text: `查询结果：${(p.samples || []).length} 条${p.truncated ? '（已截断）' : ''}` }); break;
      case 'pong': break;
      default: pushEvent({ kind: 'warn', ts: msg.ts, text: `未知消息类型：${msg.type}` });
    }
  }

  /* ===== 令牌门（契约 1、6 节） ===== */
  function onUnauthorized() {
    if (state.unauthorized) return; state.unauthorized = true; txt($('st-svc'), '令牌无效'); cls($('st-svc'), 'bad');
    notice('访问令牌缺失或无效（401 / 4401）：请重新输入令牌。'); showGate('令牌无效或缺失，请重新输入。');
  }
  function showGate(message) {
    const gate = $('gate'); if (!gate) return;
    gate.hidden = false;
    const err = $('gate-error'); if (err) { err.hidden = !message; txt(err, message || ''); }
    const input = $('gate-input'); if (input) { input.value = ''; input.focus(); }
  }

  /* ===== 验收点 7：导出 CSV / JSON（/api/export?format=…&token=…） ===== */
  function doExport(format) {
    const url = `/api/export?format=${encodeURIComponent(format)}&token=${encodeURIComponent(state.token)}`;
    const a = el('a'); a.href = url; a.download = `healthlink-export.${format}`; a.rel = 'noopener';
    document.body.appendChild(a); a.click(); a.remove();
    pushEvent({ kind: 'system', text: `已请求导出 ${format.toUpperCase()}（${url.replace(/token=[^&]*/, 'token=***')}）` });
  }

  /* ===== 验收点 6：转发目标面板（GET / POST / DELETE /api/forward） ===== */
  const fwdBody = (c, patch = {}) => ({
    id: c.id, enabled: patch.enabled === undefined ? c.enabled !== false : !!patch.enabled,
    kind: c.kind || 'websocket', url: c.url || '',
    deviceIds: Array.isArray(c.deviceIds) ? c.deviceIds : [], metrics: Array.isArray(c.metrics) ? c.metrics : [],
    batchMs: isFinite(Number(c.batchMs)) ? Number(c.batchMs) : 2000, retry: c.retry && typeof c.retry === 'object' ? c.retry : { maxAttempts: 5, backoffMs: 1000 }
  });
  function forwardError(msg) { const n = $('forward-error'); if (n) { n.hidden = !msg; txt(n, msg || ''); } }

  function createForwardRow(id) {
    const idEl = el('b', '', id), kind = el('span', 'tag', '—'), stateEl = el('span', 'badge', '—');
    const head = el('div', 'forward-head'); head.append(idEl, kind, stateEl);
    const url = el('div', 'forward-url', '—'), counters = el('div', 'forward-counters'), parts = {};
    for (const [key, label] of [['queued', '队列'], ['sent', '已发送'], ['failed', '失败'], ['dropped', '丢弃']]) {
      const b = el('b', '', '0'), span = el('span');
      span.append(document.createTextNode(`${label} `), b); counters.appendChild(span); parts[key] = b;
    }
    const toggle = el('button', 'btn small', '停用'), del = el('button', 'btn small danger', '删除');
    for (const b of [toggle, del]) b.type = 'button';
    const actions = el('div', 'forward-actions'); actions.append(toggle, del);
    const err = el('p', 'muted forward-err'); err.hidden = true;
    const row = el('article', 'forward-row'); row.append(head, url, counters, actions, err);
    toggle.addEventListener('click', () => toggleForward(id)); del.addEventListener('click', () => deleteForward(id));
    return { el: row, kind, state: stateEl, url, toggle, err, queued: parts.queued, sent: parts.sent, failed: parts.failed, dropped: parts.dropped, cfg: null };
  }

  function upsertForward(t) {                                           // 已存在则只改变化的文本节点
    let rec = state.forwards.get(t.id);
    if (!rec) { rec = createForwardRow(t.id); state.forwards.set(t.id, rec); $('forward-list').appendChild(rec.el); }
    rec.cfg = t; const on = t.enabled !== false, st = on ? (t.state || 'unknown') : 'disabled';
    txt(rec.kind, t.kind === 'http' ? 'HTTP' : 'WebSocket');
    txt(rec.url, t.url || '（未配置地址）'); rec.url.title = t.url || '';
    txt(rec.state, FWD_STATES[st] || st); cls(rec.state, `badge fw-${st}`);   // state: disabled/connecting/connected/backoff/error
    txt(rec.queued, String(t.queued == null ? 0 : t.queued));                 // 队列深度
    txt(rec.sent, fmtNum(t.sentTotal || 0)); txt(rec.failed, fmtNum(t.failedTotal || 0)); // 已发送 / 失败
    txt(rec.dropped, fmtNum(t.droppedTotal || 0));
    txt(rec.toggle, on ? '停用' : '启用');                                    // 启停按钮
    rec.err.hidden = !t.lastError; if (t.lastError) txt(rec.err, `最近错误：${t.lastError}`);
  }

  async function refreshForward() {
    let list;
    try { list = await rest('/api/forward'); } catch (e) { txt($('forward-note'), `读取转发目标失败：${e.message}`); return; }
    if (!Array.isArray(list)) return; const seen = new Set();
    for (const t of list) if (t && t.id) { seen.add(t.id); upsertForward(t); }
    for (const [id, rec] of Array.from(state.forwards)) if (!seen.has(id)) { rec.el.remove(); state.forwards.delete(id); }
    txt($('forward-note'), list.length ? '' : '尚未配置转发目标。');
  }
  function toggleForward(id) {                                          // 启停：POST 完整目标对象（id 必填）
    const rec = state.forwards.get(id);
    if (!rec || !rec.cfg) return;
    const next = rec.cfg.enabled === false;
    rest('/api/forward', { method: 'POST', body: fwdBody(rec.cfg, { enabled: next }) })
      .then(() => pushEvent({ kind: 'system', text: `转发目标 ${id} 已${next ? '启用' : '停用'}` }))
      .catch((e) => forwardError(`切换转发目标失败：${e.message}`)).then(refreshForward);
  }
  function deleteForward(id) {                                          // 删除：DELETE /api/forward?id=
    rest(`/api/forward?id=${encodeURIComponent(id)}`, { method: 'DELETE' })
      .then(() => pushEvent({ kind: 'system', text: `已删除转发目标 ${id}` }))
      .catch((e) => forwardError(`删除转发目标失败：${e.message}`)).then(refreshForward);
  }

  /* ===== 启动 ===== */
  async function loadHistory() {                                        // 打开面板即回填历史（倒序返回 → 反转成升序喂入）
    try {
      const data = await rest('/api/samples?limit=1000&order=desc'), samples = (data && data.samples) || [];
      for (let i = samples.length - 1; i >= 0; i--) if (samples[i] && samples[i].payload) feedSample(samples[i].payload, samples[i].deviceId);
      if (samples.length) pushEvent({ kind: 'system', text: `历史回填完成：${samples.length} 条` });
    } catch { /* 服务端未就绪：静默 */ }
    try {
      const data = await rest('/api/samples?metric=sleep&limit=1&order=desc');   // 最近一条 metric=sleep
      if (data && data.samples && data.samples[0] && data.samples[0].payload) renderSleep(data.samples[0].payload);
    } catch { /* 静默 */ }
  }

  function bindUi() {
    document.querySelectorAll('#window-switch [data-window]').forEach((b) => b.addEventListener('click', () => setWindow(Number(b.dataset.window))));
    $('export-csv')?.addEventListener('click', () => doExport('csv'));
    $('export-json')?.addEventListener('click', () => doExport('json'));
    $('forward-form')?.addEventListener('submit', (ev) => {              // 新增 / 更新转发目标
      ev.preventDefault();
      const id = $('f-id').value.trim(), url = $('f-url').value.trim();
      if (!id) return forwardError('请填写目标 id（必填）。');
      if (!url) return forwardError('请填写目标地址 url。');
      const batch = Number($('f-batch').value);
      rest('/api/forward', { method: 'POST', body: { id, enabled: true, kind: $('f-kind').value, url, deviceIds: [], metrics: [], batchMs: isFinite(batch) && batch >= 0 ? batch : 2000, retry: { maxAttempts: 5, backoffMs: 1000 } } })
        .then(() => { forwardError(''); $('f-id').value = ''; $('f-url').value = ''; return refreshForward(); })
        .catch((e) => forwardError(`保存转发目标失败：${e.message}`));
    });
    $('gate-form')?.addEventListener('submit', (ev) => {                 // 令牌输入：带 token 重新加载
      ev.preventDefault();
      const value = ($('gate-input').value || '').trim();
      if (!value) return showGate('令牌不能为空。');
      location.replace(`${location.pathname}?token=${encodeURIComponent(value)}`);
    });
  }

  function start() {
    initCharts(); setWindow(state.windowMs); connect();
    refreshStatus(); refreshDevices(); refreshForward(); loadHistory();
    setInterval(refreshStatus, 2000); setInterval(refreshDevices, 5000); setInterval(refreshForward, 5000);
    window.addEventListener('resize', () => state.charts.forEach((c) => c.resize()));
  }

  function init() {
    if (!HC) { notice('图表模块 chart.js 加载失败：请确认与 index.html 同目录（或 /assets/ 下）存在 chart.js。'); return; }
    state.token = new URLSearchParams(location.search).get('token') || '';  // 令牌来自 location.search
    bindUi();
    if (!state.token) { notice('URL 未携带 token 参数（契约第 6 节），请先输入访问令牌。'); showGate(''); return; }
    start();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
