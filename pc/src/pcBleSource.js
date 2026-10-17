'use strict';
/**
 * PC 蓝牙桥数据源
 *
 * 作用：在电脑端直接通过蓝牙连心率设备（如 CooSpo HW9），把心率接进服务端。
 * 这样就不需要手机参与，也不需要网络穿透 —— 整条链路只有一段蓝牙。
 *
 * 实现方式：
 *   派生 pc/ble/ 编译出的 HealthLinkBle.exe 作为子进程，
 *   逐行读取它 stdout 上的 JSON，转成 HealthLink 的 sample 注入 hub。
 *
 *   复用 hub.registerLocalDevice / ingestLocalSample ——
 *   所以"本机蓝牙设备"在设备列表、面板、订阅者推送、转发目标里
 *   和手机上报的设备完全一致，不需要任何特殊处理。
 *
 * 启用方式（默认关闭，避免没编译 exe 时反复报错）：
 *   · 环境变量：HEALTHLINK_PC_BLE=1
 *   · 或 config.json 里加 "pcBle": { "enabled": true }
 *
 * 可选配置：
 *   "pcBle": {
 *     "enabled": true,
 *     "deviceName": "HW9",          // 设备名匹配串，留空则取第一个广播 180D 的
 *     "address": "AA:BB:CC:DD:EE:FF", // 直接指定蓝牙地址，跳过扫描（更稳）
 *     "scanTimeoutSec": 25,
 *     "reconnectDelaySec": 5,
 *     "exePath": "pc\\ble\\bin\\...\\HealthLinkBle.exe"  // 一般不用写
 *   }
 */

const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

const TAG = 'pcBle';

/** 本机蓝牙设备的固定 deviceId —— 固定值才能让"重启后仍是同一台设备" */
const LOCAL_DEVICE_ID = 'pc-ble-local-hr-0001';
/** RR 间期换算：蓝牙规范里单位是 1/1024 秒 */
const RR_UNIT_SECONDS = 1024;
/** 心率节流：设备可能每秒推多次，最多每 1 秒入库一条 */
const MIN_SAMPLE_INTERVAL_MS = 1000;
/** 电量上报节流：不要每次变 1% 都发 */
const BATTERY_INTERVAL_MS = 60000;

class PcBleSource {
  /**
   * @param {object} options
   * @param {object} options.hub     HealthLink 的 Hub 实例
   * @param {object} options.config  服务端配置
   * @param {object} options.logger  日志器（需有 info/warn/error）
   */
  constructor(options = {}) {
    this.hub = options.hub;
    this.config = options.config || {};
    this.log = options.logger || console;

    const cfg = (this.config && this.config.pcBle) || {};
    this.cfg = Object.assign(
      {
        enabled: false,
        deviceName: '',
        address: '',
        scanTimeoutSec: 25,
        reconnectDelaySec: 5,
      },
      cfg
    );
    // 环境变量优先（方便临时开）
    if (String(process.env.HEALTHLINK_PC_BLE || '') === '1') this.cfg.enabled = true;
    if (process.env.HEALTHLINK_PC_BLE_NAME) this.cfg.deviceName = process.env.HEALTHLINK_PC_BLE_NAME;
    if (process.env.HEALTHLINK_PC_BLE_ADDRESS) this.cfg.address = process.env.HEALTHLINK_PC_BLE_ADDRESS;

    this.child = null;
    this.buf = '';
    this.stopping = false;
    this.restartTimer = null;
    this.restartDelayMs = 2000;

    // 运行状态（供面板/日志观察）
    this.state = {
      enabled: !!this.cfg.enabled,
      running: false,
      connected: false,
      deviceName: '',
      deviceAddress: '',
      battery: null,
      lastHr: null,
      lastHrAt: 0,
      samplesSent: 0,
      restarts: 0,
      lastError: '',
    };

    this._lastSampleAt = 0;
    this._lastBatteryAt = 0;
    this._lastBatteryPct = null;
    this._seq = 0;
    this._lastErrMsg = '';
    this._lastErrAt = 0;
  }

  /** 解析 exe 路径：优先配置，其次按编译产物常见位置找 */
  resolveExe() {
    if (this.cfg.exePath) {
      const p = path.isAbsolute(this.cfg.exePath)
        ? this.cfg.exePath
        : path.join(__dirname, '..', '..', this.cfg.exePath);
      return fs.existsSync(p) ? p : null;
    }
    const candidates = [
      path.join(__dirname, '..', 'ble', 'bin', 'Release', 'net8.0-windows10.0.19041.0', 'win-x64', 'HealthLinkBle.exe'),
      path.join(__dirname, '..', 'ble', 'bin', 'Debug', 'net8.0-windows10.0.19041.0', 'win-x64', 'HealthLinkBle.exe'),
    ];
    for (const c of candidates) {
      if (fs.existsSync(c)) return c;
    }
    return null;
  }

