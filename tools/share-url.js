// 生成"给对方的网址"，并逐个实测你本机能不能访问（自测通过才说明地址有效）
const os = require('os');
const http = require('http');

function get(host, path, timeout = 4000) {
  return new Promise((resolve) => {
    const req = http.get({ host, port: 18787, path, timeout }, (res) => {
      let b = '';
      res.on('data', (d) => (b += d));
      res.on('end', () => resolve({ ok: res.statusCode === 200, code: res.statusCode, len: b.length }));
    });
    req.on('error', (e) => resolve({ ok: false, code: 0, err: e.code }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, code: 0, err: 'timeout' }); });
  });
}

(async () => {
  const fs = require('fs');
  const path = require('path');
  const cfgPath = path.join(__dirname, '..', 'pc', 'config.json');
  let token = '';
  try { token = JSON.parse(fs.readFileSync(cfgPath, 'utf8')).authToken; } catch (e) {}
  if (!token) { console.log('  取不到令牌，请先启动一次服务'); return; }

  console.log('');
  console.log('  ══════════════════════════════════════════════════════');
  console.log('    给对方的浏览器网址（并逐条实测本机可达性）');
  console.log('  ══════════════════════════════════════════════════════');

  // 收集地址
  const v4lan = [];
  const v6pub = [];
  for (const [name, infos] of Object.entries(os.networkInterfaces())) {
    for (const i of infos || []) {
      if (i.internal) continue;
      if (i.family === 'IPv4') {
        if (/^169\.254\./.test(i.address)) continue;
        if (/^(192\.168\.|10\.)/.test(i.address) || /^172\.(1[6-9]|2[0-9]|3[01])\./.test(i.address)) {
          v4lan.push({ ip: i.address, name });
        }
      } else if (i.family === 'IPv6') {
        const bare = i.address.split('%')[0];
        if (/^(fe80|::1)/i.test(bare) || /^f[cd]/i.test(bare)) continue;
        v6pub.push({ ip: bare, name });
      }
    }
  }

  // ---- 局域网 IPv4 ----
  console.log('');
  console.log('  【① 对方和你在同一个 Wi-Fi】');
  console.log('  ──────────────────────────────────────────────────────');
  let anySameWifi = false;
  for (const a of v4lan) {
    if (a.name.match(/VMware|VMnet|Virtual|Oray|Pgy/i)) continue;
    const url = `http://${a.ip}:18787/share.html?token=${token}`;
    const r = await get(a.ip, `/share.html?token=${token}`);
    console.log(`${r.ok ? '  ✅' : '  ❌'} ${url}`);
    console.log(`     （网卡 ${a.name}，本机自测${r.ok ? '通过' : '失败 ' + (r.err || r.code)}）`);
    if (r.ok) anySameWifi = true;
  }
  if (!anySameWifi) console.log('  ⚠️ 没有可用的局域网地址，或服务未运行');

  // ---- 公网 IPv6 ----
  console.log('');
  console.log('  【② 对方在外地（推荐，走 IPv6）】');
  console.log('  ──────────────────────────────────────────────────────');
  if (v6pub.length === 0) {
    console.log('  ⚠️ 没找到公网 IPv6');
  }
  for (const a of v6pub) {
    const url = `http://[${a.ip}]:18787/share.html?token=${token}`;
    const r = await get(a.ip, `/share.html?token=${token}`);
    console.log(`${r.ok ? '  ✅' : '  ❌'} ${url}`);
  }
  console.log('');
  console.log('  注意：IPv6 地址必须用方括号包起来，这是 URL 规范要求。');
  console.log('        上面有几条 IPv6 时，优先用带 /64 的那个（接口标识较短、更稳定）。');

  // ---- 面板地址（你自己看） ----
  console.log('');
  console.log('  【你自己在这台电脑上看（面板，功能更全）】');
  console.log(`      http://127.0.0.1:18787/?token=${token}`);
  console.log('');
  console.log('  ══════════════════════════════════════════════════════');
  console.log('');
})();
