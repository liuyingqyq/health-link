'use strict';
/**
 * HealthLink 服务端配置。
 *
 * 优先级（后者覆盖前者）：
 *   内置默认值  <  config.json  <  环境变量 HEALTHLINK_*  <  命令行参数
 *
 * 令牌策略：未配置 authToken 时自动生成一个随机令牌并落盘到 config.json，
 * 避免"忘记配令牌 = 完全不鉴权"这种最危险的默认值。
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DEFAULTS = {
  // '::' 在 Windows/Linux 上默认是 **dual-stack**：同时接受 IPv4 和 IPv6 连接。
  //
  // 为什么要用 '::' 而不是 '0.0.0.0'：
  //   '0.0.0.0' 只监听 IPv4。而在国内移动/联通/电信的家宽里，IPv4 普遍是
  //   运营商大内网（CGNAT，路由器 WAN 口拿到 10.x/100.64.x），**端口映射无效**；
  //   但运营商通常同时下发**公网 IPv6**（如 2409::/…），IPv6 没有 NAT，
  //   改成 '::' 之后外地的家人就能直连，不需要组网工具或中转服务器。
  //   实测：绑定 '::' 时 127.0.0.1 / 局域网 IPv4 / 公网 IPv6 全部可连，
  //   原有 IPv4 用法完全不受影响。
  //
  // 若某台机器上 '::' 不可用（极老系统或禁用了 IPv6），改回 '0.0.0.0' 即可。
  host: '::',
  // 默认用五位数端口：四位端口（如 8787）容易和本机其他开发工具撞车。
  // 想换端口有两种方式（优先级从高到低）：
  //   1) pc/config.json 里加 "port": 你的端口
  //   2) 设置环境变量 HEALTHLINK_PORT
  port: 18787,
  authToken: '',
  /**
   * PC 蓝牙桥：让电脑自己通过蓝牙连心率设备（不需要手机、不需要网络穿透）。
   * 默认关闭。开启方式：
   *   1) 这里写 { "enabled": true }
   *   2) 或设环境变量 HEALTHLINK_PC_BLE=1
   * 需要先编译 pc/ble/：双击 pc\ble\build-ble.ps1（要求 .NET SDK 8）
   * 详见 pc/ble/README.md
   */
  pcBle: {
    enabled: false,
    /** 设备名匹配串（如 "HW9"）；留空则取第一个广播标准心率服务 180D 的设备 */
    deviceName: '',
    /** 直接指定蓝牙地址（如 "AA:BB:CC:DD:EE:FF"），可跳过扫描，更快更稳 */
    address: '',
    scanTimeoutSec: 25,
    reconnectDelaySec: 5
  },
  /** 环形缓冲容量（条）。约每条 300 字节，20000 条约 6MB。 */
  bufferCapacity: 20000,
  /** 判定设备离线的时间阈值（毫秒） */
  offlineAfterMs: 120000,
  /** 面板默认采集周期下发值（毫秒） */
  defaultCollectIntervalMs: 60000,
  /** WebSocket 心跳周期（毫秒） */
  heartbeatMs: 30000,
  /** 单帧最大字节 */
  maxFrameBytes: 1024 * 1024,
  /** 重组后单条消息最大字节 */
  maxMessageBytes: 8 * 1024 * 1024,
  /** 单条 REST 查询返回上限 */
  maxQueryLimit: 1000,
  /** 转发目标持久化文件 */
  forwardStore: 'forwards.json',
  /** 是否把收到的样本追加写入 JSONL 归档（0 表示关闭） */
  archive: { enabled: false, file: 'archive/healthlink-YYYYMMDD.jsonl' },
  /** 日志级别：debug | info | warn | error */
  logLevel: 'info'
};

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

/**
 * 去掉 UTF-8 BOM。
 *
 * ⚠️ 踩过的坑：用 PowerShell 5.1 的 `Set-Content -Encoding UTF8` 或记事本"另存为 UTF-8"
 * 生成的 JSON 会带 BOM（EF BB BF），而 `JSON.parse` 不认 BOM，会抛
 * `Unexpected token '', "..." is not valid JSON`。
 * 用户手改一次配置就可能触发，这里统一容错，不让服务因此启动失败。
 */
function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readJsonIfExists(file) {
  try {
    if (!fs.existsSync(file)) return null;
    const raw = stripBom(fs.readFileSync(file, 'utf8'));
    if (!raw.trim()) return null;
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`配置文件解析失败 ${file}: ${err.message}`);
  }
}

