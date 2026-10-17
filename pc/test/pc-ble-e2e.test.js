/**
 * PC 蓝牙桥端到端验证
 *
 * 真实验证链路：心率带 ──> HealthLinkBle.exe ──> Node 消费 ──> hub ──> REST API
 *
 * 前提：心率带已佩戴、手机 App 已停止。
 * 会启动带桥的服务端，等待最多 90 秒，检查：
 *   1) /api/pcble 显示已连接
 *   2) 设备列表里出现本机设备且在线
 *   3) /api/latest 能读到 heart_rate
 *   4) /api/samples 有 pc-ble 来源的样本
 */
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..', '..');
const PORT = 18901;   // 用独立端口，避免和正在运行的服务打架
const TOKEN = 'pcble-bridge-verify-token';

let pass = 0, fail = 0;
const log = [];
function check(label, ok, extra = '') {
  ok ? pass++ : fail++;
  log.push(`  [${ok ? 'PASS' : 'FAIL'}] ${label}${extra ? '  → ' + extra : ''}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function api(pathname) {
  return new Promise((resolve) => {
    // ⚠️ 拼 token 时要用正确的分隔符：路径里可能已经带了 ?limit=20，
    //    再写 '?token=' 会变成 '?limit=20?token='，token 被解析成 "20?token=xxx" → 鉴权失败。
    const sep = pathname.includes('?') ? '&' : '?';
    const req = http.get(
      { host: '127.0.0.1', port: PORT, path: `${pathname}${sep}token=${TOKEN}`, timeout: 5000 },
      (res) => {
        let b = '';
        res.setEncoding('utf8');
        res.on('data', (d) => (b += d));
        res.on('end', () => {
          try { resolve({ status: res.statusCode, json: JSON.parse(b) }); }
          catch { resolve({ status: res.statusCode, json: null, raw: b }); }
        });
      }
    );
    req.on('error', (e) => resolve({ status: 0, error: e.code }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, error: 'timeout' }); });
  });
}

(async () => {
  // 用临时配置目录，避免污染 pc/config.json
  const tmpDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'hl-pcble-'));
  const cfgFile = path.join(tmpDir, 'config.json');
  fs.writeFileSync(cfgFile, JSON.stringify({
    authToken: TOKEN,
    port: PORT,
    host: '127.0.0.1',
    logLevel: 'info',
    pcBle: { enabled: true, scanTimeoutSec: 25, reconnectDelaySec: 5 },
  }), 'utf8');

  console.log('');
  console.log('  ══════════════════════════════════════════════════════');
  console.log('    PC 蓝牙桥 · 端到端验证');
  console.log('  ══════════════════════════════════════════════════════');
  console.log('  请确认：心率带已佩戴，手机 App 已停止');
  console.log('');

  const child = spawn(process.execPath, [path.join(ROOT, 'pc', 'src', 'index.js')], {
    cwd: ROOT,
    env: Object.assign({}, process.env, {
      HEALTHLINK_CONFIG: cfgFile,
      HEALTHLINK_PORT: String(PORT),
      HEALTHLINK_TOKEN: TOKEN,
      HEALTHLINK_HOST: '127.0.0.1',
      HEALTHLINK_PC_BLE: '1',
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let serverLog = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (d) => { serverLog += d; });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (d) => { serverLog += d; });

  // 等服务起来
  let up = false;
  for (let i = 0; i < 30; i++) {
    await sleep(500);
    const h = await api('/api/health');
    if (h.status === 200) { up = true; break; }
  }
  check('服务已启动', up, up ? `端口 ${PORT}` : '启动失败');

  if (!up) {
    child.kill();
    console.log(log.join('\n'));
    console.log('\n  服务端日志:\n' + serverLog.slice(0, 2000));
    process.exit(1);
  }

  // 等桥连上并产生样本
  let bridgeOk = false, deviceSeen = false, hrSeen = false, sampleSeen = false;
  let lastStatus = {};
  for (let i = 0; i < 60; i++) {          // 最多等 90 秒
    await sleep(1500);

    const st = await api('/api/pcble');
    if (st.json && st.json.data) {
      lastStatus = st.json.data;
      if (st.json.data.connected) bridgeOk = true;
    }

    const dev = await api('/api/devices');
    if (dev.json && Array.isArray(dev.json.data)) {
      const local = dev.json.data.find((d) => d.deviceId === 'pc-ble-local-hr-0001');
      if (local && local.online) deviceSeen = true;
    }

    if (bridgeOk) {
      // /api/latest 的结构是 data[deviceId][metric]（按设备分组）
      const latest = await api('/api/latest');
      if (latest.json && latest.json.data) {
        const devLatest = latest.json.data['pc-ble-local-hr-0001'];
        if (devLatest && devLatest.heart_rate) hrSeen = true;
      }

      // /api/samples 的结构是 data.samples[]（外面还包了一层）
      const samples = await api('/api/samples?limit=20');
      const list = samples.json && samples.json.data && samples.json.data.samples;
      if (Array.isArray(list)) {
        if (list.some((s) => s.payload && s.payload.source === 'pc-ble')) sampleSeen = true;
      }
    }

    if (hrSeen && sampleSeen) break;
  }

  console.log('  ⊙ 桥状态：', JSON.stringify({
    enabled: lastStatus.enabled,
    running: lastStatus.running,
    connected: lastStatus.connected,
    deviceName: lastStatus.deviceName,
    battery: lastStatus.battery,
    lastHr: lastStatus.lastHr,
    samplesSent: lastStatus.samplesSent,
  }));
  console.log('');

  check('桥已连接心率设备', bridgeOk, lastStatus.deviceName || '');
  check('设备列表里出现本机设备且在线', deviceSeen, 'pc-ble-local-hr-0001');
  check('/api/latest 能读到心率', hrSeen, hrSeen ? `当前 ${lastStatus.lastHr} bpm` : '');
  check('/api/samples 有 pc-ble 来源样本', sampleSeen, `已入库 ${lastStatus.samplesSent} 条`);

  child.kill();
  await sleep(800);
  try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}

  console.log(log.join('\n'));
  console.log(`\n  结果: ${pass} 通过 / ${fail} 失败`);
  if (fail > 0) {
    console.log('\n  服务端日志片段:\n' + serverLog.slice(-2500));
  }
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error('测试异常:', e);
  process.exit(2);
});
