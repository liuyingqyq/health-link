#!/usr/bin/env node
'use strict';
/**
 * 手机端模拟器 —— 在没有真机的情况下验证整条链路。
 *
 * 它**严格按 docs/protocol/README.md v1 说话**，用与 ArkTS 端相同的信封、
 * 相同的 metric 枚举、相同的 sleepStatus 语义。所以：
 *   - 电脑端能收模拟器的数据 → 电脑端实现正确
 *   - 真机能发同样的包    → 链路通
 *
 * 用法：
 *   node tools/phone-sim.js --url ws://127.0.0.1:18787/ingest?token=xxx
 *   node tools/phone-sim.js --url ... --interval 1000 --devices 2 --sleep
 *   node tools/phone-sim.js --url ... --offline 5      # 前 5 秒假装断网，测补传
 *   node tools/phone-sim.js --url ... --disconnect 10  # 第 10 秒断开一次，测重连
 */

const crypto = require('crypto');
const { WsClient } = require('../pc/src/wsclient');

const METRICS = [
  { metric: 'heart_rate', unit: 'bpm', min: 58, max: 96 },
  { metric: 'resting_heart_rate', unit: 'bpm', min: 48, max: 68 },
  { metric: 'hrv', unit: 'ms', min: 28, max: 78 },
  { metric: 'spo2', unit: '%', min: 95, max: 99 },
  { metric: 'stress', unit: 'score', min: 18, max: 72 }
];

function parseArgs(argv) {
  const out = {
    url: '',
    interval: 2000,
    devices: 1,
    sleep: false,
    offline: 0,
    disconnect: 0,
    duration: 0,
    token: ''
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const eq = arg.indexOf('=');
    const key = eq >= 0 ? arg.slice(2, eq) : arg.slice(2);
    const val = eq >= 0 ? arg.slice(eq + 1) : argv[++i];
    if (!key.startsWith('') || arg.slice(0, 2) !== '--') continue;
    switch (key) {
      case 'url': out.url = val; break;
      case 'interval': out.interval = Number(val); break;
      case 'devices': out.devices = Number(val); break;
      case 'sleep': out.sleep = true; break;
      case 'offline': out.offline = Number(val); break;
      case 'disconnect': out.disconnect = Number(val); break;
      case 'duration': out.duration = Number(val); break;
      case 'token': out.token = val; break;
      default: break;
    }
  }
  if (!out.url) {
    const port = process.env.HEALTHLINK_PORT || 18787;
    const token = out.token || process.env.HEALTHLINK_TOKEN || '';
    out.url = `ws://127.0.0.1:${port}/ingest?token=${token}`;
  }
  return out;
}

function randInt(min, max) {
  return Math.floor(min + Math.random() * (max - min + 1));
}

/** 生成一段符合协议 3.4 节的睡眠数据：sleepStatus 官方语义 1深睡 2浅睡 3REM 4清醒 */
function buildSleep(endTime) {
  const wakeupTime = endTime;
  const fallAsleepTime = wakeupTime - 7 * 3600 * 1000;
  const segments = [];
  let cursor = fallAsleepTime;
  const plan = [
    { status: 2, minutes: 35 },
    { status: 1, minutes: 55 },
    { status: 2, minutes: 40 },
    { status: 3, minutes: 25 },
    { status: 2, minutes: 60 },
    { status: 4, minutes: 8 },
    { status: 1, minutes: 45 },
    { status: 3, minutes: 30 },
    { status: 2, minutes: 70 },
    { status: 1, minutes: 35 },
    { status: 2, minutes: 40 }
  ];
  let deep = 0;
  let shallow = 0;
  let dream = 0;
  let awake = 0;
  for (const item of plan) {
    const ms = item.minutes * 60 * 1000;
    segments.push({ startTime: cursor, endTime: cursor + ms, sleepStatus: item.status });
    cursor += ms;
    if (item.status === 1) deep += item.minutes * 60;
    else if (item.status === 2) shallow += item.minutes * 60;
    else if (item.status === 3) dream += item.minutes * 60;
    else if (item.status === 4) awake += item.minutes * 60;
  }
  const duration = Math.round((cursor - fallAsleepTime) / 1000);
  return {
    fallAsleepTime,
    wakeupTime: cursor,
    duration,
    sleepScore: randInt(72, 92),
    sleepEfficiency: randInt(88, 98),
    deepSleepContinuity: randInt(40, 80),
    respiratoryQualityScore: randInt(60, 95),
    deepDuration: deep,
    shallowDuration: shallow,
    dreamDuration: dream,
    wakeDuration: awake,
    wakeCount: randInt(0, 4),
    turnOverCount: randInt(4, 25),
    sleepType: 1,
    sleepEndReason: 1,
    sleepSegment: segments
  };
}

class FakePhone {
  constructor(options, index) {
    this.options = options;
    this.deviceId = crypto.randomBytes(16).toString('hex');
    this.seq = 0;
    this.model = index === 0 ? 'HUAWEI Mate 60 Pro (模拟)' : `HUAWEI Watch (模拟-${index})`;
    this.client = null;
    this.queue = [];
    this.timer = null;
    this.offlineUntil = options.offline > 0 ? Date.now() + options.offline * 1000 : 0;
    this.sent = 0;
    this.connected = false;
    this.reconnectAttempt = 0;
  }

  log(message) {
    process.stdout.write(`[设备${this.deviceId.slice(0, 8)}] ${message}\n`);
  }

  start() {
    this.connect();
    this.timer = setInterval(() => this.tick(), this.options.interval);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    if (this.client) {
      try { this.client.close(1000, 'simulator done'); } catch (_) { /* 忽略 */ }
    }
  }

