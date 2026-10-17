#!/usr/bin/env node
'use strict';
/**
 * HealthLink 电脑端启动入口。
 *
 * 用法：
 *   node pc/src/index.js
 *   node pc/src/index.js --port=18787 --log-level=debug
 *   HEALTHLINK_TOKEN=mytoken node pc/src/index.js
 *
 * 它会一直跑（"长加载"），断线不退出：手机掉线、转发目标掉线都只是状态变化。
 * Ctrl+C 才退出，退出时会把转发目标的队列状态保留在内存里（进程结束即丢失），
 * 但配置落盘在 forwards.json。
 */

const os = require('os');
const path = require('path');
const { loadConfig } = require('./config');
const { createConsoleLogger } = require('./hub');
const { HealthLinkServer } = require('./server');

/**
 * 列出本机可用于「手机连过来」的 IPv4。
 *
 * 过滤规则（踩过坑：不过滤会把 198.18.x.x 网络测试保留段和 169.254.x.x
 * 链路本地地址也列出来，用户照抄会连不上）：
 *   - 只保留 Up 且非回环的网卡
 *   - 排除 169.254.0.0/16（没拿到 DHCP 时的自分配地址）
 *   - 排除 127.0.0.0/8 与 198.18.0.0/15（基准测试保留段）
 * 局域网地址（192.168/10/172.16-31）排在前面。
 */
/**
 * 列出本机可用于「手机连过来」的地址。
 *
 * 分三组返回，因为三组的用途完全不同：
 *   lan  —— 局域网 IPv4（192.168.x / 10.x / 172.16-31.x）：同一个 WiFi 用
 *   v6   —— **公网 IPv6**（如 2409:…）：跨网络直连用，不需要组网工具
 *   other —— 其他 IPv4（虚拟网卡等）：兜底
 *
 * 过滤规则（踩过坑：不过滤会把连不上的地址也列出来，用户照抄就失败）：
 *   - 排除 169.254.x.x（没拿到 DHCP 时的自分配地址）
 *   - 排除 127.x / 198.18-19.x（回环与基准测试保留段）
 *   - IPv6 排除 fe80::（链路本地，只在同一网段有效且需要 zone id）
 *            与 ::1、fd00::/fc00::（唯一本地地址 ULA，通常是内网自建）
 */
function listLocalIps() {
  const os = require('os');
  const lan = [];
  const v6 = [];
  const other = [];
  for (const infos of Object.values(os.networkInterfaces())) {
    for (const info of infos || []) {
      if (info.internal) continue;
      const ip = info.address;

      if (info.family === 'IPv6') {
        const bare = ip.split('%')[0];
        if (/^(fe80|::1)/i.test(bare)) continue;
        // 唯一本地地址 ULA（fc00::/7），不是公网，跳过
        if (/^f[cd]/i.test(bare)) continue;
        v6.push(bare);
        continue;
      }

      if (info.family !== 'IPv4') continue;
      if (/^169\.254\./.test(ip)) continue;
      if (/^(127\.|198\.18\.|198\.19\.)/.test(ip)) continue;
      if (/^(192\.168\.|10\.)/.test(ip) || /^172\.(1[6-9]|2[0-9]|3[01])\./.test(ip)) lan.push(ip);
      else other.push(ip);
    }
  }
  const unique = (arr) => Array.from(new Set(arr));
  return { lan: unique(lan), v6: unique(v6), other: unique(other) };
}

async function main() {
  const configFile = process.env.HEALTHLINK_CONFIG || path.join(__dirname, '..', 'config.json');
  const config = loadConfig({ configFile, argv: process.argv.slice(2) });
  const log = createConsoleLogger(config.logLevel);

  const server = new HealthLinkServer({ config, logger: log });
  await server.listen();
  const actualPort = server.server.address().port;

  const { lan, v6, other } = listLocalIps();
  log.info('把下面这行填进手机 App 的“电脑地址”里：');
  if (lan.length > 0) {
    for (const ip of lan) log.info(`    ws://${ip}:${actualPort}/ingest?token=${config.authToken}`);
  } else {
    log.warn('没找到典型的局域网地址（192.168.x.x / 10.x.x.x），请确认电脑已连上 WiFi 或网线。');
  }
  if (v6.length > 0) {
    log.info('');
    log.info('想让手机在外地（用流量）也能传数据，用下面这条 IPv6 地址：');
    log.info('  （IPv6 没有 NAT、跨网络可直达，不需要组网工具；方括号是 URL 规范要求，别删）');
    for (const ip of v6) log.info(`    ws://[${ip}]:${actualPort}/ingest?token=${config.authToken}`);
    log.info('  注意：IPv6 地址可能随路由器重新拨号而改变，长期使用建议配动态域名。');
    log.info('');
  }
  if (other.length > 0) {
    log.info('    若上面都不通，可再试这几条（可能是虚拟网卡）：');
    for (const ip of other) log.info(`    ws://${ip}:${actualPort}/ingest?token=${config.authToken}`);
  }
  log.info(`本机打开面板： http://127.0.0.1:${actualPort}/?token=${config.authToken}`);

  let shuttingDown = false;
  const shutdown = async (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info(`收到 ${signal}，正在关闭...`);
    const force = setTimeout(() => {
      log.warn('关闭超时，强制退出');
      process.exit(1);
    }, 5000);
    if (force.unref) force.unref();
    try {
      await server.close();
    } catch (err) {
      log.error(`关闭时出错: ${err.message}`);
    }
    clearTimeout(force);
    log.info('已停止。');
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('uncaughtException', (err) => {
    log.error(`未捕获异常（服务继续运行）: ${err.stack || err.message}`);
  });
  process.on('unhandledRejection', (reason) => {
    log.error(`未处理的 Promise 拒绝（服务继续运行）: ${reason}`);
  });
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`启动失败: ${err.stack || err.message}\n`);
    process.exit(1);
  });
}

module.exports = { main, listLocalIps };
