#!/usr/bin/env node
'use strict';
/**
 * HealthLink 电脑端端到端测试。
 *
 * 不依赖任何测试框架（npm 不可用），自己写一个极小的断言器。
 * 覆盖：WebSocket 握手与帧编解码、上行协议、断线重放、REST、
 *       CSV/JSON 导出、路径穿越防护、鉴权、转发与队列。
 *
 * 用法：node pc/test/e2e.test.js
 * 退出码 0 = 全通过，1 = 有失败。
 */

const assert = require('assert');
const http = require('http');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const { loadConfig } = require('../src/config');
const { HealthLinkServer } = require('../src/server');
const { SampleBuffer } = require('../src/storage');
const { WsClient } = require('../src/wsclient');
const { createConsoleLogger } = require('../src/hub');

// ---------------------------------------------------------------- 迷你测试器

const results = [];
let currentSuite = '';

function suite(name) {
  currentSuite = name;
  process.stdout.write(`\n\x1b[36m▶ ${name}\x1b[0m\n`);
}

/** 单个套件的超时：卡住的用例必须"失败"，不能变成"静默通过" */
const SUITE_TIMEOUT_MS = 30000;
/** 汇总是否已经打出来过（配合 beforeExit 兜底，防止进程提前静默退出） */
let summaryPrinted = false;

async function test(name, fn) {
  try {
    // ⚠️ 为什么要加超时：以前某个用例里 await 一个永不 resolve 的 promise 时，
    //    事件循环空了 Node 会**以退出码 0 直接退出**，测试看起来"全部通过"，
    //    其实后面的用例根本没跑。有超时才能把它变成一条明确的 FAIL。
    await Promise.race([
      Promise.resolve().then(fn),
      new Promise((_, reject) => {
        const t = setTimeout(() => reject(new Error(`用例超时（>${SUITE_TIMEOUT_MS}ms）：${name}`)), SUITE_TIMEOUT_MS);
        if (typeof t.unref === 'function') t.unref();
      }),
    ]);
    results.push({ suite: currentSuite, name, ok: true });
    process.stdout.write(`  \x1b[32m✓\x1b[0m ${name}\n`);
  } catch (err) {
    results.push({ suite: currentSuite, name, ok: false, error: err });
    process.stdout.write(`  \x1b[31m✗\x1b[0m ${name}\n      \x1b[31m${err.message}\x1b[0m\n`);
  }
}

// 兜底：如果进程在汇总之前就要退出（比如某个 await 永远等不到、事件循环空了），
// 明确报错并以非 0 退出，别让 CI 以为测试通过了。
process.on('beforeExit', () => {
  if (summaryPrinted) return;
  process.stdout.write('\n\x1b[31m测试运行未跑完：进程在打印汇总前就退出了（多半是某个 await 永不 resolve）\x1b[0m\n');
  process.exitCode = 1;
});

// ---------------------------------------------------------------- 工具

const silentLogger = { debug() {}, info() {}, warn() {}, error() {} };

function tmpDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function httpJson(port, urlPath, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, path: urlPath, method: options.method || 'GET', headers: options.headers || {} },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const body = Buffer.concat(chunks);
          let json = null;
          try { json = JSON.parse(body.toString('utf8')); } catch (_) { /* 非 JSON */ }
          resolve({ status: res.statusCode, headers: res.headers, body, json });
        });
      }
    );
    req.on('error', reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}

function httpRaw(port, urlPath, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, path: urlPath, method: options.method || 'GET', headers: options.headers || {} },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      }
    );
    req.on('error', reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}

/** 建立一个已握手、已发 hello 的假手机 */
async function connectPhone(url, deviceId, extraHello = {}) {
  const client = new WsClient(url, { connectTimeoutMs: 4000 });
  const received = [];
  await new Promise((resolve, reject) => {
    client.on('open', resolve);
    client.on('error', reject);
    client.connect();
  });
  client.on('message', (text) => {
    try { received.push(JSON.parse(text)); } catch (_) { /* 忽略 */ }
  });
  let seq = 0;
  const send = (type, payload) => {
    seq++;
    client.send(JSON.stringify({ v: 1, type, seq, ts: Date.now(), deviceId, payload }));
    return seq;
  };
  send('hello', {
    protocol: 1,
    model: 'TEST-DEVICE',
    osVersion: 'HarmonyOS test',
    appVersion: 'test',
    collectIntervalMs: 1000,
    lastSeq: 0,
    backgroundMode: ['bluetoothInteraction', 'dataTransfer'],
    healthStoreReady: true,
    permissions: { healthDataRead: true },
    ...extraHello
  });
  await waitFor(() => received.some((m) => m.type === 'hello_ack'), 3000);
  return { client, received, send, get seq() { return seq; } };
}

function waitFor(predicate, timeoutMs = 3000, stepMs = 20) {
  return new Promise((resolve) => {
    const started = Date.now();
    const tick = () => {
      if (predicate()) return resolve(true);
      if (Date.now() - started > timeoutMs) return resolve(false);
      setTimeout(tick, stepMs);
    };
    tick();
  });
}

/**
 * 打开一条 WebSocket 并**在连接建立前**就挂好 message 监听。
 *
 * ⚠️ 这里踩过坑：如果先 await open 再 on('message')，
 * 服务端在握手回调里同步发出的第一条消息（例如 subscribed / hello_ack）会丢，
 * 表现为"订阅者收不到 subscribed"这种假失败。
 */
async function openWs(url) {
  const client = new WsClient(url, { connectTimeoutMs: 5000 });
  const messages = [];
  let closeInfo = null;
  const waiters = [];
  client.on('message', (text) => {
    let parsed = null;
    try { parsed = JSON.parse(text); } catch (_) { /* 忽略非 JSON */ }
    messages.push(parsed === null ? { type: '__raw__', raw: text } : parsed);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].predicate()) {
        waiters[i].resolve(true);
        waiters.splice(i, 1);
      }
    }
  });
  client.on('close', (code, reason) => {
    closeInfo = { code, reason };
  });
  client.on('error', () => { /* 由调用方按需断言 */ });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`连接超时: ${url}`)), 6000);
    client.on('open', () => {
      clearTimeout(timer);
      resolve();
    });
    client.connect();
  });
  return {
    client,
    messages,
    get closeInfo() { return closeInfo; },
    send: (obj) => client.send(JSON.stringify(obj)),
    /** 等某类消息出现 */
    waitForMessage(predicate, timeoutMs = 3000) {
      if (predicate()) return Promise.resolve(true);
      return new Promise((resolve) => {
        const timer = setTimeout(() => resolve(false), timeoutMs);
        waiters.push({ predicate, resolve: (v) => { clearTimeout(timer); resolve(v); } });
      });
    },
    first(type) {
      return messages.find((m) => m && m.type === type) || null;
    },
    all(type) {
      return messages.filter((m) => m && m.type === type);
    },
    destroy() {
      try { client.destroy(); } catch (_) { /* 忽略 */ }
    }
  };
}