  start() {
    if (!this.cfg.enabled) {
      this.log.info(`[${TAG}] 未启用（要开启：设 HEALTHLINK_PC_BLE=1，或在 config.json 里加 pcBle.enabled=true）`);
      return;
    }
    if (this.child) return;

    const exe = this.resolveExe();
    if (!exe) {
      this.state.lastError = '找不到 HealthLinkBle.exe';
      this.log.warn(`[${TAG}] 找不到 HealthLinkBle.exe，PC 蓝牙桥无法启动`);
      this.log.warn(`[${TAG}] 请先编译： .\\pc\\ble\\build-ble.ps1  （需要 .NET SDK 8）`);
      return;
    }

    const args = ['--verbose'];
    if (this.cfg.address) args.push('--address', String(this.cfg.address));
    else if (this.cfg.deviceName) args.push('--name', String(this.cfg.deviceName));
    args.push('--scan-timeout', String(this.cfg.scanTimeoutSec || 25));
    args.push('--reconnect-delay', String(this.cfg.reconnectDelaySec || 5));

    this.log.info(`[${TAG}] 启动 PC 蓝牙桥：${path.basename(exe)} ${args.join(' ')}`);

    let child;
    try {
      child = spawn(exe, args, {
        cwd: path.dirname(exe),
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
      });
    } catch (err) {
      this.state.lastError = err.message;
      this.log.error(`[${TAG}] 启动失败：${err.message}`);
      this._scheduleRestart();
      return;
    }

    this.child = child;
    this.buf = '';
    this.state.running = true;
    this.state.lastError = '';

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => this._onData(chunk));

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      const s = String(chunk).trim();
      if (s) this.log.warn(`[${TAG}] 子进程 stderr: ${s}`);
    });

    child.on('error', (err) => {
      this.state.lastError = err.message;
      this.log.error(`[${TAG}] 子进程错误：${err.message}`);
    });

    child.on('exit', (code, signal) => {
      const wasConnected = this.state.connected;
      this.state.running = false;
      this.state.connected = false;
      this.child = null;
      if (wasConnected) {
        this.hub.unregisterLocalDevice(LOCAL_DEVICE_ID, `桥进程退出(code=${code})`);
      }
      if (this.stopping) return;
      this.log.warn(`[${TAG}] 桥进程退出 code=${code} signal=${signal || '-'}，准备重启`);
      this._scheduleRestart();
    });
  }

  stop() {
    this.stopping = true;
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    const child = this.child;
    this.child = null;
    if (child) {
      try { child.kill(); } catch (e) { /* 忽略 */ }
    }
    if (this.state.connected) {
      this.hub.unregisterLocalDevice(LOCAL_DEVICE_ID, '服务停止');
      this.state.connected = false;
    }
    this.state.running = false;
  }

  getStatus() {
    return Object.assign({}, this.state, { deviceId: LOCAL_DEVICE_ID });
  }

  // ---------------------------------------------------------------- 内部

  _scheduleRestart() {
    if (this.stopping) return;
    if (this.restartTimer) return;
    this.state.restarts++;
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start();
    }, this.restartDelayMs);
    // 退避，避免反复失败时刷屏
    this.restartDelayMs = Math.min(this.restartDelayMs * 2, 30000);
  }

  /** 处理子进程 stdout：按行切分 JSON */
  _onData(chunk) {
    this.buf += chunk;
    let idx;
    while ((idx = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, idx).trim();
      this.buf = this.buf.slice(idx + 1);
      if (!line) continue;
      let obj;
      try { obj = JSON.parse(line); } catch (e) { continue; }
      try { this._handle(obj); } catch (e) {
        this.log.warn(`[${TAG}] 处理桥消息异常：${e.message}`);
      }
    }
    // 防止异常长的行把内存撑爆
    if (this.buf.length > 64 * 1024) this.buf = '';
  }

  _handle(msg) {
    switch (msg.t) {
      case 'ready':
        this.log.info(`[${TAG}] 桥已就绪，开始扫描蓝牙设备…`);
        break;

      case 'scan':
        this.restartDelayMs = 2000;   // 扫描成功就重置退避
        break;

      case 'found':
        this.log.info(`[${TAG}] 发现设备 ${msg.name || '(无名)'} [${msg.id}]`);
        break;

      case 'connecting':
        this.log.info(`[${TAG}] 正在连接 [${msg.id}]…`);
        break;

      case 'connected': {
        this.state.connected = true;
        this.state.deviceName = msg.name || '';
        this.state.deviceAddress = msg.id || '';
        this.restartDelayMs = 2000;
        // 连上了就把上一次的错误清掉 —— 否则 lastError 会一直挂着旧故障，
        // 面板上看起来像"明明连着却还在报错"。
        this.state.lastError = '';
        this._lastErrMsg = '';
        this._lastErrAt = 0;
        // 注册成本机设备 —— 之后面板/订阅者/转发都能看到它
        this.hub.registerLocalDevice(LOCAL_DEVICE_ID, {
          model: `电脑蓝牙直连 · ${msg.name || msg.id}`,
          localKind: 'pc-ble',
          appVersion: 'pc-ble-bridge',
        });
        this.log.info(`[${TAG}] 已连接 ${msg.name || msg.id}，心率开始进入管线`);
        break;
      }

      case 'hr':
        this._onHeartRate(msg);
        break;

      case 'battery':
        this._onBattery(msg);
        break;

      case 'disconnected':
        this.state.connected = false;
        this.hub.unregisterLocalDevice(LOCAL_DEVICE_ID, msg.reason || '设备断开');
        this.log.warn(`[${TAG}] 设备断开：${msg.reason || '未知'}，等待重连`);
        break;

      case 'error': {
        this.state.lastError = msg.msg || '';
        // 同一条错误在短时间内重复出现就不重复打日志：
        // 蓝牙重连是每 5～60 秒一轮，同一条 warn 刷满控制台会把有用信息全挤掉。
        // 静默 30 秒后允许再打一次，避免"问题一直存在却完全看不见"。
        const now = Date.now();
        const same = msg.msg && msg.msg === this._lastErrMsg && now - this._lastErrAt < 30000;
        if (!same) {
          this._lastErrMsg = msg.msg || '';
          this._lastErrAt = now;
          this.log.warn(`[${TAG}] ${msg.msg}`);
        }
        break;
      }

      case 'log':
        // 子进程的调试信息：只在需要时打出来，避免刷屏
        if (String(process.env.HEALTHLINK_PC_BLE_VERBOSE || '') === '1') {
          this.log.info(`[${TAG}] ${msg.msg}`);
        }
        break;

      default:
        break;
    }
  }

  _onHeartRate(msg) {
    const bpm = Number(msg.bpm);
    if (!Number.isFinite(bpm) || bpm <= 0 || bpm > 300) return;

    this.state.lastHr = bpm;
    this.state.lastHrAt = Date.now();

    // 节流：设备可能每秒推多次，避免把缓冲塞爆
    const now = Date.now();
    if (now - this._lastSampleAt < MIN_SAMPLE_INTERVAL_MS) return;
    this._lastSampleAt = now;

    this._seq++;
    const res = this.hub.ingestLocalSample(
      LOCAL_DEVICE_ID,
      {
        metric: 'heart_rate',
        value: bpm,
        unit: 'bpm',
        startTime: now - 1000,
        endTime: now,
        source: 'pc-ble',
      },
      this._seq
    );
    if (res && res.ok) {
      this.state.samplesSent++;
    } else if (res && res.error !== 'no_device') {
      this.log.warn(`[${TAG}] 心率入库被拒：${res.message || res.error}`);
    }

    // 顺带从 RR 间期算 HRV（RMSSD）—— 没有 RR 就不报，不瞎编
    this._maybeEmitHrv(msg.rr, now);
  }

  /**
   * 用 RR 间期算 HRV（RMSSD）。
   *
   * RR 单位是 1/1024 秒；RMSSD = sqrt(mean(相邻 RR 差的平方))，单位毫秒。
   * 为什么值得算：心率带免费提供了 RR 间期，而 RMSSD 是标准的短时 HRV 指标，
   * 服务端的 KNOWN_METRICS 白名单里也有 hrv —— 不报白不报。
   * 至少要有 4 个 RR 才有统计意义（否则差值样本太少）。
   */
  _maybeEmitHrv(rr, now) {
    if (!Array.isArray(rr) || rr.length < 4) return;
    const ms = rr.map((v) => Number(v) / RR_UNIT_SECONDS * 1000).filter((v) => Number.isFinite(v) && v > 200 && v < 3000);
    if (ms.length < 4) return;

    let sumSq = 0;
    let n = 0;
    for (let i = 1; i < ms.length; i++) {
      const d = ms[i] - ms[i - 1];
      sumSq += d * d;
      n++;
    }
    if (n === 0) return;
    const rmssd = Math.sqrt(sumSq / n);
    if (!Number.isFinite(rmssd) || rmssd <= 0 || rmssd > 500) return;

    this._seq++;
    this.hub.ingestLocalSample(
      LOCAL_DEVICE_ID,
      {
        metric: 'hrv',
        value: Math.round(rmssd),
        unit: 'ms',
        startTime: now - 1000,
        endTime: now,
        source: 'pc-ble',
      },
      this._seq
    );
  }

  _onBattery(msg) {
    const pct = Number(msg.percent);
    if (!Number.isFinite(pct)) return;
    this.state.battery = pct;

    const now = Date.now();
    if (this._lastBatteryPct !== null &&
        Math.abs(pct - this._lastBatteryPct) < 5 &&
        now - this._lastBatteryAt < BATTERY_INTERVAL_MS) {
      return;
    }
    this._lastBatteryPct = pct;
    this._lastBatteryAt = now;
    // 电量不是健康指标，不进样本缓冲（KNOWN_METRICS 里没有它），
    // 只放在设备展示信息里 —— 这里仅记录状态，由 getStatus() 暴露。
    this.log.info(`[${TAG}] 心率带电量 ${pct}%`);
  }
}

module.exports = { PcBleSource, LOCAL_DEVICE_ID };
