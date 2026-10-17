#!/usr/bin/env node
'use strict';
/**
 * 樱花穿透地址生成器
 * ==================
 *
 * 解决的问题：**樱花那条 https 链接没有任何地方会打印，一直是手工拼的。**
 *   端口（如 27930）只有樱花启动器自己知道；
 *   而 启动.cmd 只能看到本机网卡，拼不出公网地址。
 *
 * 这个工具把两头接起来 —— 从樱花客户端日志里读出「节点域名:远程端口」，
 * 从 pc\config.json 读出令牌和本地端口，拼成三条可直接复制的地址：
 *
 *   1. 对方用浏览器看数据   https://域名:端口/share.html?token=…
 *   2. 你自己看完整面板     https://域名:端口/?token=…
 *   3. 手机在外地传数据     wss://域名:端口/ingest?token=…   ← 必须 wss，不能用 ws
 *
 * 用法：
 *   node tools\sakura-url.js            # 生成三条地址
 *   node tools\sakura-url.js --check    # 生成并实测（自签证书自动跳过校验）
 *   node tools\sakura-url.js --host frp-xxx.com --port 27930   # 手动指定，不读日志
 *
 * 零依赖：只用 Node 内置模块。
 */

const fs = require('fs');
const path = require('path');
const https = require('https');

const ROOT = path.resolve(__dirname, '..');
const DEFAULT_LOG_DIR = 'C:\\ProgramData\\SakuraFrpService\\Logs';

function parseArgs(argv) {
  const out = { check: false, host: '', port: '', logDir: process.env.SAKURA_LOG_DIR || DEFAULT_LOG_DIR, config: '' };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    const eq = arg.indexOf('=');
    const key = arg.slice(0, eq >= 0 ? eq : arg.length);
    const val = eq >= 0 ? arg.slice(eq + 1) : argv[++i];
    switch (key) {
      case '--check': out.check = true; break;
      case '--host': out.host = val || ''; break;
      case '--port': out.port = val || ''; break;
      case '--log-dir': out.logDir = val || out.logDir; break;
      case '--config': out.config = val || ''; break;
      default: break;
    }
  }
  return out;
}

/** 从樱花客户端日志里找出最后一次「使用 >>域名:端口<< 连接你的隧道」 */
function readTunnelFromLogs(logDir) {
  if (!fs.existsSync(logDir)) return { err: `日志目录不存在：${logDir}` };
  // 文件名形如 SakuraFrpService.20261017.log，按名字倒序即"最近的优先"
  const files = fs.readdirSync(logDir)
    .filter((f) => /^SakuraFrpService\.\d{8}\.log$/i.test(f))
    .sort()
    .reverse();
  if (files.length === 0) return { err: `日志目录里没有 SakuraFrpService.*.log` };

  // ⚠️ 这个正则需要 g 标志，否则 exec() 每次返回同一个匹配 → while 死循环
  const re = /使用\s*>>([A-Za-z0-9.-]+):(\d+)<</g;
  for (const f of files) {
    const full = path.join(logDir, f);
    const text = fs.readFileSync(full, 'utf8');
    let last = null;
    let m;
    re.lastIndex = 0;
    while ((m = re.exec(text)) !== null) last = { host: m[1], port: m[2], file: full };
    if (last) {
      // 顺便确认这次日志里隧道确实启动成功了
      const started = /隧道启动成功/.test(text);
      return { host: last.host, port: last.port, file: full, started };
    }
  }
  return { err: '日志里找不到「使用 >>域名:端口<< 连接你的隧道」。请先在樱花启动器里启动隧道。' };
}

function readServerConfig(configPath) {
  const p = configPath || path.join(ROOT, 'pc', 'config.json');
  if (!fs.existsSync(p)) return { err: `找不到配置文件：${p}` };
  let raw = fs.readFileSync(p, 'utf8');
  if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);   // 去掉 BOM
  try {
    const cfg = JSON.parse(raw);
    return { token: cfg.authToken || '', port: String(cfg.port || 18787), file: p };
  } catch (e) {
    return { err: `配置文件解析失败：${e.message}` };
  }
}

function req(url, { timeout = 15000 } = {}) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const r = https.get(url, {
      // 樱花用的是自签证书，必须跳过校验，否则一律报证书错误
      rejectUnauthorized: false,
      timeout,
      servername: new URL(url).hostname,
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => { body += d; });
      res.on('end', () => resolve({ status: res.statusCode, body, ms: Date.now() - t0 }));
    });
    r.on('timeout', () => { r.destroy(); resolve({ status: 0, body: '', ms: Date.now() - t0, error: 'timeout' }); });
    r.on('error', (e) => resolve({ status: 0, body: '', ms: Date.now() - t0, error: e.message }));
  });
}