  connect() {
    if (Date.now() < this.offlineUntil) {
      this.log(`假装离线中，${Math.ceil((this.offlineUntil - Date.now()) / 1000)}s 后重连`);
      setTimeout(() => this.connect(), this.offlineUntil - Date.now() + 50);
      return;
    }
    const client = new WsClient(this.options.url, { connectTimeoutMs: 4000 });
    this.client = client;
    client.on('open', () => {
      this.connected = true;
      this.reconnectAttempt = 0;
      this.log('已连接电脑端');
      this.sendHello();
      this.flush();
    });
    client.on('message', (text) => this.onMessage(text));
    client.on('error', (err) => this.log(`连接错误: ${err.message}`));
    client.on('close', (code) => {
      this.connected = false;
      this.client = null;
      if (this.stopping) return;
      const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempt++), 30000);
      this.log(`断开 code=${code}，${delay}ms 后重连`);
      setTimeout(() => this.connect(), delay);
    });
    client.connect();
  }

  onMessage(text) {
    let env;
    try { env = JSON.parse(text); } catch (_) { return; }
    if (env.type === 'hello_ack') {
      const p = env.payload || {};
      this.log(`收到 hello_ack：需补传自 ${p.needBackfillFrom}，电脑下发周期 ${p.collectIntervalMs}ms`);
      if (p.needBackfillFrom > 0 && this.queue.length > 0) {
        this.sendBatch('reconnect_backfill');
      }
    } else if (env.type === 'nack') {
      this.log(`收到 nack: ${JSON.stringify(env.payload)}`);
    }
  }

  envelope(type, payload) {
    return { v: 1, type, seq: ++this.seq, ts: Date.now(), deviceId: this.deviceId, payload };
  }

  sendHello() {
    this.send(this.envelope('hello', {
      protocol: 1,
      model: this.model,
      osVersion: 'HarmonyOS 6.0.0 (模拟)',
      appVersion: '1.0.0-sim',
      collectIntervalMs: this.options.interval,
      lastSeq: this.seq,
      backgroundMode: ['bluetoothInteraction', 'dataTransfer'],
      healthStoreReady: true,
      permissions: { healthDataRead: true, internet: true, keepBackgroundRunning: true }
    }));
  }

  send(env) {
    if (this.connected && this.client) {
      try {
        this.client.send(JSON.stringify(env));
        this.sent++;
        return;
      } catch (_) { /* 落到队列 */ }
    }
    this.queue.push(env);
    if (this.queue.length > 2000) this.queue.shift();
  }

  flush() {
    if (this.queue.length === 0) return;
    const pending = this.queue;
    this.queue = [];
    this.log(`补发离线队列 ${pending.length} 条`);
    for (const env of pending) {
      try { this.client.send(JSON.stringify(env)); this.sent++; } catch (_) { this.queue.push(env); }
    }
  }

  sendBatch(reason) {
    const samples = this.queue.splice(0, Math.min(this.queue.length, 200));
    if (samples.length === 0) return;
    this.send({
      v: 1,
      type: 'batch',
      seq: ++this.seq,
      ts: Date.now(),
      deviceId: this.deviceId,
      payload: {
        samples: samples.map((e) => e.payload),
        count: samples.length,
        reason
      }
    });
  }

  tick() {
    const now = Date.now();
    for (const m of METRICS) {
      const payload = {
        metric: m.metric,
        value: randInt(m.min, m.max),
        unit: m.unit,
        startTime: now - this.options.interval,
        endTime: now,
        source: 'mock'
      };
      this.send(this.envelope('sample', payload));
    }
    // 睡眠不是每次都有，每 10 轮发一次
    if (this.options.sleep && Math.random() < 0.1) {
      const sleep = buildSleep(now);
      this.send(this.envelope('sample', {
        metric: 'sleep',
        value: null,
        unit: null,
        startTime: sleep.fallAsleepTime,
        endTime: sleep.wakeupTime,
        source: 'mock',
        sleep
      }));
      this.log(`已发送睡眠记录：得分 ${sleep.sleepScore}，分期 ${sleep.sleepSegment.length} 段`);
    }
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  process.stdout.write(
    `手机端模拟器启动\n  目标: ${options.url}\n  设备数: ${options.devices}  周期: ${options.interval}ms` +
      `${options.offline ? `  初始离线: ${options.offline}s` : ''}${options.sleep ? '  含睡眠数据' : ''}\n`
  );
  const phones = [];
  for (let i = 0; i < options.devices; i++) {
    const phone = new FakePhone(options, i);
    phone.stopping = false;
    phones.push(phone);
    setTimeout(() => phone.start(), i * 300);
  }

  if (options.disconnect > 0) {
    setTimeout(() => {
      for (const phone of phones) {
        if (phone.client) {
          process.stdout.write(`[模拟] 主动断开一次以测试重连\n`);
          phone.client.destroy();
        }
      }
    }, options.disconnect * 1000);
  }

  const shutdown = () => {
    process.stdout.write('\n[模拟] 停止中...\n');
    for (const phone of phones) {
      phone.stopping = true;
      phone.stop();
    }
    const total = phones.reduce((sum, p) => sum + p.sent, 0);
    process.stdout.write(`[模拟] 共发送 ${total} 条\n`);
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  if (options.duration > 0) {
    setTimeout(shutdown, options.duration * 1000);
  }
}

if (require.main === module) main();

module.exports = { FakePhone, buildSleep, parseArgs, METRICS };
