/**
 * 验证只读分享页：
 *  1) 服务端能从 pc/web/ 正确提供 share.html（MIME、状态码）
 *  2) /subscribe 的真实消息序列（subscribed / sample / device_event）与分享页的解析逻辑一致
 *
 * 做法：进程内起电脑端服务 → 用 HTTP 取页面 → 用 WebSocket 模拟手机上行 + 订阅者，
 * 断言订阅者收到的消息类型与字段正是 share.html 里 switch 处理的那些。
 */
const path = require('path');
const http = require('http');
const PC = path.join(__dirname, '..', 'pc', 'src');
const { HealthLinkServer } = require(path.join(PC, 'server.js'));
// Node 18/20 没有全局 WebSocket（21+ 才有），用垫片保证各版本都能跑
const { getWebSocketCtor } = require('./mini-ws');
const WS = getWebSocketCtor();

let pass = 0, fail = 0;
const log = [];
function check(label, ok, extra = '') {
  ok ? pass++ : fail++;
  log.push(`  [${ok ? 'PASS' : 'FAIL'}] ${label}${extra ? '  → ' + extra : ''}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function httpGet(host, port, urlPath) {
  return new Promise((resolve) => {
    const req = http.get({ host, port, path: urlPath, timeout: 6000 }, (res) => {
      let b = '';
      res.setEncoding('utf8');
      res.on('data', (d) => (b += d));
      res.on('end', () => resolve({ status: res.statusCode, ctype: res.headers['content-type'], body: b }));
    });
    req.on('error', (e) => resolve({ status: 0, error: e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, error: 'timeout' }); });
  });
}

(async () => {
  const TOKEN = 'sharetoken-verify';
  const server = new HealthLinkServer({
    config: {
      port: 0, host: '127.0.0.1', authToken: TOKEN, logLevel: 'error',
      defaultCollectIntervalMs: 60000,
      dataDir: path.join(process.env.TEMP || '.', 'hl-share-verify'),
      offlineAfterMs: 60000, maxFrameBytes: 4 * 1024 * 1024,
    },
    logger: { info() {}, warn() {}, error() {}, debug() {} },
  });
  await server.listen();
  const port = server.server.address().port;

  // ---------- 1) 页面能否被服务端提供 ----------
  const page = await httpGet('127.0.0.1', port, '/share.html');
  check('GET /share.html 返回 200', page.status === 200, `status=${page.status} ${page.error || ''}`);
  check('Content-Type 是 text/html', /text\/html/i.test(page.ctype || ''), page.ctype || '(空)');
  check('页面内容包含 subscribe 连接逻辑', /\/subscribe\?token=/.test(page.body || ''));
  check('页面不写入令牌到外部（无 fetch 外发）',
    !/fetch\(|XMLHttpRequest/.test(page.body || ''));

  // 路径穿越拦截仍然有效（顺带回归）
  const evil = await httpGet('127.0.0.1', port, '/../server.js');
  check('路径穿越仍被拦截（非 200 或非源码）',
    evil.status !== 200 || !/HealthLinkServer/.test(evil.body || ''), `status=${evil.status}`);

  // ---------- 2) 订阅消息序列 ----------
  const url = `ws://127.0.0.1:${port}/subscribe?token=${TOKEN}&topic=health&since=0`;
  const sub = new WS(url);
  const got = [];
  sub.onmessage = (e) => { try { got.push(JSON.parse(e.data)); } catch {} };
  await new Promise((r) => { sub.onopen = r; sub.onerror = r; setTimeout(r, 4000); });

  // 手机端上行一批数据
  const DEV = 'sharetoken0000device0000000000000001'.slice(0, 32);
  const dev = new WS(`ws://127.0.0.1:${port}/ingest?token=${TOKEN}`);
  await new Promise((r) => { dev.onopen = r; setTimeout(r, 4000); });
  dev.send(JSON.stringify({
    v: 1, type: 'hello', seq: 1, ts: Date.now(), deviceId: DEV,
    payload: { protocol: 1, model: 'Test Phone', osVersion: 'HarmonyOS 4.3', appVersion: '1.0.0',
      collectIntervalMs: 5000, lastSeq: 0, backgroundMode: [], healthStoreReady: true, permissions: {} },
  }));
  await sleep(400);

  const now = Date.now();
  const samples = [
    { metric: 'heart_rate', value: 72, unit: 'bpm' },
    { metric: 'spo2', value: 97, unit: '%' },
    { metric: 'stress', value: 38, unit: 'score' },
    { metric: 'resting_heart_rate', value: 62, unit: 'bpm' },
  ];
  let seq = 2;
  for (const s of samples) {
    dev.send(JSON.stringify({
      v: 1, type: 'sample', seq: seq++, ts: now, deviceId: DEV,
      payload: { metric: s.metric, value: s.value, unit: s.unit, startTime: now - 1000, endTime: now,
        source: 'ble', sleep: null, extra: {} },
    }));
  }
  await sleep(1200);

  const types = got.map((m) => m.type);
  check('订阅者收到 subscribed', types.includes('subscribed'), types.join(','));
  check('订阅者收到 device_event（设备上线）', types.includes('device_event'));
  const sampleMsgs = got.filter((m) => m.type === 'sample');
  check(`订阅者收到 ${samples.length} 条 sample`, sampleMsgs.length === samples.length,
    `实际 ${sampleMsgs.length}`);

  // 分享页依赖的字段是否都在
  const hr = sampleMsgs.find((m) => m.payload && m.payload.metric === 'heart_rate');
  check('sample 带 metric/value/unit/endTime（分享页渲染所需）',
    !!hr && hr.payload.value === 72 && hr.payload.unit === 'bpm' && typeof hr.payload.endTime === 'number',
    hr ? JSON.stringify(hr.payload).slice(0, 90) : '无 heart_rate');
  check('sample 信封带 deviceId 与 ts（分享页信息区所需）',
    !!hr && typeof hr.deviceId === 'string' && typeof hr.ts === 'number');
  const ev = got.find((m) => m.type === 'device_event');
  check('device_event 带 event/model（分享页设备状态所需）',
    !!ev && typeof ev.payload.event === 'string', ev ? JSON.stringify(ev.payload) : '无');

  // 分享页用到的 metric 是否都被服务端透传（不能被过滤掉）
  const seen = new Set(sampleMsgs.map((m) => m.payload.metric));
  const missing = samples.map((s) => s.metric).filter((m) => !seen.has(m));
  check('全部 4 个指标都透传给订阅者', missing.length === 0, missing.length ? '缺: ' + missing.join(',') : '');

  dev.close(); sub.close();

  console.log(log.join('\n'));
  console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
  if (server.close) server.close();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error('测试异常:', e); process.exit(2); });