(async () => {
  const args = parseArgs(process.argv);
  const cfg = readServerConfig(args.config);
  if (cfg.err) { console.error('  [×] ' + cfg.err); process.exit(1); }

  let host = args.host;
  let port = args.port;
  let source = '命令行参数';

  if (!host || !port) {
    const t = readTunnelFromLogs(args.logDir);
    if (t.err) {
      console.error('  [×] ' + t.err);
      console.error('');
      console.error('  手动指定也行：node tools\\sakura-url.js --host frp-xxx.com --port 27930');
      process.exit(1);
    }
    host = t.host;
    port = t.port;
    source = `樱花日志（${path.basename(t.file)}${t.started ? '，隧道启动成功' : ''}）`;
    if (!t.started) console.error('  [!] 这份日志里没看到「隧道启动成功」，端口可能是旧的');
  }

  const base = `${host}:${port}`;
  const tokQ = `token=${encodeURIComponent(cfg.token)}`;

  console.log('');
  console.log('  ════════════════════════════════════════════════════════════');
  console.log('    樱花穿透 · 地址一览');
  console.log('  ════════════════════════════════════════════════════════════');
  console.log(`  公网入口    ${base}    ← 来源：${source}`);
  console.log(`  令牌        ${cfg.token ? cfg.token.slice(0, 6) + '…' + cfg.token.slice(-4) : '(未配置)'}    ← 来源：${path.basename(cfg.file)}`);
  console.log(`  本地端口    ${cfg.port}`);
  console.log('');
  console.log('  ── 三条地址 ────────────────────────────────────────────────');
  console.log('');
  console.log('  ① 对方用浏览器看数据（只读分享页）');
  console.log(`     https://${base}/share.html?${tokQ}`);
  console.log('');
  console.log('  ② 你自己看完整面板');
  console.log(`     https://${base}/?${tokQ}`);
  console.log('');
  console.log('  ③ 手机在外地（走流量）传数据 → 填 App 的「电脑地址」');
  console.log(`     wss://${base}/ingest?${tokQ}`);
  console.log('     ⚠️ 必须 wss，填 ws:// 连不上（国内节点拦明文）');
  console.log('');
  console.log(`  手机同一 WiFi 时改用：ws://<本机IP>:${cfg.port}/ingest?${tokQ}`);
  console.log('');

  if (!args.check) {
    console.log('  想实测一遍通不通，加 --check：node tools\\sakura-url.js --check');
    console.log('');
    return;
  }

  console.log('  ── 实测 ────────────────────────────────────────────────────');
  const h = await req(`https://${base}/api/health`);
  if (h.status === 200) console.log(`  [√] /api/health        HTTP 200  ${h.ms} ms  ${h.body.slice(0, 80)}`);
  else console.log(`  [×] /api/health        HTTP ${h.status || '-'}  ${h.error || ''}  ${h.body.slice(0, 120)}`);

  const s = await req(`https://${base}/share.html?${tokQ}`);
  const m = /<title>(.*?)<\/title>/i.exec(s.body || '');
  // 用字节数，不然中文页面显示的是"字符数"，和 curl/浏览器对不上
  const bytes = Buffer.byteLength(s.body || '', 'utf8');
  if (s.status === 200) console.log(`  [√] /share.html        HTTP 200  ${bytes} 字节  标题「${m ? m[1] : '?'}」`);
  else console.log(`  [×] /share.html        HTTP ${s.status || '-'}  ${s.error || ''}`);

  const l = await req(`https://${base}/api/latest?${tokQ}`);
  if (l.status === 200) {
    let hr = '-';
    try {
      const j = JSON.parse(l.body);
      const devs = (j.data && Object.values(j.data)) || [];
      for (const d of devs) if (d && d.heart_rate) hr = `${d.heart_rate.value} bpm`;
    } catch (e) { /* 忽略 */ }
    console.log(`  [√] /api/latest        HTTP 200  当前心率 ${hr}`);
  } else {
    console.log(`  [×] /api/latest        HTTP ${l.status || '-'}  ${l.error || ''}`);
  }
  console.log('');
  console.log('  提示：如果 http:// 访问返回 501，说明国内节点正常拦明文，不代表出错 —— 用 https。');
  console.log('');
})();
