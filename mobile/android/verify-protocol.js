/**
 * 验证 Android 客户端（ProtocolClient 的行为）与现有电脑端 hub.js 是否逐字段兼容。
 *
 * 做法：把电脑端服务**在同一个进程内**起来（避免子进程 stdio 沙箱限制），
 * 然后用项目自带的 WebSocket 实现复现 Android 客户端会发的每一条消息，
 * 断言电脑端的响应——这正是我无法在本机跑 Kotlin 时能做的最强验证。
 */
const path = require('path');
const PC = path.join(__dirname, '..', '..', 'pc', 'src');

const { HealthLinkServer } = require(path.join(PC, 'server.js'));
// Node 18/20 没有全局 WebSocket（21+ 才有），用垫片保证各版本都能跑
const { getWebSocketCtor } = require(path.join(__dirname, '..', '..', 'tools', 'mini-ws.js'));
const WS = getWebSocketCtor();

let pass = 0, fail = 0;
const results = [];
function check(label, ok, extra = '') {
  ok ? pass++ : fail++;
  results.push(`  [${ok ? 'PASS' : 'FAIL'}] ${label}${extra ? '  ' + extra : ''}`);
}

const TOKEN = 'testtoken-android-verify';
const DEVICE_ID = '0123456789abcdef0123456789abcdef'; // 32 个小写 hex，Android DeviceIdentity 的形态

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

