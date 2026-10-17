/**
 * PcBleSource 纯逻辑验证（不碰蓝牙、不启服务）
 *
 * 覆盖最近修掉的三个问题：
 *   1) 连上以后 lastError 要清空（否则面板一直挂着旧故障）
 *   2) 同一条错误 30 秒内只打一次日志（否则重连循环把控制台刷满）
 *   3) 心率 + RR 间期 → 入库 heart_rate，并顺带算 HRV
 */
'use strict';
const path = require('path');
const { PcBleSource, LOCAL_DEVICE_ID } = require(path.resolve(__dirname, '..', 'src', 'pcBleSource.js'));

let pass = 0, fail = 0;
function check(label, ok, extra = '') {
  ok ? pass++ : fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${label}${extra ? '  → ' + extra : ''}`);
}

const warns = [];
const infos = [];
const samples = [];
const logger = {
  info: (m) => infos.push(m),
  warn: (m) => warns.push(m),
  error: (m) => warns.push('ERR ' + m),
};

let registered = null;
const hub = {
  registerLocalDevice: (id, info) => { registered = { id, info }; },
  unregisterLocalDevice: () => { registered = null; },
  ingestLocalSample: (id, payload) => { samples.push(payload); return { ok: true }; },
};

const src = new PcBleSource({ hub, config: { pcBle: { enabled: true } }, logger });
const send = (obj) => src._onData(JSON.stringify(obj) + '\n');

// 1) 先来一条错误 → 应该记进 lastError 并打一条 warn
send({ t: 'error', msg: '拿不到设备对象（测试）' });
check('错误写进 lastError', src.state.lastError === '拿不到设备对象（测试）', src.state.lastError);
check('错误打了一条日志', warns.length === 1, `warns=${warns.length}`);

// 2) 同一条错误再来三次 → 30 秒内不再刷屏
send({ t: 'error', msg: '拿不到设备对象（测试）' });
send({ t: 'error', msg: '拿不到设备对象（测试）' });
send({ t: 'error', msg: '拿不到设备对象（测试）' });
check('重复错误不重复刷日志', warns.length === 1, `warns=${warns.length}`);

// 3) 连上以后 lastError 必须清空
send({ t: 'connected', name: 'HW9-12345', id: 'AA:BB:CC:DD:EE:FF' });
check('连接成功清空 lastError', src.state.lastError === '', JSON.stringify(src.state.lastError));
check('连接成功注册本机设备', registered && registered.id === LOCAL_DEVICE_ID, JSON.stringify(registered && registered.info));
check('连接状态为 true', src.state.connected === true);

// 4) 心率 + RR 间期 → heart_rate 和 hrv 都入库
//    flags=0x10 → 带 RR；bpm=88；RR 依次约 680ms（1/1024 秒单位 ≈ 697/697/686/697）
send({ t: 'hr', bpm: 88, rr: [697, 697, 686, 697] });
const hr = samples.find((s) => s.metric === 'heart_rate');
const hrv = samples.find((s) => s.metric === 'hrv');
check('heart_rate 入库', !!hr && hr.value === 88 && hr.source === 'pc-ble', JSON.stringify(hr));
check('hrv(RMSSD) 入库', !!hrv && hrv.value >= 0 && hrv.unit === 'ms', JSON.stringify(hrv));

// 5) 节流：1 秒内连推多次心率，只入库一条
const before = samples.filter((s) => s.metric === 'heart_rate').length;
send({ t: 'hr', bpm: 90 });
send({ t: 'hr', bpm: 91 });
check('心率节流生效', samples.filter((s) => s.metric === 'heart_rate').length === before,
  `之前 ${before} 条，之后 ${samples.filter((s) => s.metric === 'heart_rate').length} 条`);

// 6) 断开 → 注销设备
send({ t: 'disconnected', reason: '设备侧断开' });
check('断开后注销设备', registered === null && src.state.connected === false);

console.log(`\n  结果: ${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