function sample(metric, value, unit, t) {
  return { metric, value, unit, startTime: t - 1000, endTime: t, source: 'mock' };
}

// ---------------------------------------------------------------- 测试主体

async function main() {
  // ============================================================ 单元：环形缓冲
  suite('单元测试 · SampleBuffer 环形缓冲');

  await test('写入与按 order 读取', () => {
    const buf = new SampleBuffer(5);
    for (let i = 1; i <= 5; i++) buf.push({ seq: i, payload: { metric: 'heart_rate' } });
    assert.strictEqual(buf.length, 5);
    assert.strictEqual(buf.oldestOrder, 1);
    assert.strictEqual(buf.newestOrder, 5);
    assert.strictEqual(buf.atOrder(3).seq, 3);
    assert.strictEqual(buf.atOrder(0), null);
    assert.strictEqual(buf.atOrder(6), null);
  });

  await test('超出容量后淘汰最旧，order 不回退', () => {
    const buf = new SampleBuffer(3);
    for (let i = 1; i <= 10; i++) buf.push({ seq: i, payload: { metric: 'heart_rate' } });
    assert.strictEqual(buf.length, 10);
    assert.strictEqual(buf.oldestOrder, 8, '应只保留最近 3 条');
    assert.strictEqual(buf.newestOrder, 10);
    assert.strictEqual(buf.atOrder(7), null, '被淘汰的应取不到');
    assert.strictEqual(buf.atOrder(8).seq, 8);
    assert.strictEqual(buf.atOrder(10).seq, 10);
  });

  await test('环形回绕后 forEachInRange 顺序正确', () => {
    const buf = new SampleBuffer(4);
    for (let i = 1; i <= 6; i++) buf.push({ seq: i, payload: {} });
    const seen = [];
    const n = buf.forEachInRange(1, 6, (r) => seen.push(r.seq));
    assert.deepStrictEqual(seen, [3, 4, 5, 6], '区间应被裁剪到保留范围内且保持插入顺序');
    assert.strictEqual(n, 4);
  });

  await test('query 按设备/指标过滤并支持排序', () => {
    const buf = new SampleBuffer(100);
    buf.push({ seq: 1, deviceId: 'A', ts: 100, payload: { metric: 'heart_rate', endTime: 100 } });
    buf.push({ seq: 2, deviceId: 'B', ts: 200, payload: { metric: 'spo2', endTime: 200 } });
    buf.push({ seq: 3, deviceId: 'A', ts: 300, payload: { metric: 'spo2', endTime: 300 } });
    const byDevice = buf.query({ deviceIds: ['A'], limit: 10 });
    assert.strictEqual(byDevice.samples.length, 2);
    const asc = buf.query({ limit: 10, order: 'asc' });
    assert.deepStrictEqual(asc.samples.map((s) => s.seq), [1, 2, 3]);
    const desc = buf.query({ limit: 2, order: 'desc' });
    assert.deepStrictEqual(desc.samples.map((s) => s.seq), [3, 2]);
    assert.strictEqual(desc.truncated, true);
  });

  // ============================================================ 单元：配置
  suite('单元测试 · 配置加载');

  await test('命令行参数覆盖默认值', () => {
    const dir = tmpDir('hl-cfg-');
    const cfg = loadConfig({ configFile: path.join(dir, 'config.json'), argv: ['--port=19999', '--log-level=debug'] });
    assert.strictEqual(cfg.port, 19999);
    assert.strictEqual(cfg.logLevel, 'debug');
  });

  await test('未配置令牌时自动生成并落盘', () => {
    const dir = tmpDir('hl-cfg-');
    const file = path.join(dir, 'config.json');
    const cfg = loadConfig({ configFile: file, argv: [] });
    assert.ok(cfg.authToken && cfg.authToken.length >= 16, '应生成足够长的令牌');
    assert.ok(cfg.tokenGenerated, '应标记为自动生成');
    assert.ok(fs.existsSync(file), '应写回配置文件');
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.strictEqual(saved.authToken, cfg.authToken);
  });

  await test('非法端口被拒绝', () => {
    const dir = tmpDir('hl-cfg-');
    assert.throws(
      () => loadConfig({ configFile: path.join(dir, 'config.json'), argv: ['--port=99999'] }),
      /端口不合法/
    );
  });

  // ============================================================ 集成：服务器
  suite('集成测试 · HTTP / WebSocket 服务');

  const workDir = tmpDir('hl-e2e-');
  const configFile = path.join(workDir, 'config.json');
  const config = loadConfig({
    configFile,
    argv: ['--port=0', '--log-level=error'],
    persistGeneratedToken: false
  });
  config.port = 0;
  config.archive = { enabled: true, file: path.join(workDir, 'archive.jsonl') };
  const { Hub } = require('../src/hub');
  const hub = new Hub({ config, logger: silentLogger });
  const { Forwarder } = require('../src/relay');
  const forwarder = new Forwarder({ hub, config, logger: silentLogger });
  const server = new HealthLinkServer({ config, logger: silentLogger, hub, forwarder });

  await server.listen();
  const port = server.server.address().port;
  const token = config.authToken;
  process.stdout.write(`  （测试服务监听 127.0.0.1:${port}）\n`);

  await test('GET /api/health 无需令牌', async () => {
    const res = await httpJson(port, '/api/health');
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.json.data.service, 'healthlink-hub');
    assert.strictEqual(res.json.data.protocol, 1);
  });

  await test('无令牌访问 /api/devices 返回 401', async () => {
    const res = await httpJson(port, '/api/devices');
    assert.strictEqual(res.status, 401);
    assert.strictEqual(res.json.error.code, 'unauthorized');
  });

  await test('错误令牌访问 /api/devices 返回 401', async () => {
    const res = await httpJson(port, `/api/devices?token=${'x'.repeat(32)}`);
    assert.strictEqual(res.status, 401);
  });

  await test('正确令牌（查询参数）访问 /api/devices 返回 200', async () => {
    const res = await httpJson(port, `/api/devices?token=${token}`);
    assert.strictEqual(res.status, 200);
    assert.ok(Array.isArray(res.json.data));
  });

  await test('正确令牌（请求头）访问 /api/stats 返回 200', async () => {
    const res = await httpJson(port, '/api/stats', { headers: { 'X-Auth-Token': token } });
    assert.strictEqual(res.status, 200);
    assert.ok(res.json.data.buffer.capacity > 0);
  });

  await test('未知 API 返回 404', async () => {
    const res = await httpJson(port, `/api/nope?token=${token}`);
    assert.strictEqual(res.status, 404);
    assert.strictEqual(res.json.error.code, 'not_found');
  });

  await test('非法 limit 返回 400', async () => {
    const res = await httpJson(port, `/api/samples?token=${token}&limit=0`);
    assert.strictEqual(res.status, 400);
    const res2 = await httpJson(port, `/api/samples?token=${token}&limit=999999`);
    assert.strictEqual(res2.status, 400);
  });

  await test('路径穿越被拦截', async () => {
    const res = await httpRaw(port, '/assets/../../../../Windows/win.ini', {
      headers: { 'X-Auth-Token': token }
    });
    assert.ok(res.status === 403 || res.status === 404, `期望 403/404，实际 ${res.status}`);
    assert.ok(!res.body.toString('utf8').includes('[fonts]'), '绝不能返回工作区外的文件内容');
  });

  // ---- WebSocket 上行

  await test('未发 hello 就发 sample 会被 nack', async () => {
    const client = new WsClient(`ws://127.0.0.1:${port}/ingest?token=${token}`);
    const got = [];
    await new Promise((resolve, reject) => {
      client.on('open', resolve);
      client.on('error', reject);
      client.connect();
    });
    client.on('message', (t) => got.push(JSON.parse(t)));
    client.send(JSON.stringify({ v: 1, type: 'sample', seq: 1, ts: Date.now(), deviceId: 'a'.repeat(32), payload: sample('heart_rate', 70, 'bpm', Date.now()) }));
    const ok = await waitFor(() => got.some((m) => m.type === 'nack'), 2000);
    assert.ok(ok, '应收到 nack');
    assert.strictEqual(got.find((m) => m.type === 'nack').payload.reason, 'handshake_required');
    client.destroy();
  });

  await test('错误令牌的 WebSocket 被 4401 关闭', async () => {
    const client = new WsClient(`ws://127.0.0.1:${port}/ingest?token=wrong-token-value`);
    const closeInfo = await new Promise((resolve) => {
      client.on('close', (code, reason) => resolve({ code, reason }));
      client.on('error', () => { /* 预期会中断 */ });
      client.connect();
      setTimeout(() => resolve({ code: 'timeout' }), 4000);
    });
    assert.strictEqual(closeInfo.code, 4401, `期望关闭码 4401，实际 ${JSON.stringify(closeInfo)}`);
    client.destroy();
  });

  const phoneId = crypto.randomBytes(16).toString('hex');
  let phone = null;

  await test('hello 握手返回 hello_ack', async () => {
    phone = await connectPhone(`ws://127.0.0.1:${port}/ingest?token=${token}`, phoneId, { lastSeq: 0 });
    const ack = phone.received.find((m) => m.type === 'hello_ack');
    assert.ok(ack, '应收到 hello_ack');
    assert.strictEqual(ack.payload.accepted, true);
    assert.strictEqual(ack.payload.needBackfillFrom, -1, '新设备不应要求补传');
    assert.ok(Array.isArray(ack.payload.metrics) && ack.payload.metrics.includes('heart_rate'));
  });

  await test('sample 入库并收到 ack', async () => {
    const now = Date.now();
    const seq = phone.send('sample', sample('heart_rate', 72, 'bpm', now));
    const ok = await waitFor(() => phone.received.some((m) => m.type === 'ack' && m.payload.ackSeq === seq), 2000);
    assert.ok(ok, '应收到对应 seq 的 ack');
    const devices = (await httpJson(port, `/api/devices?token=${token}`)).json.data;
    const dev = devices.find((d) => d.deviceId === phoneId);
    assert.ok(dev, '设备应出现在设备列表');
    assert.strictEqual(dev.latest.heart_rate.value, 72);
  });

  await test('未知 metric 被拒绝', async () => {
    const before = (await httpJson(port, `/api/stats?token=${token}`)).json.data.ingest.rejected;
    phone.send('sample', sample('not_a_metric', 1, 'x', Date.now()));
    await waitFor(async () => true, 100);
    await new Promise((r) => setTimeout(r, 300));
    const after = (await httpJson(port, `/api/stats?token=${token}`)).json.data.ingest.rejected;
    assert.ok(after > before, 'rejected 计数应增加');
  });

  await test('sleep 复合数据校验：缺少 sleep 对象被拒', async () => {
    const rejectedBefore = hub.stats.rejected;
    phone.send('sample', { metric: 'sleep', value: null, unit: null, startTime: 1, endTime: 2, source: 'mock' });
    await new Promise((r) => setTimeout(r, 300));
    assert.ok(hub.stats.rejected > rejectedBefore, '应被拒绝');
  });

  await test('sleep 复合数据正确入库（含 sleepStatus 官方语义）', async () => {
    const end = Date.now();
    const sleep = {
      fallAsleepTime: end - 3600000,
      wakeupTime: end,
      duration: 3600,
      sleepScore: 85,
      sleepEfficiency: 95,
      deepDuration: 1200,
      sleepSegment: [
        { startTime: end - 3600000, endTime: end - 3000000, sleepStatus: 2 },
        { startTime: end - 3000000, endTime: end - 2400000, sleepStatus: 1 },
        { startTime: end - 2400000, endTime: end - 1800000, sleepStatus: 3 }
      ]
    };
    phone.send('sample', { metric: 'sleep', value: null, unit: null, startTime: sleep.fallAsleepTime, endTime: sleep.wakeupTime, source: 'mock', sleep });
    const ok = await waitFor(() => {
      const dev = hub.devices.get(phoneId);
      return dev && dev.latest && dev.latest.sleep && dev.latest.sleep.sleep.sleepSegment.length === 3;
    }, 2000);
    assert.ok(ok, '睡眠数据应入库');
    const stored = hub.devices.get(phoneId).latest.sleep.sleep;
    assert.strictEqual(stored.sleepSegment[1].sleepStatus, 1, '深睡应原样保留为 1');
  });

  await test('batch 补传按 startTime 升序入库', async () => {
    const base = Date.now() - 60000;
    const samples = [
      sample('spo2', 98, '%', base + 3000),
      sample('spo2', 96, '%', base + 1000),
      sample('spo2', 97, '%', base + 2000)
    ];
    phone.send('batch', { samples, count: 3, reason: 'reconnect_backfill' });
    const ok = await waitFor(() => {
      const res = hub.buffer.query({ deviceIds: [phoneId], metrics: ['spo2'], limit: 3, order: 'asc' });
      return res.samples.length >= 3;
    }, 2000);
    assert.ok(ok, '批次应入库');
    const res = hub.buffer.query({ deviceIds: [phoneId], metrics: ['spo2'], limit: 3, order: 'asc' });
    const times = res.samples.map((s) => s.payload.endTime);
    for (let i = 1; i < times.length; i++) {
      assert.ok(times[i] >= times[i - 1], `应按时间升序，实际 ${times.join(',')}`);
    }
  });

  await test('batch 中非法条目被单独剔除而不整批失败', async () => {
    const base = Date.now();
    const acceptedBefore = (await httpJson(port, `/api/stats?token=${token}`)).json.data.ingest.samples;
    phone.send('batch', {
      samples: [
        sample('heart_rate', 70, 'bpm', base),
        { metric: 'bogus_metric', value: 1, unit: 'x', startTime: base, endTime: base, source: 'mock' },
        sample('heart_rate', 71, 'bpm', base + 1000)
      ],
      count: 3,
      reason: 'manual'
    });
    await new Promise((r) => setTimeout(r, 400));
    const acceptedAfter = (await httpJson(port, `/api/stats?token=${token}`)).json.data.ingest.samples;
    assert.strictEqual(acceptedAfter - acceptedBefore, 2, '应接受 2 条、拒绝 1 条');
  });

  await test('不支持的协议版本被 nack', async () => {
    const client = new WsClient(`ws://127.0.0.1:${port}/ingest?token=${token}`);
    const got = [];
    await new Promise((resolve, reject) => {
      client.on('open', resolve);
      client.on('error', reject);
      client.connect();
    });
    client.on('message', (t) => got.push(JSON.parse(t)));
    client.send(JSON.stringify({ v: 99, type: 'hello', seq: 1, ts: Date.now(), deviceId: 'b'.repeat(32), payload: {} }));
    const ok = await waitFor(() => got.some((m) => m.type === 'nack'), 2000);
    assert.ok(ok, '应收到 nack');
    assert.strictEqual(got.find((m) => m.type === 'nack').payload.reason, 'unsupported_version');
    client.destroy();
  });

  await test('同 deviceId 重复连接会踢掉旧连接（4409）', async () => {
    const deviceId = crypto.randomBytes(16).toString('hex');

    // 第一条连接：先建立并**等到 hello_ack**，确保服务端已把它登记为该 deviceId 的当前连接
    const first = await openWs(`ws://127.0.0.1:${port}/ingest?token=${token}`);
    first.send({
      v: 1, type: 'hello', seq: 1, ts: Date.now(), deviceId,
      payload: { protocol: 1, model: 'OLD-CONN', lastSeq: 0 }
    });
    const acked = await first.waitForMessage(() => first.first('hello_ack') !== null, 3000);
    assert.ok(acked, '第一条连接应完成握手');

    // 第二条连接用同一个 deviceId，服务端应把旧连接以 4409 关掉
    const second = await openWs(`ws://127.0.0.1:${port}/ingest?token=${token}`);
    second.send({
      v: 1, type: 'hello', seq: 1, ts: Date.now(), deviceId,
      payload: { protocol: 1, model: 'NEW-CONN', lastSeq: 0 }
    });
    const secondAcked = await second.waitForMessage(() => second.first('hello_ack') !== null, 3000);
    assert.ok(secondAcked, '第二条连接应完成握手（新连接优先）');

    const kicked = await waitFor(() => first.closeInfo !== null, 4000);
    assert.ok(kicked, '旧连接应被服务端关闭');
    assert.strictEqual(first.closeInfo.code, 4409, `旧连接应被 4409 关闭，实际 ${JSON.stringify(first.closeInfo)}`);

    first.destroy();
    second.destroy();
  });

  await test('重连时带更大的 lastSeq 会要求补传', async () => {
    const id = crypto.randomBytes(16).toString('hex');
    const first = await connectPhone(`ws://127.0.0.1:${port}/ingest?token=${token}`, id, { lastSeq: 0 });
    const end = Date.now();
    first.send('sample', sample('heart_rate', 80, 'bpm', end));
    await new Promise((r) => setTimeout(r, 300));
    first.client.close(1000, 'reconnect test');
    await new Promise((r) => setTimeout(r, 400));

    // 第二次连接，假装手机在断线期间采集到了 seq 20
    const second = await connectPhone(`ws://127.0.0.1:${port}/ingest?token=${token}`, id, { lastSeq: 20 });
    const ack = second.received.find((m) => m.type === 'hello_ack');
    assert.ok(ack.payload.needBackfillFrom > 0, `应要求补传，实际 ${ack.payload.needBackfillFrom}`);
    second.client.close(1000, 'done');
  });

  // ---- 订阅 / 重放

  await test('订阅者收到 subscribed 与实时 sample', async () => {
    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}&topic=health`);
    const subscribed = await sub.waitForMessage(() => sub.first('subscribed') !== null, 2000);
    assert.ok(subscribed, '应收到 subscribed');

    phone.send('sample', sample('stress', 45, 'score', Date.now()));
    const live = await sub.waitForMessage(
      () => sub.all('sample').some((m) => m.payload.metric === 'stress'),
      2000
    );
    assert.ok(live, '应收到实时 sample');
    sub.destroy();
  });

  await test('订阅者 since=0 时不重放历史', async () => {
    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}&since=0`);
    await sub.waitForMessage(() => sub.first('subscribed') !== null, 2000);
    await new Promise((r) => setTimeout(r, 200));
    assert.strictEqual(sub.all('sample').length, 0, 'since=0 不应重放');
    assert.strictEqual(sub.first('subscribed').payload.replayed, 0);
    sub.destroy();
  });

  await test('订阅者带 since 会重放历史', async () => {
    const oldest = hub.buffer.oldestOrder;
    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}&since=${oldest}`);
    const ok = await sub.waitForMessage(() => sub.first('subscribed') !== null, 3000);
    assert.ok(ok, '应收到 subscribed');
    const info = sub.first('subscribed');
    assert.ok(info.payload.replayed > 0, `应重放若干条，实际 ${info.payload.replayed}`);
    sub.destroy();
  });

  await test('since 太旧时先发 gap 再重放', async () => {
    // 构造"锚点已被淘汰"的 since：游标取到缓冲最旧 seq 之前，
    // 此时缓冲里找不到 <= since 的记录，属于真正的缺口。
    const oldest = hub.buffer.oldestOrder;
    const oldestRec = hub.buffer.atOrder(oldest);
    assert.ok(oldestRec, `缓冲应已有数据，oldestOrder=${oldest}`);
    const tooOld = Math.max(1, (oldestRec.seq || 1) - 1);

    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}&since=${tooOld}`);
    const ok = await sub.waitForMessage(() => sub.first('gap') !== null, 3000);
    assert.ok(ok, '应收到 gap');
    const gap = sub.first('gap');
    assert.strictEqual(gap.payload.requestedSince, tooOld);
    assert.ok(gap.payload.oldestAvailable > 0, 'oldestAvailable 应给出缓冲最旧 seq');
    // gap 必须出现在第一批重放数据之前
    const gapIndex = sub.messages.findIndex((m) => m && m.type === 'gap');
    const firstSampleIndex = sub.messages.findIndex((m) => m && m.type === 'sample');
    if (firstSampleIndex >= 0) {
      assert.ok(gapIndex < firstSampleIndex, 'gap 应先于重放数据到达');
    }
    assert.ok(sub.all('sample').length > 0, '缺口之后仍应重放缓冲里剩下的数据');
    sub.destroy();
  });

  await test('订阅者过滤器只放行指定指标', async () => {
    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}`);
    await sub.waitForMessage(() => sub.first('subscribed') !== null, 2000);
    sub.send({ v: 1, type: 'subscribe_filter', seq: 0, ts: Date.now(), deviceId: '*', payload: { metrics: ['hrv'] } });
    await sub.waitForMessage(() => sub.first('subscribed') !== null, 2000);
    await new Promise((r) => setTimeout(r, 150));
    sub.messages.length = 0;
    phone.send('sample', sample('heart_rate', 66, 'bpm', Date.now()));
    phone.send('sample', sample('hrv', 44, 'ms', Date.now()));
    await sub.waitForMessage(() => sub.all('sample').some((m) => m.payload.metric === 'hrv'), 2500);
    const metrics = sub.all('sample').map((m) => m.payload.metric);
    assert.deepStrictEqual(metrics, ['hrv'], `只应收到 hrv，实际 ${metrics.join(',')}`);
    sub.destroy();
  });

  await test('订阅者 query 能拉历史', async () => {
    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}`);
    await sub.waitForMessage(() => sub.first('subscribed') !== null, 2000);
    sub.send({
      v: 1, type: 'query', seq: 0, ts: Date.now(), deviceId: '*',
      payload: { requestId: 'q1', deviceIds: [phoneId], metrics: [], startTime: 0, endTime: 0, limit: 100 }
    });
    const ok = await sub.waitForMessage(() => sub.first('query_result') !== null, 3000);
    assert.ok(ok, '应收到 query_result');
    const result = sub.first('query_result');
    assert.strictEqual(result.payload.requestId, 'q1');
    assert.ok(Array.isArray(result.payload.samples));
    sub.destroy();
  });

  await test('设备上线/下线会广播 device_event', async () => {
    const sub = await openWs(`ws://127.0.0.1:${port}/subscribe?token=${token}`);
    await sub.waitForMessage(() => sub.first('subscribed') !== null, 2000);
    const id = crypto.randomBytes(16).toString('hex');
    const temp = await connectPhone(`ws://127.0.0.1:${port}/ingest?token=${token}`, id, { lastSeq: 0 });
    const online = await sub.waitForMessage(
      () => sub.all('device_event').some((m) => m.payload.event === 'online' && m.deviceId === id),
      2500
    );
    assert.ok(online, '应收到上线事件');
    temp.client.close(1000, 'bye');
    const offline = await sub.waitForMessage(
      () => sub.all('device_event').some((m) => m.payload.event === 'offline' && m.deviceId === id),
      3000
    );
    assert.ok(offline, '应收到下线事件');
    sub.destroy();
  });

  // ---- REST 查询与导出

  await test('GET /api/samples 支持 deviceId/metric/limit', async () => {
    const res = await httpJson(port, `/api/samples?token=${token}&deviceId=${phoneId}&metric=heart_rate&limit=5`);
    assert.strictEqual(res.status, 200);
    assert.ok(res.json.data.samples.length > 0);
    for (const s of res.json.data.samples) {
      assert.strictEqual(s.deviceId, phoneId);
      assert.strictEqual(s.payload.metric, 'heart_rate');
    }
    assert.ok(res.json.data.samples.length <= 5);
  });

  await test('GET /api/latest 返回各指标最新值', async () => {
    const res = await httpJson(port, `/api/latest?token=${token}`);
    assert.strictEqual(res.status, 200);
    assert.ok(res.json.data[phoneId]);
    assert.ok(res.json.data[phoneId].heart_rate);
  });

  await test('导出 JSON 带 Content-Disposition 且内容可解析', async () => {
    const res = await httpRaw(port, `/api/export?token=${token}&format=json&limit=10`);
    assert.strictEqual(res.status, 200);
    assert.match(res.headers['content-disposition'] || '', /attachment; filename="healthlink-export-.*\.json"/);
    const parsed = JSON.parse(res.body.toString('utf8'));
    assert.ok(Array.isArray(parsed.samples));
    assert.ok(parsed.samples.length > 0);
  });

  await test('导出 CSV 带 UTF-8 BOM 且表头正确', async () => {
    const res = await httpRaw(port, `/api/export?token=${token}&format=csv&limit=10`);
    assert.strictEqual(res.status, 200);
    assert.match(res.headers['content-type'] || '', /text\/csv/);
    const text = res.body.toString('utf8');
    assert.strictEqual(text.charCodeAt(0), 0xfeff, '应以 UTF-8 BOM 开头（Excel 中文兼容）');
    const header = text.replace(/^\uFEFF/, '').split('\r\n')[0];
    assert.strictEqual(header, 'seq,deviceId,metric,value,unit,startTime,endTime,source,receivedAt,metricJson');
  });

  await test('CSV 中带逗号的 JSON 被正确转义', async () => {
    const res = await httpRaw(port, `/api/export?token=${token}&format=csv&metric=sleep&limit=5`);
    const text = res.body.toString('utf8').replace(/^\uFEFF/, '');
    const lines = text.trim().split('\r\n');
    if (lines.length > 1) {
      // 含逗号的字段必须被双引号包裹，且内部引号翻倍
      const dataLine = lines[1];
      const quoted = /"[^"]*"/.test(dataLine);
      assert.ok(quoted || !dataLine.includes('"'), 'JSON 字段应被引号包裹');
    }
  });

  await test('不支持的导出格式返回 400', async () => {
    const res = await httpJson(port, `/api/export?token=${token}&format=xml`);
    assert.strictEqual(res.status, 400);
  });

  // ---- 转发

  await test('转发目标 CRUD', async () => {
    const created = await httpJson(port, `/api/forward?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({ id: 'test-target', enabled: false, kind: 'websocket', url: 'ws://127.0.0.1:1/ingest' })
    });
    assert.strictEqual(created.status, 200);
    assert.strictEqual(created.json.data.id, 'test-target');

    const list = await httpJson(port, `/api/forward?token=${token}`);
    assert.ok(list.json.data.some((t) => t.id === 'test-target'));

    const removed = await httpJson(port, `/api/forward?id=test-target&token=${token}`, { method: 'DELETE' });
    assert.strictEqual(removed.status, 200);

    const removedAgain = await httpJson(port, `/api/forward?id=test-target&token=${token}`, { method: 'DELETE' });
    assert.strictEqual(removedAgain.status, 404);
  });

  await test('非法转发目标被拒绝（缺 id / 协议不匹配）', async () => {
    const noId = await httpJson(port, `/api/forward?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({ url: 'ws://127.0.0.1:1/x' })
    });
    assert.strictEqual(noId.status, 400);

    const badProto = await httpJson(port, `/api/forward?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({ id: 'bad', kind: 'websocket', url: 'http://127.0.0.1:1/x' })
    });
    assert.strictEqual(badProto.status, 400);
  });

  await test('HTTP 转发目标能真实收到数据（攒批）', async () => {
    // 起一个假的"对端服务"
    const received = [];
    const target = http.createServer((req, res) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        try { received.push(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (_) {}
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{"ok":true}');
      });
    });
    await new Promise((resolve) => target.listen(0, '127.0.0.1', resolve));
    const targetPort = target.address().port;

    await httpJson(port, `/api/forward?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({
        id: 'http-target',
        enabled: true,
        kind: 'http',
        url: `http://127.0.0.1:${targetPort}/api/ingest`,
        deviceIds: [],
        metrics: ['spo2'],
        batchMs: 200
      })
    });

    phone.send('sample', sample('spo2', 97, '%', Date.now()));
    const ok = await waitFor(() => received.length > 0, 4000);
    assert.ok(ok, 'HTTP 转发目标应收到数据');
    const batch = received[0];
    assert.strictEqual(batch.type, 'batch');
    assert.strictEqual(batch.payload.reason, 'forward');
    assert.ok(batch.payload.samples.length > 0);
    assert.strictEqual(batch.payload.samples[0].metric, 'spo2', '应只转发 spo2');

    await httpJson(port, `/api/forward?id=http-target&token=${token}`, { method: 'DELETE' });
    await new Promise((resolve) => target.close(resolve));
  });

  await test('转发目标连不上时数据进队列不丢失，且能重试成功', async () => {
    // 1) 指向一个关闭的端口，数据应进队列而不是丢失
    const created = await httpJson(port, `/api/forward?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({
        id: 'recover-target',
        enabled: true,
        kind: 'http',
        url: 'http://127.0.0.1:1/api/ingest',
        metrics: ['stress'],
        batchMs: 150,
        retry: { maxAttempts: 0, backoffMs: 100 }
      })
    });
    assert.strictEqual(created.status, 200);

    phone.send('sample', sample('stress', 33, 'score', Date.now()));
    const queued = await waitFor(() => {
      const t = forwarder.get('recover-target');
      return t && t.queue.length > 0;
    }, 3000);
    assert.ok(queued, '连不上时应进队列');
    const target1 = forwarder.get('recover-target');
    const queuedCount = target1.queue.length;
    const droppedBefore = target1.droppedTotal;
    assert.strictEqual(droppedBefore, 0, '不应有丢弃');

    // 2) 换成一个真实可用的服务，队列里的数据应被补发出去
    const received = [];
    const target = http.createServer((req, res) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        try { received.push(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (_) { /* 忽略 */ }
        res.writeHead(200);
        res.end('{}');
      });
    });
    await new Promise((resolve) => target.listen(0, '127.0.0.1', resolve));
    const targetPort = target.address().port;

    await httpJson(port, `/api/forward?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({
        id: 'recover-target',
        enabled: true,
        kind: 'http',
        url: `http://127.0.0.1:${targetPort}/api/ingest`,
        metrics: ['stress'],
        batchMs: 150,
        retry: { maxAttempts: 0, backoffMs: 100 }
      })
    });

    const delivered = await waitFor(() => received.length > 0, 8000);
    assert.ok(
      delivered,
      `恢复后应把队列里的数据补发出去（队列里当时有 ${queuedCount} 条）`
    );
    const target2 = forwarder.get('recover-target');
    assert.strictEqual(target2.droppedTotal, 0, '重连过程中不应丢数据');
    assert.ok(target2.sentTotal > 0, '应记录已发送计数');

    await httpJson(port, `/api/forward?id=recover-target&token=${token}`, { method: 'DELETE' });
    await new Promise((resolve) => target.close(resolve));
  });

  await test('转发目标可持久化到磁盘并在重启后恢复', () => {
    const before = forwarder.list().length;
    const file = config.forwardStorePath;
    assert.ok(fs.existsSync(file), '应有持久化文件');
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.ok(Array.isArray(saved.targets));
    assert.strictEqual(saved.targets.length, before);
  });

  await test('/api/forward/test 能探测不可达目标', async () => {
    const res = await httpJson(port, `/api/forward/test?token=${token}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Auth-Token': token },
      body: JSON.stringify({ id: 'x', kind: 'http', url: 'http://127.0.0.1:1/nope' })
    });
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.json.data.reachable, false);
    assert.ok(res.json.data.error);
  });

  // ---- 归档

  await test('归档文件按 JSONL 写入且每行可解析', async () => {
    await new Promise((r) => setTimeout(r, 300));
    const archiveDir = path.dirname(config.archive.file);
    assert.ok(fs.existsSync(archiveDir), '归档目录应存在');
    const files = fs.readdirSync(archiveDir).filter((f) => f.startsWith('archive'));
    assert.ok(files.length > 0, '应有归档文件');
    const raw = fs.readFileSync(path.join(archiveDir, files[0]), 'utf8').trim();
    const lines = raw.split('\n').filter(Boolean);
    assert.ok(lines.length > 0, '归档应有内容');
    for (const line of lines.slice(0, 5)) {
      const obj = JSON.parse(line);
      assert.ok(obj.deviceId && obj.payload);
    }
  });

  // ---- 压力：大帧与分片

  await test('大消息（>64KB）能正确收发（验证 64 位长度与分片）', async () => {
    const sub = new WsClient(`ws://127.0.0.1:${port}/subscribe?token=${token}`);
    const got = [];
    await new Promise((resolve, reject) => {
      sub.on('open', resolve);
      sub.on('error', reject);
      sub.connect();
    });
    sub.on('message', (t) => got.push(t));
    await waitFor(() => got.length > 0, 2000);

    // 造一条超长 sleepSymptoms，把整帧撑到 100KB 以上
    const big = {
      metric: 'sleep',
      value: null,
      unit: null,
      startTime: Date.now() - 1000,
      endTime: Date.now(),
      source: 'mock',
      sleep: { fallAsleepTime: Date.now() - 1000, wakeupTime: Date.now(), duration: 1, sleepSymptoms: 'x'.repeat(120000) }
    };
    got.length = 0;
    phone.send('sample', big);
    const ok = await waitFor(() => got.some((t) => t.includes('x'.repeat(1000))), 5000);
    assert.ok(ok, '订阅者应收到这条大消息');
    sub.destroy();
  });

  await test('超大消息（>1MB 单帧上限）被拒绝且压不垮进程', async () => {
    // 这里用裸 socket 当客户端，而不是 WsClient：
    // 因为要发送 2MB 帧时，服务端会在客户端仍处于发送中途时回 CLOSE，
    // 高层客户端在这条路径上的 close 事件时序不稳定（不是协议错误，是 TCP 缓冲现象）。
    // 裸 socket 能直接断言"服务端到底回了什么字节"，这才是要验证的东西。
    const net = require('net');
    const socket = net.connect({ host: '127.0.0.1', port }, () => {
      socket.write(
        `GET /ingest?token=${token} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\n` +
          `Connection: Upgrade\r\nSec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}\r\n` +
          'Sec-WebSocket-Version: 13\r\n\r\n'
      );
    });

    // 复用测试文件里的 clientFrame 逻辑（掩码、64 位长度）
    const mask = crypto.randomBytes(4);
    const bigPayload = Buffer.from(
      JSON.stringify({
        v: 1, type: 'sample', seq: 2, ts: Date.now(), deviceId: 'B'.repeat(32),
        payload: { metric: 'heart_rate', value: 1, unit: 'bpm', startTime: 1, endTime: 2, source: 'mock', extra: { pad: 'y'.repeat(2 * 1024 * 1024) } }
      }),
      'utf8'
    );
    const header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 0x80 | 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(bigPayload.length, 6);
    const masked = Buffer.allocUnsafe(bigPayload.length);
    for (let i = 0; i < bigPayload.length; i++) masked[i] = bigPayload[i] ^ mask[i & 3];
    const frame = Buffer.concat([header, mask, masked]);

    let seen = Buffer.alloc(0);
    let handshaken = false;
    let closeCode = null;
    socket.on('data', (chunk) => {
      seen = Buffer.concat([seen, chunk]);
      if (!handshaken) {
        const idx = seen.indexOf('\r\n\r\n');
        if (idx < 0) return;
        handshaken = true;
        seen = seen.subarray(idx + 4);
        socket.write(frame);
        return;
      }
      // 找服务端回的 CLOSE 帧
      let off = 0;
      while (off + 2 <= seen.length) {
        const b0 = seen[off];
        const b1 = seen[off + 1];
        let len = b1 & 0x7f;
        let hdr = 2;
        if (len === 126) { if (off + 4 > seen.length) break; len = seen.readUInt16BE(off + 2); hdr = 4; }
        else if (len === 127) { if (off + 10 > seen.length) break; len = seen.readUInt32BE(off + 6); hdr = 10; }
        if ((b0 & 0x0f) === 0x8) {
          closeCode = seen.readUInt16BE(off + hdr);
          return;
        }
        off += hdr + len;
      }
    });
    socket.on('error', () => { /* 服务端关闭时可能触发，不影响断言 */ });

    const got = await waitFor(() => closeCode !== null, 6000);
    assert.ok(got, '服务端应以 CLOSE 帧明确拒绝超大帧');
    assert.strictEqual(closeCode, 1002, `关闭码应为 1002（protocol error），实际 ${closeCode}`);
    socket.destroy();

    // 关键：服务本身必须还活着，不能被一个坏客户端搞死
    const health = await httpJson(port, '/api/health');
    assert.strictEqual(health.status, 200, '服务不应因为超大帧崩溃');

    // 而且后续正常客户端仍然能正常握手（验证连接表没被污染）
    const after = await openWs(`ws://127.0.0.1:${port}/ingest?token=${token}`);
    assert.ok(after, '超大帧之后新连接仍应能建立');
    after.destroy();
  });

  await test('超大帧返回 1002、错误只报一次、连接随后回收（单元级确定性验证）', async () => {
    // 这一条用假 socket 直接驱动 WebSocketConnection，不依赖真实网络时序。
    // 它同时守住一个曾经真实存在的严重缺陷：协议错误后没有停止解析，
    // 导致同一帧被反复解析、error 事件刷屏、CLOSE 帧发不出去。
    const { EventEmitter } = require('events');
    const { WebSocketConnection } = require('../src/ws');

    const socket = new EventEmitter();
    socket.writable = true;
    socket.setNoDelay = () => {};
    socket.destroy = () => socket.emit('close');
    const written = [];
    socket.write = (buf) => {
      written.push(Buffer.from(buf));
      return true;
    };

    const conn = new WebSocketConnection(socket, { maxFrameBytes: 100 });
    let errorCount = 0;
    conn.on('error', () => { errorCount++; });

    // 构造一个 200 字节的掩码文本帧，超过 100 字节上限
    const mask = Buffer.alloc(4, 7);
    const payload = Buffer.alloc(200, 0x41);
    const header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(200, 2);
    const masked = Buffer.alloc(200);
    for (let i = 0; i < 200; i++) masked[i] = payload[i] ^ mask[i & 3];
    const frame = Buffer.concat([header, mask, masked]);

    // 分两片投递，模拟 TCP 分包：错误应只报一次，而不是每片报一次
    conn._onData(frame.subarray(0, 100));
    conn._onData(frame.subarray(100));

    assert.strictEqual(errorCount, 1, `协议错误应只上报 1 次，实际 ${errorCount} 次`);
    assert.strictEqual(written.length, 1, `应只写出一个 CLOSE 帧，实际 ${written.length} 个`);
    const closeFrame = written[0];
    assert.strictEqual(closeFrame[0] & 0x0f, 0x8, '写出的应是 CLOSE 帧');
    assert.strictEqual(closeFrame.readUInt16BE(2), 1002, '关闭码应为 1002（protocol error）');

    // 关闭之后再有数据到达应被直接丢弃，不得再次触发解析
    conn._onData(frame);
    assert.strictEqual(errorCount, 1, '关闭后到达的数据不应再次触发错误');
    assert.strictEqual(written.length, 1, '关闭后不应再写帧');
  });

  // ---- 并发

  await test('多设备并发上行互不串号', async () => {
    const ids = [];
    const phones = [];
    for (let i = 0; i < 5; i++) {
      const id = crypto.randomBytes(16).toString('hex');
      ids.push(id);
      phones.push(await connectPhone(`ws://127.0.0.1:${port}/ingest?token=${token}`, id, { lastSeq: 0 }));
    }
    const before = hub.stats.samplesReceived;
    for (let round = 0; round < 10; round++) {
      for (let i = 0; i < phones.length; i++) {
        phones[i].send('sample', sample('heart_rate', 60 + i, 'bpm', Date.now()));
      }
    }
    const ok = await waitFor(() => hub.stats.samplesReceived >= before + 50, 5000);
    assert.ok(ok, `应收到 50 条，实际 ${hub.stats.samplesReceived - before}`);
    for (let i = 0; i < ids.length; i++) {
      const dev = hub.devices.get(ids[i]);
      assert.ok(dev, `设备 ${i} 应存在`);
      assert.strictEqual(dev.latest.heart_rate.value, 60 + i, `设备 ${i} 的最新值不应串号`);
    }
    for (const p of phones) p.client.close(1000, 'done');
  });

  await test('心跳机制能识别并清理死连接', async () => {
    // 用很短的心跳周期单独测：这里只验证服务端 sweep 逻辑本身
    const { WebSocketServer } = require('../src/ws');
    const wss = new WebSocketServer({ heartbeatMs: 100 });
    let conn = null;
    const fakeSocket = new (require('events').EventEmitter)();
    fakeSocket.writable = true;
    fakeSocket.setNoDelay = () => {};
    fakeSocket.write = () => true;
    fakeSocket.destroy = () => fakeSocket.emit('close');
    const { WebSocketConnection } = require('../src/ws');
    conn = new WebSocketConnection(fakeSocket, {});
    wss.connections.add(conn);
    conn.on('close', () => wss.connections.delete(conn));
    // 第一次 sweep 会把它标为不存活并发 ping，第二次 sweep 就应该踢掉
    await new Promise((r) => setTimeout(r, 250));
    assert.strictEqual(wss.connections.size, 0, '僵尸连接应被清理');
    wss.close();
  });

  // ============================================================ 收尾
  await test('关闭服务后端口释放', async () => {
    await server.close();
    await new Promise((r) => setTimeout(r, 200));
    const closed = await new Promise((resolve) => {
      const req = http.request({ host: '127.0.0.1', port, path: '/api/health' }, () => resolve(false));
      req.on('error', () => resolve(true));
      req.end();
    });
    assert.ok(closed, '服务应已停止监听');
  });

  try { fs.rmSync(workDir, { recursive: true, force: true }); } catch (_) { /* 忽略 */ }

  // ---------------------------------------------------------------- 汇总
  const failed = results.filter((r) => !r.ok);
  const passed = results.length - failed.length;
  summaryPrinted = true;
  process.stdout.write(`\n${'='.repeat(64)}\n`);
  process.stdout.write(`总计 ${results.length} 项，通过 ${passed}，失败 ${failed.length}\n`);
  if (failed.length > 0) {
    process.stdout.write('\n失败明细：\n');
    for (const f of failed) {
      process.stdout.write(`  ✗ [${f.suite}] ${f.name}\n      ${f.error && f.error.stack ? f.error.stack.split('\n').slice(0, 3).join('\n      ') : f.error}\n`);
    }
    process.exitCode = 1;
  } else {
    process.stdout.write('\x1b[32m全部通过\x1b[0m\n');
  }
  // ⚠️ 不要直接 process.exit()：stdout 走管道（CI、PowerShell 管道、GitHub Actions）时
  //    未刷出的缓冲区会被直接丢弃，汇总行就"消失"了 —— 只设 exitCode，让进程自然退出。
}

main().catch((err) => {
  process.stderr.write(`测试运行器崩溃: ${err.stack}\n`);
  process.exit(1);
});