(async () => {
  const server = new HealthLinkServer({
    config: {
      port: 0,
      host: '127.0.0.1',
      authToken: TOKEN,
      logLevel: 'error',
      defaultCollectIntervalMs: 60000,
      dataDir: path.join(process.env.TEMP || '.', 'hl-android-verify'),
      offlineAfterMs: 60000,
      maxFrameBytes: 4 * 1024 * 1024,
    },
    logger: { info() {}, warn() {}, error() {}, debug() {} },
  });
  await server.listen();
  const port = server.server.address().port;
  const url = `ws://127.0.0.1:${port}/ingest?token=${TOKEN}`;
  console.log(`电脑端已启动: ${url}\n`);

  // ---------------- 1) 鉴权 ----------------
  const badUrl = `ws://127.0.0.1:${port}/ingest?token=wrong`;
  const badResult = await new Promise((resolve) => {
    const ws = new WS(badUrl);
    let closedCode = null, gotNack = false;
    ws.onmessage = (e) => { try { if (JSON.parse(e.data).type === 'nack') gotNack = true; } catch {} };
    ws.onclose = (e) => { closedCode = e.code; resolve({ closedCode, gotNack }); };
    ws.onerror = () => {};
    setTimeout(() => resolve({ closedCode, gotNack }), 4000);
  });
  check('错误 token 被拒绝（回 nack 并关闭）', badResult.gotNack && badResult.closedCode === 4401,
    `code=${badResult.closedCode} nack=${badResult.gotNack}`);

  // ---------------- 建立合法连接 ----------------
  const ws = new WS(url);
  const inbox = [];
  ws.onmessage = (e) => {
    try { inbox.push(JSON.parse(e.data)); } catch {}
  };
  const waitType = async (type, timeoutMs = 5000) => {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const hit = inbox.find((m) => m.type === type);
      if (hit) return hit;
      await sleep(30);
    }
    return null;
  };
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = (e) => j(new Error('connect failed')); timeout = setTimeout(r, 5000); });

  // ---------------- 2) 首条必须是 hello ----------------
  ws.send(JSON.stringify({ v: 1, type: 'sample', seq: 1, ts: Date.now(), deviceId: DEVICE_ID, payload: {} }));
  const rejectMsg = await waitType('nack');
  check('非 hello 首条被拒（handshake_required）',
    !!rejectMsg && rejectMsg.payload.reason === 'handshake_required',
    rejectMsg ? `reason=${rejectMsg.payload.reason}` : '无响应');

  // ---------------- 3) hello 握手 ----------------
  const HELLO_SEQ = 1;
  ws.send(JSON.stringify({
    v: 1, type: 'hello', seq: HELLO_SEQ, ts: Date.now(), deviceId: DEVICE_ID,
    payload: {
      protocol: 1,
      model: 'Xiaomi 14',
      osVersion: 'Android 14 (API 34)',
      appVersion: '1.0.0',
      collectIntervalMs: 5000,
      lastSeq: 0,
      backgroundMode: ['bluetoothInteraction', 'dataTransfer'],
      healthStoreReady: true,
      permissions: { source: 'sensorpro' },
    },
  }));
  const ack = await waitType('hello_ack');
  check('hello 被接受，收到 hello_ack', !!ack && ack.payload.accepted === true,
    ack ? `accepted=${ack.payload.accepted} needBackfillFrom=${ack.payload.needBackfillFrom} interval=${ack.payload.collectIntervalMs}` : '无 hello_ack');
  check('hello_ack 带 needBackfillFrom 字段（首次应为 -1）',
    !!ack && ack.payload.needBackfillFrom === -1, ack ? `needBackfillFrom=${ack.payload.needBackfillFrom}` : '');
  check('hello_ack 回显 collectIntervalMs 且带 metrics 列表',
    !!ack && ack.payload.collectIntervalMs === 5000 && Array.isArray(ack.payload.metrics),
    ack ? `interval=${ack.payload.collectIntervalMs} metrics=${(ack.payload.metrics || []).length}项` : '');

  // ---------------- 4) sample：9 个合法 metric 全部应被接受 ----------------
  const METRICS = ['heart_rate', 'resting_heart_rate', 'hrv', 'spo2', 'stress', 'body_temperature', 'heart_rate_series'];
  const COMPOSITE = ['sleep', 'sleep_nap'];
  let seq = 2;
  inbox.length = 0;
  for (const m of METRICS) {
    ws.send(JSON.stringify({
      v: 1, type: 'sample', seq: seq++, ts: Date.now(), deviceId: DEVICE_ID,
      payload: { metric: m, value: 70, unit: null, startTime: Date.now() - 1000, endTime: Date.now(), source: 'sensorpro', sleep: null, extra: {} },
    }));
  }
  for (const m of COMPOSITE) {
    ws.send(JSON.stringify({
      v: 1, type: 'sample', seq: seq++, ts: Date.now(), deviceId: DEVICE_ID,
      payload: {
        metric: m, value: null, unit: null, startTime: Date.now() - 3600000, endTime: Date.now(), source: 'sensorpro',
        sleep: { fallAsleepTime: Date.now() - 28800000, wakeupTime: Date.now(), duration: 28800, sleepScore: 86, sleepSegment: [{ startTime: Date.now() - 28800000, endTime: Date.now(), sleepStatus: 2 }] },
        extra: {},
      },
    }));
  }
  await sleep(900);
  const acks = inbox.filter((m) => m.type === 'ack');
  const sampleNacks = inbox.filter((m) => m.type === 'nack');
  check(`9 个 KNOWN_METRICS 全部被接受（收到 ${acks.length}/9 个 ack）`, acks.length === 9, `nack=${sampleNacks.length}`);
  if (sampleNacks.length) results.push('        nack 详情: ' + JSON.stringify(sampleNacks.map((n) => n.payload)));

  // 非法 metric 必须被拒
  inbox.length = 0;
  ws.send(JSON.stringify({
    v: 1, type: 'sample', seq: seq++, ts: Date.now(), deviceId: DEVICE_ID,
    payload: { metric: 'emotion', value: 1, unit: null, startTime: Date.now() - 1000, endTime: Date.now(), source: 'sensorpro' },
  }));
  const badMetric = await waitType('nack');
  check('未知 metric 被拒（unknown_metric）', !!badMetric && badMetric.payload.reason === 'unknown_metric',
    badMetric ? `reason=${badMetric.payload.reason}` : '无 nack');

  // 复合指标缺 sleep 对象必须被拒
  inbox.length = 0;
  ws.send(JSON.stringify({
    v: 1, type: 'sample', seq: seq++, ts: Date.now(), deviceId: DEVICE_ID,
    payload: { metric: 'sleep', value: null, unit: null, startTime: Date.now() - 1000, endTime: Date.now(), source: 'sensorpro' },
  }));
  const badSleep = await waitType('nack');
  check('sleep 缺 sleep 对象被拒（malformed）', !!badSleep && badSleep.payload.reason === 'malformed',
    badSleep ? `reason=${badSleep.payload.reason}` : '无 nack');

  // ---------------- 5) ping / pong ----------------
  inbox.length = 0;
  ws.send(JSON.stringify({ v: 1, type: 'ping', seq: 0, ts: 12345, deviceId: DEVICE_ID, payload: { rtt: null } }));
  const pong = await waitType('pong');
  check('ping 得到 pong（echo 回显 ts）', !!pong && pong.payload.echo === 12345,
    pong ? `echo=${pong.payload.echo}` : '无 pong');

  // ---------------- 6) batch 补传 ----------------
  inbox.length = 0;
  const batchItems = [];
  for (let i = 0; i < 12; i++) {
    batchItems.push({ metric: 'heart_rate', value: 60 + i, unit: 'bpm', startTime: Date.now() - (12 - i) * 1000, endTime: Date.now() - (11 - i) * 1000, source: 'sensorpro' });
  }
  const BATCH_SEQ = seq++;
  ws.send(JSON.stringify({
    v: 1, type: 'batch', seq: BATCH_SEQ, ts: Date.now(), deviceId: DEVICE_ID,
    payload: { samples: batchItems, count: batchItems.length, reason: 'reconnect_backfill' },
  }));
  const batchAck = await waitType('ack');
  check('batch 被接受并回带 accepted/rejected 的 ack',
    !!batchAck && batchAck.payload.ackSeq === BATCH_SEQ && batchAck.payload.accepted === 12,
    batchAck ? `ackSeq=${batchAck.payload.ackSeq} accepted=${batchAck.payload.accepted} rejected=${batchAck.payload.rejected}` : `无 ack`);

  // batch 非法载荷
  inbox.length = 0;
  ws.send(JSON.stringify({ v: 1, type: 'batch', seq: seq++, ts: Date.now(), deviceId: DEVICE_ID, payload: { samples: 'not-array' } }));
  const badBatch = await waitType('nack');
  check('batch.samples 非数组被拒（bad_batch）', !!badBatch && badBatch.payload.reason === 'bad_batch',
    badBatch ? `reason=${badBatch.payload.reason}` : '无 nack');

  // ---------------- 7) 版本协商与未知类型 ----------------
  inbox.length = 0;
  ws.send(JSON.stringify({ v: 99, type: 'sample', seq: seq++, ts: Date.now(), deviceId: DEVICE_ID, payload: { metric: 'heart_rate', value: 1 } }));
  const badVer = await waitType('nack');
  check('v=99 被拒（unsupported_version）', !!badVer && badVer.payload.reason === 'unsupported_version',
    badVer ? `reason=${badVer.payload.reason}` : '无 nack');

  inbox.length = 0;
  ws.send(JSON.stringify({ v: 1, type: 'future_type_xyz', seq: 0, ts: Date.now(), deviceId: DEVICE_ID, payload: {} }));
  const unknown = await waitType('nack');
  check('未知 type 被拒（unknown_type）', !!unknown && unknown.payload.reason === 'unknown_type',
    unknown ? `reason=${unknown.payload.reason}` : '无 nack');

  // ---------------- 8) 补传区间计算（needBackfillFrom） ----------------
  // 模拟：已发到 seq 100，然后断线，重连时 lastSeq=100 而上报 lastSeq=150
  ws.close();
  await sleep(300);
  const ws2 = new WS(url);
  const inbox2 = [];
  ws2.onmessage = (e) => { try { inbox2.push(JSON.parse(e.data)); } catch {} };
  await new Promise((r) => { ws2.onopen = r; setTimeout(r, 4000); });
  ws2.send(JSON.stringify({
    v: 1, type: 'hello', seq: 151, ts: Date.now(), deviceId: DEVICE_ID,
    payload: { protocol: 1, model: 'X', osVersion: 'Android 14', appVersion: '1.0.0', collectIntervalMs: 5000, lastSeq: 150, backgroundMode: [], healthStoreReady: true, permissions: {} },
  }));
  await sleep(600);
  const ack2 = inbox2.find((m) => m.type === 'hello_ack');
  check('上报更大 lastSeq 时电脑端给出补传起点（needBackfillFrom > 0）',
    !!ack2 && ack2.payload.needBackfillFrom > 0,
    ack2 ? `上轮已收 seq=${BATCH_SEQ}，needBackfillFrom=${ack2.payload.needBackfillFrom}` : '无 hello_ack');
  ws2.close();

  // ---------------- 结果 ----------------
  console.log(results.join('\n'));
  console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
  server.close && server.close();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error('测试异常:', e);
  process.exit(2);
});
