// 网络环境诊断：判断你有没有公网 IP、能不能做端口映射
// 结论会直接告诉你该走哪条路
const os = require('os');
const dns = require('dns').promises;
const http = require('http');
const net = require('net');
const dgram = require('dgram');

function line(c) { console.log('  ' + '─'.repeat(58)); }
function head(t) { console.log(''); console.log('  ' + t); line(); }

function getPublicIp(host, path, timeout = 6000) {
  return new Promise((resolve) => {
    const req = http.get({ host, path, timeout }, (res) => {
      let b = '';
      res.on('data', (d) => (b += d));
      res.on('end', () => resolve(b.trim()));
    });
    req.on('error', (e) => resolve('ERR:' + e.code));
    req.on('timeout', () => { req.destroy(); resolve('TIMEOUT'); });
  });
}

function tcpTest(host, port, ms = 3000) {
  return new Promise((resolve) => {
    const s = net.connect({ host, port });
    let done = false;
    const fin = (ok, extra) => {
      if (done) return;
      done = true;
      try { s.destroy(); } catch (e) {}
      resolve({ ok, extra });
    };
    s.setTimeout(ms);
    s.on('connect', () => fin(true, ''));
    s.on('timeout', () => fin(false, 'timeout'));
    s.on('error', (e) => fin(false, e.code));
  });
}

// UPnP/SSDP 探测：很多路由器支持，可自动映射端口
function ssdpProbe(timeout = 4000) {
  return new Promise((resolve) => {
    const s = dgram.createSocket('udp4');
    let found = [];
    let done = false;
    const fin = () => {
      if (done) return;
      done = true;
      try { s.close(); } catch (e) {}
      resolve(found);
    };
    s.on('message', (msg) => {
      const text = msg.toString('utf8');
      if (text.includes('InternetGatewayDevice') || text.includes('WANIPConnection')) {
        const m = text.match(/LOCATION:\s*(\S+)/i);
        if (m) found.push(m[1]);
        else found.push('(IGD 有响应)');
      }
    });
    s.on('error', () => fin());
    const msearch = Buffer.from(
      'M-SEARCH * HTTP/1.1\r\n' +
      'HOST: 239.255.255.250:1900\r\n' +
      'MAN: "ssdp:discover"\r\n' +
      'MX: 2\r\n' +
      'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n' +
      '\r\n'
    );
    try {
      s.send(msearch, 1900, '239.255.255.250', (err) => { if (err) fin(); });
    } catch (e) { fin(); }
    setTimeout(fin, timeout);
  });
}

(async () => {
  console.log('');
  console.log('  ══════════════════════════════════════════════════════');
  console.log('     HealthLink 网络环境诊断');
  console.log('  ══════════════════════════════════════════════════════');

  // ---- 1) 本机网卡 ----
  head('1) 本机地址');
  const locals = [];
  for (const [name, infos] of Object.entries(os.networkInterfaces())) {
    for (const i of infos || []) {
      if (i.family !== 'IPv4' || i.internal) continue;
      locals.push({ ip: i.address, name });
      console.log(`     ${i.address.padEnd(18)} ${name}`);
    }
  }

  // ---- 2) 公网出口 ----
  head('2) 公网出口 IP（真实对外地址）');
  const pub = await getPublicIp('myip.ipip.net', '/');
  console.log('     ' + pub);
  const ipMatch = pub.match(/(\d+\.\d+\.\d+\.\d+)/);
  const pubIp = ipMatch ? ipMatch[1] : '';

  let verdict = '未知';
  let advice = '';
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(pubIp)) {
    verdict = '运营商大内网（CGNAT）';
    advice = '❌ 没有公网 IP → 端口映射无效，必须走组网工具或公网服务器中转';
  } else if (/^10\./.test(pubIp) || /^172\.(1[6-9]|2\d|3[01])\./.test(pubIp) || /^192\.168\./.test(pubIp)) {
    verdict = '私网地址（多层 NAT）';
    advice = '❌ 你在多层 NAT 里 → 端口映射无效';
  } else if (pubIp) {
    verdict = '看起来是公网地址';
    advice = '✅ 有机会做端口映射！下一步要确认光猫/路由器的 WAN 口是不是同一个 IP';
  }
  console.log('');
  console.log(`     判定：${verdict}`);
  console.log(`     ${advice}`);

  // ---- 3) 本机 vs 公网 是否同段 ----
  head('3) 关键判断：出口 IP 与内网是否同段');
  console.log(`     内网 IP ： ${locals.map((l) => l.ip).join(', ')}`);
  console.log(`     出口 IP ： ${pubIp || '(取不到)'}`);
  if (pubIp && !locals.some((l) => l.ip === pubIp)) {
    console.log('     → 出口 IP 与内网不同，说明中间有 NAT 设备（正常）');
  }

  // ---- 4) 路由器后台 ----
  head('4) 找路由器管理界面（去这里看 WAN 口 IP）');
  const gateways = new Set();
  // 用默认网关：从路由表推断（常见 192.168.8.1 / .0.1 / .1.1）
  const seg = locals.find((l) => /^192\.168\./.test(l.ip));
  if (seg) {
    const base = seg.ip.split('.').slice(0, 3).join('.');
    for (const last of ['1', '0.1', '1.1']) gateways.add(base + '.' + last);
  }
  for (const gw of gateways) {
    const r = await tcpTest(gw, 80, 1500);
    const r2 = await tcpTest(gw, 443, 1500);
    if (r.ok || r2.ok) {
      console.log(`     ✅ http://${gw}  (管理界面可达)`);
    }
  }
  if (gateways.size === 0) console.log('     （没找到局域网网关，请手动看路由器背面标签）');

  // ---- 5) UPnP ----
  head('5) 路由器是否支持 UPnP（能自动映射端口）');
  const igd = await ssdpProbe(4000);
  if (igd.length > 0) {
    console.log('     ✅ 路由器支持 UPnP/IGD，可以自动映射端口');
    igd.slice(0, 2).forEach((u) => console.log('        ' + u));
  } else {
    console.log('     ❌ 没探到 UPnP（可能没开，或路由器不支持）');
  }

  // ---- 6) 结论 ----
  head('结论与下一步');
  if (!pubIp) {
    console.log('     取不到公网 IP。请手动在浏览器打开 http://myip.ipip.net 看一眼。');
  } else if (/^100\.|^10\.|^172\.(1[6-9]|2\d|3[01])\.|^192\.168\./.test(pubIp)) {
    console.log('     你没有公网 IP，两条路：');
    console.log('       A. 组网工具（Tailscale / 蒲公英）—— 双方各装一次');
    console.log('       B. 租一台公网服务器 + frp/rathole 中转');
  } else {
    console.log('     你可能有公网 IP，按顺序做：');
    console.log('       ① 浏览器打开上面那个管理界面，找「WAN 口状态 / 外网 IP」');
    console.log(`          看它是不是 ${pubIp}`);
    console.log('       ② 如果一致 → 做端口映射（外部端口 18787 → 你的电脑 18787）');
    console.log('       ③ 然后让外地家人访问 http://' + pubIp + ':18787/share.html?token=...');
    console.log('');
    console.log('     ⚠️ 安全提醒（重要）：');
    console.log('        映射成功后，你的健康数据就暴露在公网上了，任何人扫到端口都能试。');
    console.log('        · 建议用临时端口（如 48787），不用时立刻关掉映射');
    console.log('        · 看完就删映射，别长期开着');
    console.log('        · 或者改用组网工具，安全性更好');
  }

  console.log('');
  console.log('  ══════════════════════════════════════════════════════');
  console.log('');
})();