/** 把 'a.b=1' 形式的 CLI 覆盖展开成嵌套对象 */
function applyCliOverrides(cfg, argv) {
  for (const arg of argv) {
    const m = /^--([A-Za-z0-9_.-]+)(?:=(.*))?$/.exec(arg);
    if (!m) continue;
    const keyPath = m[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    let value = m[2];
    if (value === undefined) value = 'true';
    if (value === 'true') value = true;
    else if (value === 'false') value = false;
    else if (/^-?\d+$/.test(value)) value = Number(value);
    const parts = keyPath.split('.');
    let cursor = cfg;
    for (let i = 0; i < parts.length - 1; i++) {
      if (typeof cursor[parts[i]] !== 'object' || cursor[parts[i]] === null) cursor[parts[i]] = {};
      cursor = cursor[parts[i]];
    }
    cursor[parts[parts.length - 1]] = value;
  }
  return cfg;
}

function applyEnvOverrides(cfg) {
  const map = {
    HEALTHLINK_HOST: 'host',
    HEALTHLINK_PORT: 'port',
    HEALTHLINK_TOKEN: 'authToken',
    HEALTHLINK_BUFFER_CAPACITY: 'bufferCapacity',
    HEALTHLINK_OFFLINE_AFTER_MS: 'offlineAfterMs',
    HEALTHLINK_HEARTBEAT_MS: 'heartbeatMs',
    HEALTHLINK_LOG_LEVEL: 'logLevel',
    HEALTHLINK_ARCHIVE: 'archive.enabled'
  };
  for (const [envKey, cfgPath] of Object.entries(map)) {
    const raw = process.env[envKey];
    if (raw === undefined || raw === '') continue;
    let value = raw;
    if (raw === 'true') value = true;
    else if (raw === 'false') value = false;
    else if (/^\d+$/.test(raw)) value = Number(raw);
    const parts = cfgPath.split('.');
    let cursor = cfg;
    for (let i = 0; i < parts.length - 1; i++) {
      if (typeof cursor[parts[i]] !== 'object' || cursor[parts[i]] === null) cursor[parts[i]] = {};
      cursor = cursor[parts[i]];
    }
    cursor[parts[parts.length - 1]] = value;
  }
  return cfg;
}

/**
 * 载入配置。
 * @param {object} options
 * @param {string} options.configFile config.json 路径
 * @param {string[]} options.argv 命令行参数（不含 node 与脚本名）
 * @param {boolean} options.persistGeneratedToken 生成令牌时是否写回 config.json
 */
function loadConfig(options = {}) {
  const configFile = options.configFile || path.join(__dirname, '..', 'config.json');
  const fileCfg = readJsonIfExists(configFile) || {};

  let cfg = { ...DEFAULTS, ...fileCfg };
  // 嵌套对象必须深合并一次：否则用户在 config.json 里只写
  //   "archive": { "enabled": true }
  // 会把 file、bufferCapacity 之类的默认值一起丢掉（pcBle 同理）。
  // 踩过的坑：浅合并是 JS 展开运算的默认行为，很容易忘。
  cfg.archive = { ...DEFAULTS.archive, ...(fileCfg.archive || {}) };
  cfg.pcBle = { ...DEFAULTS.pcBle, ...(fileCfg.pcBle || {}) };

  cfg = applyEnvOverrides(cfg);
  cfg = applyCliOverrides(cfg, options.argv || []);

  cfg.port = Number(cfg.port);
  // port=0 是合法的：让操作系统分配一个空闲端口（自动化测试用）
  if (!Number.isInteger(cfg.port) || cfg.port < 0 || cfg.port > 65535) {
    throw new Error(`端口不合法: ${cfg.port}`);
  }
  cfg.bufferCapacity = Math.max(100, Number(cfg.bufferCapacity) || DEFAULTS.bufferCapacity);

  cfg.tokenGenerated = false;
  if (!cfg.authToken || typeof cfg.authToken !== 'string' || cfg.authToken.length < 8) {
    cfg.authToken = generateToken();
    cfg.tokenGenerated = true;
    if (options.persistGeneratedToken !== false) {
      try {
        const existing = readJsonIfExists(configFile) || {};
        existing.authToken = cfg.authToken;
        fs.writeFileSync(configFile, JSON.stringify(existing, null, 2) + '\n', 'utf8');
      } catch (err) {
        // 写不进去不是致命错误：令牌仍在本进程内有效，只是重启会变
        process.stderr.write(`[warn] 无法把自动生成的令牌写回 ${configFile}: ${err.message}\n`);
      }
    }
  }

  cfg.configFile = configFile;
  cfg.forwardStorePath = path.isAbsolute(cfg.forwardStore)
    ? cfg.forwardStore
    : path.join(path.dirname(configFile), cfg.forwardStore);
  return cfg;
}

module.exports = { loadConfig, DEFAULTS, generateToken, stripBom };
