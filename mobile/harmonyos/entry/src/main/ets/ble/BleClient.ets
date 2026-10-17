/**
 * BLE GATT 客户端 —— 直连蓝牙健康设备（手表/手环/心率带）读取数据。
 *
 * ## 为什么走这条路
 * 华为 Health Service Kit 需要企业资质 + 人工审核（高阶健康数据还要注册资本门槛），
 * 而 HarmonyOS **完整开放了 BLE GATT 客户端能力**，任何第三方应用都能作为
 * GATT Client 去读外设暴露的 Service / Characteristic。所需权限
 * `ohos.permission.ACCESS_BLUETOOTH` 是普通权限，**不需要任何华为审批**。
 *
 * ## 能力边界（必须清楚，否则会白忙）
 * 能不能读到数据，取决于**设备暴露了什么**：
 *   ✅ 支持蓝牙 SIG 标准心率服务（0x180D / 0x2A37）的设备 → 心率可实时订阅
 *      （常见于心率带、部分手环、部分运动表）
 *   ❌ 华为手表/手环的睡眠、血氧、HRV、压力 → 走的是厂商私有通道，
 *      GATT 读不到，只能通过 Health Service Kit 获取
 *
 * 所以本模块的策略是：**扫描 + 把设备真实暴露的服务/特征全部列出来**，
 * 认识的标准服务自动订阅，不认识的也如实展示，让用户能看到自己那块表到底有什么。
 *
 * ## API 依据（均对照本机 SDK 声明核实）
 *   - `ble.startBLEScan(filters, options)` / `ble.stopBLEScan()`
 *   - `ble.on('BLEDeviceFind', callback: Callback<Array<ScanResult>>)`  ← **模块级**事件
 *   - `ble.createGattClientDevice(deviceId)`
 *   - `GattClientDevice.connect()` / `getServices()` / `readCharacteristicValue()`
 *   - `GattClientDevice.setCharacteristicChangeNotification(c, enable)`
 *   - `GattClientDevice.on('BLECharacteristicChange', Callback<BLECharacteristic>)`
 *   - `GattClientDevice.on('BLEConnectionStateChange', Callback<BLEConnectionChangeState>)`
 *   - `access.getState()` 判断蓝牙是否打开
 */

import { ble } from '@kit.ConnectivityKit';
import { access } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';

const TAG = 'BleClient';

/**
 * 连接失败后的重试次数。
 * BLE 首次连接失败很常见（设备刚离开广播态、扫描刚停时射频切换、栈繁忙），
 * 官方错误码 `2900099` 就是这种通用失败，重试往往就成功。
 */
const CONNECT_MAX_ATTEMPTS = 2;

/** 两次连接尝试之间的等待（毫秒）。 */
const CONNECT_RETRY_DELAY_MS = 1200;

/**
 * 发起连接后等待 BLEConnectionStateChange 事件的超时（毫秒）。
 * `connect()` 是同步方法，成功与否靠事件通知；等不到就走超时分支。
 */
const CONNECT_TIMEOUT_MS = 12000;

/**
 * 自定义的"连接超时"错误码。
 * 负数不会与官方错误码（201/801/2900001/2900003/2900099 等）冲突，
 * 便于在提示里区分「发起连接就失败」与「发起成功但等不到已连接事件」。
 */
const E_CODE_TIMEOUT = -1;

/** 订阅成功后等多久没收到上报就改用轮询读（毫秒） */
const NOTIFY_FALLBACK_DELAY_MS = 3000;

/** 轮询读取的间隔（毫秒） */
const NOTIFY_POLL_INTERVAL_MS = 3000;

/**
 * 构造带错误码的 BusinessError。
 *
 * 为什么不用 `new Error(msg) as Error & { code: number }`：
 * ArkTS 严格模式**禁止交叉类型**（arkts-no-intersection-types）和
 * **对象字面量当类型**（arkts-no-obj-literals-as-types），那样写编译不过（10605019 / 10605040）。
 * `BusinessError` 本身就是官方提供的 `extends Error` 且带 `code: number` 的类型，直接用它最稳。
 */
function makeBusinessError(code: number, message: string): BusinessError {
  const e: BusinessError = { code, name: 'BusinessError', message };
  return e;
}

// ---------------------------------------------------------------- 已知服务/特征表

/**
 * 一个已知特征。
 * 为什么单独抽成接口：ArkTS 不允许对象字面量对应**匿名**类型
 * （arkts-no-untyped-obj-literals），必须用具名接口。
 */
export interface KnownCharacteristic {
  /** 短 UUID，大写，如 "2A37" */
  uuid: string;
  name: string;
  /** 是否可以通过订阅通知拿到值 */
  subscribable: boolean;
}

/**
 * 认识的标准 GATT 服务。
 * 注意：UUID 在 SDK 里以 **短格式**（"180D"）表示，不要在代码里写 128 位长格式。
 */
export interface KnownService {
  /** 短 UUID，大写，如 "180D" */
  uuid: string;
  name: string;
  /** 是否已标准化解析 */
  standard: boolean;
  /** 该服务下我们关心的特征（短 UUID 大写） */
  characteristics: KnownCharacteristic[];
}

export const KNOWN_SERVICES: KnownService[] = [
  {
    uuid: '180D',
    name: '心率服务 (Heart Rate)',
    standard: true,
    characteristics: [
      { uuid: '2A37', name: '心率测量', subscribable: true },
      { uuid: '2A38', name: '身体传感器位置', subscribable: false },
      { uuid: '2A39', name: '心率控制点', subscribable: false }
    ]
  },
  {
    uuid: '1822',
    name: '脉搏血氧服务 (Pulse Oximeter)',
    standard: true,
    characteristics: [
      { uuid: '2A5E', name: '血氧连续测量', subscribable: true },
      { uuid: '2A5F', name: '血氧单次测量', subscribable: false }
    ]
  },
  {
    uuid: '1810',
    name: '血压服务 (Blood Pressure)',
    standard: true,
    characteristics: [{ uuid: '2A35', name: '血压测量', subscribable: true }]
  },
  {
    uuid: '1809',
    name: '体温服务 (Health Thermometer)',
    standard: true,
    characteristics: [{ uuid: '2A1C', name: '温度测量', subscribable: true }]
  },
  {
    uuid: '180F',
    name: '电池服务 (Battery)',
    standard: true,
    characteristics: [{ uuid: '2A19', name: '电池电量', subscribable: true }]
  },
  {
    uuid: '180A',
    name: '设备信息 (Device Information)',
    standard: true,
    characteristics: [
      { uuid: '2A29', name: '厂商名称', subscribable: false },
      { uuid: '2A24', name: '型号', subscribable: false },
      { uuid: '2A25', name: '序列号', subscribable: false },
      { uuid: '2A26', name: '固件版本', subscribable: false },
      { uuid: '2A27', name: '硬件版本', subscribable: false },
      { uuid: '2A28', name: '软件版本', subscribable: false }
    ]
  },
  {
    uuid: '1800',
    name: '通用访问 (Generic Access)',
    standard: true,
    characteristics: [
      { uuid: '2A00', name: '设备名称', subscribable: false },
      { uuid: '2A01', name: '外观', subscribable: false }
    ]
  }
];

/** 把短 UUID 归一成大写，便于比较（SDK 返回值大小写不统一） */
export function normalizeUuid(uuid: string): string {
  if (!uuid) return '';
  return uuid.trim().toUpperCase();
}

/** 单次连接尝试的结果（内部用，避免直接抛异常破坏重试流程） */
interface ConnectAttempt {
  ok: boolean;
  code: number;
  message: string;
}

/** 连接失败后的等待时间（毫秒），给蓝牙栈和设备一点缓冲 */
function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}

/**
 * 从任意形式的 UUID 中提取**短码**（4 位十六进制，如 "180D"），用于和常量表比较。
 *
 * ⚠️ 为什么必须有这个函数：
 *   SDK 的 `GattService.serviceUuid` / `BLECharacteristic.characteristicUuid`
 *   官方返回的是 **128 位完整格式**（文档示例：`"00002a11-0000-1000-8000-00805f9b34fb"`），
 *   而本模块的 KNOWN_SERVICES / 解析逻辑用的是短码。
 *   若直接拿整串去比 `=== '180D'`，永远不相等 —— 表现为「连上了设备但读不到心率」。
 */
export function shortUuid(uuid: string): string {
  const u = normalizeUuid(uuid);
  if (u.length === 0) return '';
  const dash = u.indexOf('-');
  if (dash <= 0) return u;
  const head = u.substring(0, dash);
  // 去掉前导 0（0000180D → 180D）。不用正则，避免 ArkTS 上的兼容性问题。
  let i = 0;
  while (i < head.length - 1 && head.charAt(i) === '0') i++;
  return head.substring(i);
}

/**
 * 判断两个 UUID 是否指向同一个服务/特征（自动兼容短码与 128 位完整格式）。
 */
export function uuidEquals(a: string, b: string): boolean {
  const na = normalizeUuid(a);
  const nb = normalizeUuid(b);
  if (na === nb) return true;
  return shortUuid(na) === shortUuid(nb);
}

/**
 * 蓝牙 SIG 基础 UUID 后缀：128 位 = 短 UUID 左移补零 + 该后缀。
 * 2A37 → 00002a37-0000-1000-8000-00805f9b34fb
 */
const BLUETOOTH_BASE_UUID_SUFFIX = '-0000-1000-8000-00805F9B34FB';

/**
 * 把 4 位/8 位短 UUID 展开成 **128 位完整 UUID**。
 *
 * ⚠️ 为什么必须有这个函数：
 *   `ble.startBLEScan()` 的 `ScanFilter.serviceUuid` 官方要求 128 位完整格式
 *   （文档示例：`"00001888-0000-1000-8000-00805f9b34fb"`）。
 *   若传短格式 `"180D"`，参数校验会失败并抛 **401 Invalid parameter** ——
 *   表现为「开始扫描失败」，而不是「扫不到设备」，很容易被误判成权限问题。
 *
 * 注意与 `normalizeUuid` 分工：那个只做大小写归一，**用于比较**；
 * 这个只用于**传给系统接口的参数**，不要在比较逻辑里使用（否则两边格式必须都展开）。
 */
export function toFullUuid(uuid: string): string {
  const u = normalizeUuid(uuid);
  if (u.length === 0) return '';
  if (u.indexOf('-') >= 0) return u; // 已是 128 位形式
  if (u.length === 4) return '0000' + u + BLUETOOTH_BASE_UUID_SUFFIX;
  if (u.length === 8) return u + BLUETOOTH_BASE_UUID_SUFFIX;
  return u; // 其他长度原样返回，交给系统校验
}

/** 数字转 4 位十六进制（不依赖 padStart，ArkTS 上更稳妥） */
function hex4(value: number): string {
  const h = value.toString(16).toUpperCase();
  if (h.length >= 4) return h;
  if (h.length === 3) return `0${h}`;
  if (h.length === 2) return `00${h}`;
  return `000${h}`;
}

/** 查某个服务 UUID 是否是我们认识的（兼容短码与 128 位完整格式） */
export function findKnownService(serviceUuid: string): KnownService | null {
  for (const s of KNOWN_SERVICES) {
    if (uuidEquals(s.uuid, serviceUuid)) return s;
  }
  return null;
}

/** 查某个特征名 */
/**
 * 查某个特征。
 *
 * ⚠️ 返回类型必须是**具名**接口：ArkTS 不允许把内联对象类型当类型声明用
 * （arkts-no-obj-literals-as-types），写 `): { name: string } | null` 会编译失败。
 */
export function findKnownCharacteristic(serviceUuid: string, charUuid: string): KnownCharacteristic | null {
  const svc = findKnownService(serviceUuid);
  if (svc === null) return null;
  for (const c of svc.characteristics) {
    if (uuidEquals(c.uuid, charUuid)) {
      const hit: KnownCharacteristic = { uuid: c.uuid, name: c.name, subscribable: c.subscribable };
      return hit;
    }
  }
  return null;
}

// ---------------------------------------------------------------- 数据结构

/** 扫描到的设备（给 UI 用） */
export interface DiscoveredDevice {
  deviceId: string;
  name: string;
  rssi: number;
  /** 广播里带的服务 UUID（有些设备不广播，所以可能为空） */
  advertisedServices: string[];
  /** 我们是否认为它像健康设备 */
  looksLikeHealthDevice: boolean;
  lastSeen: number;
}

/** 扫描到的服务结构（给 UI 和调试用） */
export interface DiscoveredService {
  serviceUuid: string;
  serviceName: string;
  isKnown: boolean;
  characteristics: DiscoveredCharacteristic[];
}

export interface DiscoveredCharacteristic {
  characteristicUuid: string;
  characteristicName: string;
  properties: string[];
  /** 是否已订阅通知 */
  subscribed: boolean;
  /** 最近一次读到的原始值（十六进制） */
  lastRawHex: string;
}

/** 连接状态 */
export type BleConnectionState = 'idle' | 'connecting' | 'connected' | 'disconnected';

/** 回调接口：把事件交给上层（BleHealthSource / UI） */
export interface BleClientEvents {
  onDeviceFound?: (device: DiscoveredDevice) => void;
  onConnectionChange?: (state: BleConnectionState, deviceId: string) => void;
  onServices?: (services: DiscoveredService[]) => void;
  /** 收到特征值变化或读取结果 */
  onCharacteristicValue?: (serviceUuid: string, charUuid: string, value: Uint8Array) => void;
  onError?: (message: string) => void;
}

// ---------------------------------------------------------------- 解析器

/**
 * 解析标准心率测量值（0x2A37）。
 *
 * 官方格式：第 0 字节是 flags，
 *   bit0 = 0 → 心率是 uint8（在第 1 字节）
 *   bit0 = 1 → 心率是 uint16 little-endian（在第 1~2 字节）
 * 后面还可能跟能量消耗、RR 间期，本函数只取心率。
 *
 * @returns 心率（次/分）；解析失败返回 null
 */
export function parseHeartRateMeasurement(bytes: Uint8Array): number | null {
  if (!bytes || bytes.length < 2) return null;
  const flags = bytes[0];
  const isUint16 = (flags & 0x01) !== 0;
  if (isUint16) {
    if (bytes.length < 3) return null;
    return bytes[1] | (bytes[2] << 8);
  }
  return bytes[1];
}

/**
 * 解析脉搏血氧连续测量（0x2A5E）。
 * 格式：flags(1) + SpO2(2, SFLOAT) + PR(2, SFLOAT)…
 * SFLOAT 这里按整数低字节近似处理，够用；异常时返回 null。
 */
export function parseSpo2Measurement(bytes: Uint8Array): number | null {
  if (!bytes || bytes.length < 3) return null;
  // 简化：很多设备把 SpO2 直接放第 1 字节（百分比整数）
  const v = bytes[1];
  if (v <= 0 || v > 100) return null;
  return v;
}

/** 解析电池电量（0x2A19） */
export function parseBatteryLevel(bytes: Uint8Array): number | null {
  if (!bytes || bytes.length < 1) return null;
  const v = bytes[0];
  return v <= 100 ? v : null;
}

/** ArrayBuffer → Uint8Array */
export function toBytes(buf: ArrayBuffer): Uint8Array {
  return new Uint8Array(buf);
}

/** Uint8Array → 十六进制字符串（调试展示用） */
export function toHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const h = bytes[i].toString(16);
    out += (h.length === 1 ? '0' : '') + h;
    if (i !== bytes.length - 1) out += ' ';
  }
  return out;
}

// ---------------------------------------------------------------- 客户端主体

export class BleClient {
  /**
   * 事件订阅者列表。
   *
   * ⚠️ 为什么是数组而不是单个对象：
   *   同一个 BleClient 单例有**两个消费者** —— BleHealthSource（心率数据源）
   *   和 BleDevices（蓝牙设备扫描页）。原来 `setEvents()` 直接整体赋值，
   *   于是后注册的一方会把前一方的回调**全部顶掉**：
   *   用户在「蓝牙设备」页连上设备后，该页用空实现覆盖了
   *   `onCharacteristicValue`，心率就再也到不了数据源 → 永远发不到电脑。
   *   改成"合并注册 + 多方广播"后，两个消费者并存互不干扰。
   */
  private eventsList: BleClientEvents[] = [];
  private scanListener: ((results: ble.ScanResult[]) => void) | null = null;
  private scanning: boolean = false;
  private knownDevices: Map<string, DiscoveredDevice> = new Map();

  private gatt: ble.GattClientDevice | null = null;
  private connectedDeviceId: string = '';
  private _state: BleConnectionState = 'idle';

  /** 已发现的服务（连接后填充） */
  private services: DiscoveredService[] = [];
  /**
   * 特征索引："短服务UUID|短特征UUID" → `getServices()` 返回的**真实** BLECharacteristic。
   * 订阅/读取都必须用这些真实对象（它们带着 CCCD 描述符与正确的字段），
   * 自己构造的对象会被 SDK 以 401 Invalid parameter 拒绝。
   */
  private charRefs: Map<string, ble.BLECharacteristic> = new Map();
  /** SDK 返回的原始服务数组（保留用于调试与索引重建） */
  private rawServices: ble.GattService[] = [];
  /** 已订阅的特征 key（serviceUuid|charUuid），断开时用来退订 */
  private subscribedKeys: Set<string> = new Set();
  /** 订阅通知的回调引用，用于 off() */
  private charChangeCallback: ((c: ble.BLECharacteristic) => void) | null = null;
  private connChangeCallback: ((s: ble.BLEConnectionChangeState) => void) | null = null;

  /**
   * 「等待已连接事件」的挂起状态。
   * 因为 connect() 是同步方法、结果靠事件通知，所以用这组字段把事件与 Promise 连起来。
   */
  private pendingConnectId: string = '';
  private pendingConnectResolve: (() => void) | null = null;
  private pendingConnectReject: ((code: number, message: string) => void) | null = null;
  private pendingConnectTimer: number = -1;

  /** 通知兜底（订阅成功但不上报时改用轮询读） */
  private notifyFallbackTimer: number = -1;
  private notifyFallbackSvc: string = '';
  private notifyFallbackChr: string = '';
  /** 是否已收到过上报：收到后就不再轮询 */
  private notifyDataArrived: boolean = false;

  get state(): BleConnectionState {
    return this._state;
  }

  get currentDeviceId(): string {
    return this.connectedDeviceId;
  }

  get discoveredServices(): DiscoveredService[] {
    return this.services;
  }

  get deviceList(): DiscoveredDevice[] {
    return Array.from(this.knownDevices.values());
  }

  /**
   * 注册事件回调。**按字段合并**，不会清除其他订阅者已注册的回调。
   * 同一对象重复注册只保留一份（幂等），避免离开页面再进入时回调重复触发。
   */
  setEvents(events: BleClientEvents): void {
    const idx = this.eventsList.indexOf(events);
    if (idx >= 0) {
      this.eventsList[idx] = events;
      return;
    }
    this.eventsList.push(events);
  }

  /** 注销某个订阅者的全部回调（页面 aboutToDisappear 时调用，避免悬挂引用） */
  clearEvents(events: BleClientEvents): void {
    const idx = this.eventsList.indexOf(events);
    if (idx >= 0) {
      this.eventsList.splice(idx, 1);
    }
  }

  // ---- 事件广播：逐个通知所有订阅者，单个订阅者出错不影响其他 ----

  private emitDeviceFound(device: DiscoveredDevice): void {
    for (const e of this.eventsList) {
      try {
        if (e.onDeviceFound) e.onDeviceFound(device);
      } catch (err) {
        Logger.warn(TAG, 'onDeviceFound 回调异常');
      }
    }
  }

  private emitConnectionChange(state: BleConnectionState, deviceId: string): void {
    for (const e of this.eventsList) {
      try {
        if (e.onConnectionChange) e.onConnectionChange(state, deviceId);
      } catch (err) {
        Logger.warn(TAG, 'onConnectionChange 回调异常');
      }
    }
  }

  private emitServices(services: DiscoveredService[]): void {
    for (const e of this.eventsList) {
      try {
        if (e.onServices) e.onServices(services);
      } catch (err) {
        Logger.warn(TAG, 'onServices 回调异常');
      }
    }
  }

  private emitCharacteristicValue(serviceUuid: string, charUuid: string, bytes: Uint8Array): void {
    for (const e of this.eventsList) {
      try {
        if (e.onCharacteristicValue) e.onCharacteristicValue(serviceUuid, charUuid, bytes);
      } catch (err) {
        Logger.warn(TAG, 'onCharacteristicValue 回调异常');
      }
    }
  }

  private emitError(message: string): void {
    for (const e of this.eventsList) {
      try {
        if (e.onError) e.onError(message);
      } catch (err) {
        Logger.warn(TAG, 'onError 回调异常');
      }
    }
  }

  // ------------------------------------------------------------ 蓝牙开关

  /** 蓝牙是否已打开 */
  isBluetoothOn(): boolean {
    try {
      return access.getState() === access.BluetoothState.STATE_ON;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `读取蓝牙状态失败 code=${e.code}`);
      return false;
    }
  }

  // ------------------------------------------------------------ 扫描

  /**
   * 开始扫描。
   * @param services 想过滤的服务 UUID（短格式如 "180D"，内部会展开成 128 位）；传空数组 = 扫全部
   * @param aggressive true 用低延迟高功耗模式
   */
  startScan(services: string[] = [], aggressive: boolean = false): void {
    if (this.scanning) {
      Logger.info(TAG, '已在扫描中，忽略重复调用');
      return;
    }
    if (!this.isBluetoothOn()) {
      this.emitError('蓝牙未打开，请先在系统设置里打开蓝牙');
      return;
    }

    // ⚠️ 扫描结果是**模块级**事件 ble.on('BLEDeviceFind')，
    //    不是 GattClientDevice 实例上的事件。这点很容易写错。
    this.scanListener = (results: ble.ScanResult[]) => {
      for (const r of results) {
        const advertised = this.extractAdvertisedServices(r);
        const device: DiscoveredDevice = {
          deviceId: r.deviceId,
          name: r.deviceName && r.deviceName.length > 0 ? r.deviceName : '(未命名设备)',
          rssi: r.rssi,
          advertisedServices: advertised,
          looksLikeHealthDevice: this.guessIsHealthDevice(r.deviceName, advertised),
          lastSeen: Date.now()
        };
        const existed = this.knownDevices.get(device.deviceId);
        if (existed) {
          // 保留更完整的名字，更新信号强度
          device.name = existed.name !== '(未命名设备)' ? existed.name : device.name;
        }
        this.knownDevices.set(device.deviceId, device);
        this.emitDeviceFound(device);
      }
    };

    try {
      ble.on('BLEDeviceFind', this.scanListener);

      // ⚠️ serviceUuid 必须传 **128 位完整 UUID**，短格式会让参数校验抛 401。
      //    无过滤时官方要求传 null（空数组虽未明确禁止，但它不等于"不过滤"，
      //    且官方参数表注明"该参数设置为 null 将扫描所有可发现的周边 BLE 设备"）。
      let filters: ble.ScanFilter[] | null = null;
      if (services.length > 0) {
        const list: ble.ScanFilter[] = [];
        for (const s of services) {
          const full = toFullUuid(s);
          if (full.length === 0) continue;
          list.push({ serviceUuid: full });
        }
        filters = list.length > 0 ? list : null;
      }
      const options: ble.ScanOptions = {
        dutyMode: aggressive ? ble.ScanDuty.SCAN_MODE_LOW_LATENCY : ble.ScanDuty.SCAN_MODE_BALANCED,
        matchMode: aggressive ? ble.MatchMode.MATCH_MODE_AGGRESSIVE : ble.MatchMode.MATCH_MODE_STICKY
      };
      ble.startBLEScan(filters, options);
      this.scanning = true;
      Logger.info(TAG, `开始扫描（过滤服务=${services.length ? services.map((s) => toFullUuid(s)).join(',') : '全部'}）`);
    } catch (err) {
      const e = err as BusinessError;
      this.scanning = false;
      this.emitError(this.explainBleError(e, '开始扫描失败'));
    }
  }

  stopScan(): void {
    if (!this.scanning && this.scanListener === null) return;
    try {
      ble.stopBLEScan();
    } catch (err) {
      // 停止失败通常是因为已经在停，不当作错误
      const e = err as BusinessError;
      Logger.warn(TAG, `停止扫描异常 code=${e.code}（通常可忽略）`);
    }
    if (this.scanListener !== null) {
      try {
        ble.off('BLEDeviceFind', this.scanListener);
      } catch (err) {
        Logger.warn(TAG, '移除扫描监听失败');
      }
      this.scanListener = null;
    }
    this.scanning = false;
    Logger.info(TAG, '已停止扫描');
  }

  isScanning(): boolean {
    return this.scanning;
  }

  clearDeviceList(): void {
    this.knownDevices.clear();
  }

  // ------------------------------------------------------------ 连接

  /**
   * 连接设备并发现服务。**失败会自动重试 2 次**。
   *
   * 为什么要重试：BLE 连接首次失败非常常见（设备刚从广播态切到可连接态需要时间、
   * 扫描刚停时射频还在切换、系统蓝牙栈繁忙）。官方错误码 `2900099 Operation failed`
   * 就是这种"通用操作失败"，官方文档也没给出更细的原因，实测重试往往第二次就成功。
   *
   * 成功后会自动：
   *   1. 枚举全部服务/特征（结果通过 onServices 回调给 UI）
   *   2. 对认识的可订阅特征自动开启通知（心率 / 血氧 / 电量）
   */
  async connect(deviceId: string): Promise<boolean> {
    // ⚠️ 已经连的就是这台设备 → 直接返回成功，**绝不能断开重连**。
    //
    //    踩过的坑：原来这里是「只要 this.gatt 不为 null 就先 disconnect()」，
    //    于是任何一次多余的 connect() 调用都会把已经好的连接掐断。
    //    表现正是"在设备页连上了，返回主页后设备又断开"——
    //    因为返回主页会触发数据源的自动重连，而那一刻若 state 尚未settle成
    //    'connected'，就会走进来把连接断掉、再重连一次。
    if (this.gatt !== null && this.connectedDeviceId === deviceId) {
      Logger.info(TAG, `已连接 ${deviceId}，跳过重复连接`);
      return true;
    }
    // 连的是另一台设备：才需要先把旧的断开
    if (this.gatt !== null) {
      Logger.info(TAG, `切换到设备 ${deviceId}，先断开 ${this.connectedDeviceId}`);
      await this.disconnect();
    }
    if (!this.isBluetoothOn()) {
      this.emitError('蓝牙未打开');
      return false;
    }

    let lastCode = 0;
    let lastMsg = '';
    for (let attempt = 1; attempt <= CONNECT_MAX_ATTEMPTS; attempt++) {
      this.setState('connecting', deviceId);
      const result = await this.connectOnce(deviceId);
      if (result.ok) {
        return true;
      }
      lastCode = result.code;
      lastMsg = result.message;

      // 失败后必须彻底断开并清掉 gatt，否则残留状态会让重试一直失败
      await this.disconnect();

      if (attempt < CONNECT_MAX_ATTEMPTS) {
        Logger.warn(TAG, `连接第 ${attempt} 次失败 code=${lastCode}，${CONNECT_RETRY_DELAY_MS}ms 后重试`);
        this.emitError(`第 ${attempt} 次连接失败，正在重试…`);
        await sleepMs(CONNECT_RETRY_DELAY_MS);
      }
    }

    this.setState('disconnected', deviceId);
    this.emitError(this.explainConnectFailure(lastCode, lastMsg, deviceId));
    return false;
  }

  /**
   * 单次连接尝试。成功返回 { ok: true }，失败返回错误码与原始消息。
   * 注意：只有连接成功才把 gatt 记录到 this.gatt，避免失败后留下半连接状态。
   */
  private async connectOnce(deviceId: string): Promise<ConnectAttempt> {
    try {
      const gatt = ble.createGattClientDevice(deviceId);

      // 注册连接状态变化
      this.connChangeCallback = (s: ble.BLEConnectionChangeState) => {
        const st = this.mapConnState(s.state);
        Logger.info(TAG, `连接状态变化: ${st} (deviceId=${s.deviceId})`);
        this.setState(st, s.deviceId);

        // 把事件转成「等待连接」的信号（connect() 是同步方法，结果只能靠事件）
        if (this.pendingConnectId !== '' && s.deviceId === this.pendingConnectId) {
          if (st === 'connected') {
            const done = this.pendingConnectResolve;
            if (done !== null) done();
            return;
          }
          if (st === 'disconnected') {
            const fail = this.pendingConnectReject;
            if (fail !== null) fail(2900099, '设备拒绝了连接或立即断开');
            return;
          }
        }

        if (st === 'disconnected') {
          this.emitError('与设备断开连接');
        }
      };
      gatt.on('BLEConnectionStateChange', this.connChangeCallback);

      // 注册特征值变化（订阅通知会走这里）
      this.charChangeCallback = (c: ble.BLECharacteristic) => {
        const bytes = toBytes(c.characteristicValue);
        this.handleValue(c.serviceUuid, c.characteristicUuid, bytes);
      };
      gatt.on('BLECharacteristicChange', this.charChangeCallback);

      // ⚠️⚠️ 这里是本项目最容易写错的一处，务必按官方语义来：
      //
      //   官方签名：  connect(): void        —— 是**同步**方法，不是 Promise！
      //   官方原文：  "client 可通过订阅 on('BLEConnectionStateChange') 事件来感知连接是否成功"
      //
      // 之前这里写成 `await gatt.connect()`，把它当 Promise 用，是错的：
      //   · connect() 只是"发起"连接，返回值不可 await；
      //   · 成功与否必须等 BLEConnectionStateChange 事件；
      //   · 而且 getServices() 必须在**事件报告已连接之后**调用，否则必然失败。
      //
      // 正确顺序：注册事件 → 发起连接 → 等"已连接"事件 → 再取服务。
      await this.waitForConnected(gatt, deviceId);
      Logger.info(TAG, `已连接 ${deviceId}`);

      // 发现服务（此时已确认连接建立）
      const rawServices = await gatt.getServices();
      this.rawServices = rawServices;
      // 先建索引：订阅/读取都要用这里的真实对象
      this.indexCharacterRefs(rawServices);
      this.services = this.mapServices(rawServices);
      Logger.info(TAG, `发现 ${this.services.length} 个服务`);
      // 一次性把全部服务/特征打成清单：日志是滚动+倒序的，
      // 逐条打印时关键行（例如 180D）很容易被刷掉，导致误判"设备没暴露心率服务"。
      this.logServiceInventory();

      // 连接成功后才记录，便于失败时判断是否需要清理
      this.gatt = gatt;
      this.connectedDeviceId = deviceId;

      // 自动订阅已知的可订阅特征
      await this.autoSubscribe(gatt);

      this.emitServices(this.services);
      this.setState('connected', deviceId);
      return { ok: true, code: 0, message: '' };
    } catch (err) {
      // ArkTS 里 catch 拿到的是 unknown，必须显式转成 BusinessError 才能读 code
      const e = err as BusinessError;
      const code: number = e.code !== undefined ? e.code : 0;
      const message: string = e.message !== undefined ? e.message : '未知错误';
      return { ok: false, code: code, message: message };
    }
  }

  /**
   * 发起连接并**等待 BLEConnectionStateChange 事件**报告"已连接"。
   *
   * 这是本文件最容易写错的地方：`connect()` 是同步方法（`: void`），不是 Promise。
   * 它只负责"发起"，成功与否由事件回调告知，所以必须用 Promise 包一层等事件。
   *
   * @throws BusinessError 连接发起即失败（如 2900099 / 201 / 2900003）
   * @throws Error 事件迟迟未到达（超时）
   */
  private waitForConnected(gatt: ble.GattClientDevice, deviceId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.pendingConnectId = deviceId;
      this.pendingConnectResolve = () => {
        this.clearPendingConnect();
        resolve();
      };
      this.pendingConnectReject = (code: number, message: string) => {
        this.clearPendingConnect();
        const be: BusinessError = makeBusinessError(code, message);
        reject(be);
      };
      this.pendingConnectTimer = setTimeout(() => {
        const stillThisOne = this.pendingConnectId === deviceId;
        this.clearPendingConnect();
        if (stillThisOne) {
          const be: BusinessError = makeBusinessError(E_CODE_TIMEOUT, `连接超时（${CONNECT_TIMEOUT_MS}ms 内未收到已连接事件）`);
          reject(be);
        }
      }, CONNECT_TIMEOUT_MS);

      // 发起连接：同步抛错说明连"发起"这一步都没成功
      gatt.connect();
    });
  }

  private clearPendingConnect(): void {
    if (this.pendingConnectTimer !== -1) {
      clearTimeout(this.pendingConnectTimer);
      this.pendingConnectTimer = -1;
    }
    this.pendingConnectId = '';
    this.pendingConnectResolve = null;
    this.pendingConnectReject = null;
  }

  /**
   * 连接失败的针对性提示。
   * `2900099` 是通用"操作失败"，官方没有更细的说明，所以这里按**实测最常见的三个原因**给出可操作建议。
   */
  private explainConnectFailure(code: number, rawMessage: string, deviceId: string): string {
    let hint = '';
    switch (code) {
      case 201:
        hint = '缺少蓝牙权限：请到 设置 → 应用 → 权限 里授予「蓝牙」权限';
        break;
      case 2900001:
        hint = '蓝牙服务已停止：关掉蓝牙再打开试试';
        break;
      case 2900003:
        hint = '蓝牙未打开：请先打开系统蓝牙';
        break;
      case -1:
        hint =
          '已发出连接但没有收到"已连接"事件。常见原因：\n' +
          '1) 设备已被别处占用 —— BLE 设备通常只允许一个中心连接，请先断开系统蓝牙里的连接，并退出心率带厂商 App；\n' +
          '2) 臂带没戴在皮肤上 —— 光电心率带多数要检测到皮肤才允许连接；\n' +
          '3) 设备已休眠 —— 动一下臂带或重新佩戴后重试。';
        break;
      case 2900099:
        hint =
          '连接发起即失败。常见原因（按可能性排序）：\n' +
          '1) 该设备已被别处占用 —— 请先断开系统蓝牙里的连接，并退出心率带厂商 App（如 CooSpo）；\n' +
          '2) 扫描得到的地址已过期 —— 回上一层「重新扫描」一次，再点连接；\n' +
          '3) 蓝牙栈状态异常 —— 关掉蓝牙开关再打开后重试。';
        break;
      case 801:
        hint = '该设备不支持此能力';
        break;
      default:
        hint = '未知原因，可尝试重新扫描后再连接';
        break;
    }
    const msg = `连接 ${deviceId} 失败（已重试 ${CONNECT_MAX_ATTEMPTS} 次）：code=${code} ${rawMessage}\n${hint}`;
    Logger.error(TAG, msg);
    return msg;
  }

  async disconnect(): Promise<void> {
    // 清掉可能挂起的连接等待，避免上次失败的重试流程残留
    this.clearPendingConnect();
    const gatt = this.gatt;
    if (gatt === null) {
      this.setState('disconnected', this.connectedDeviceId);
      return;
    }
    try {
      // 先退订，避免断开时收到残留通知
      for (const key of this.subscribedKeys) {
        const parts = key.split('|');
        try {
          const c = this.findCharacteristicRef(parts[0], parts[1]);
          if (c !== null) {
            await gatt.setCharacteristicChangeNotification(c, false);
          }
        } catch (err) {
          // 退订失败不影响断开
        }
      }
      this.subscribedKeys.clear();

      if (this.connChangeCallback !== null) {
        gatt.off('BLEConnectionStateChange', this.connChangeCallback);
        this.connChangeCallback = null;
      }
      if (this.charChangeCallback !== null) {
        gatt.off('BLECharacteristicChange', this.charChangeCallback);
        this.charChangeCallback = null;
      }

      gatt.disconnect();
      gatt.close();
      Logger.info(TAG, `已断开 ${this.connectedDeviceId}`);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `断开连接异常 code=${e.code}`);
    } finally {
      this.stopNotifyFallback();
      this.gatt = null;
      this.rawServices = [];
      this.charRefs.clear();
      this.services = [];
      this.setState('disconnected', this.connectedDeviceId);
    }
  }

  // ------------------------------------------------------------ 读 / 订阅

  /** 主动读一次某个特征（适合"读一次"型数据，如设备信息、电量） */
  async readCharacteristic(serviceUuid: string, charUuid: string): Promise<Uint8Array | null> {
    const gatt = this.gatt;
    if (gatt === null) {
      this.emitError('未连接设备，无法读取');
      return null;
    }
    const ref = this.findCharacteristicRef(serviceUuid, charUuid);
    if (ref === null) {
      this.emitError(`未找到特征 ${serviceUuid}/${charUuid}`);
      return null;
    }
    try {
      const result = await gatt.readCharacteristicValue(ref);
      const bytes = toBytes(result.characteristicValue);
      this.handleValue(serviceUuid, charUuid, bytes);
      return bytes;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `读取特征 ${serviceUuid}/${charUuid} 失败 code=${e.code}`);
      return null;
    }
  }

  /** 开启/关闭某个特征的通知订阅 */
  async setNotify(serviceUuid: string, charUuid: string, enable: boolean): Promise<boolean> {
    const gatt = this.gatt;
    if (gatt === null) {
      this.emitError('未连接设备，无法订阅');
      return false;
    }
    const ref = this.findCharacteristicRef(serviceUuid, charUuid);
    if (ref === null) {
      this.emitError(`未找到特征 ${serviceUuid}/${charUuid}`);
      return false;
    }
    const key = `${shortUuid(serviceUuid)}|${shortUuid(charUuid)}`;
    try {
      await gatt.setCharacteristicChangeNotification(ref, enable);
      if (enable) this.subscribedKeys.add(key);
      else this.subscribedKeys.delete(key);
      // 同步到展示用的数据结构
      for (const s of this.services) {
        if (!uuidEquals(s.serviceUuid, serviceUuid)) continue;
        for (const c of s.characteristics) {
          if (uuidEquals(c.characteristicUuid, charUuid)) {
            c.subscribed = enable;
          }
        }
      }
      this.emitServices(this.services);
      Logger.info(TAG, `${enable ? '开启' : '关闭'}订阅 ${serviceUuid}/${charUuid}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      this.emitError(`订阅 ${serviceUuid}/${charUuid} 失败 code=${e.code}`);
      return false;
    }
  }

  // ------------------------------------------------------------ 内部

  /** 连接后自动订阅认识的可订阅特征 */
  private async autoSubscribe(gatt: ble.GattClientDevice): Promise<void> {
    Logger.info(TAG, `开始自动订阅，共 ${this.services.length} 个服务`);
    for (const svc of this.services) {
      const known = findKnownService(svc.serviceUuid);
      // 把每个服务的识别结果都打出来，否则"识别不到"时是完全静默的
      Logger.info(
        TAG,
        `服务 ${shortUuid(svc.serviceUuid)} → ${known ? `已识别：${known.name}` : '未识别（私有协议）'}，` +
          `特征数 ${svc.characteristics.length}`
      );
      if (known === null) continue;
      for (const ch of svc.characteristics) {
        const kc = findKnownCharacteristic(svc.serviceUuid, ch.characteristicUuid);
        const wantsNotify = known.characteristics.some(
          (k) => uuidEquals(k.uuid, ch.characteristicUuid) && k.subscribable
        );
        Logger.info(
          TAG,
          `  特征 ${shortUuid(ch.characteristicUuid)}${kc ? `（${kc.name}）` : ''} ` +
            `属性=[${ch.properties.join(',')}] 需订阅=${wantsNotify}`
        );
        if (!wantsNotify) continue;

        const ref = this.findCharacteristicRef(svc.serviceUuid, ch.characteristicUuid);
        if (ref === null) {
          Logger.warn(TAG, `  找不到 ${ch.characteristicUuid} 的引用，跳过`);
          continue;
        }

        try {
          await gatt.setCharacteristicChangeNotification(ref, true);
          this.subscribedKeys.add(`${shortUuid(svc.serviceUuid)}|${shortUuid(ch.characteristicUuid)}`);
          ch.subscribed = true;
          Logger.info(TAG, `  ✅ 已订阅 ${kc ? kc.name : ch.characteristicUuid}，等待通知…`);
          // 订阅成功但设备可能不上报：启动轮询兜底
          this.startNotifyFallback(svc.serviceUuid, ch.characteristicUuid);
        } catch (err) {
          const e = err as BusinessError;
          // 有些特征声明可通知但实际不允许，静默跳过并尝试直接读一次
          Logger.info(TAG, `自动订阅 ${ch.characteristicUuid} 未成功 code=${e.code}，改为读一次`);
          try {
            const r = await gatt.readCharacteristicValue(ref);
            this.handleValue(svc.serviceUuid, ch.characteristicUuid, toBytes(r.characteristicValue));
          } catch (err2) {
            // 读也不行就放弃这个特征
            Logger.info(TAG, `读取 ${ch.characteristicUuid} 也不支持，跳过`);
          }
        }
      }
    }
  }

  /**
   * 通知兜底：订阅成功后若一段时间收不到上报，就改用轮询读。
   *
   * 为什么要它：OpenHarmony 的 `setCharacteristicChangeNotification` 有时会"成功返回但设备不上报"
   * （例如 CCCD 描述符写入未生效、或设备侧要求先配对）。心率测量特征通常同时支持 read 与 notify，
   * 所以轮询读能得到同样的数据 —— 宁可多几次读，也不要让用户面对"连上了却没数据"。
   */
  private startNotifyFallback(serviceUuid: string, charUuid: string): void {
    this.notifyFallbackSvc = serviceUuid;
    this.notifyFallbackChr = charUuid;
    this.notifyDataArrived = false;
    const gatt = this.gatt;
    if (gatt === null) return;

    // 先给通知 3 秒机会；之后若仍无数据，改为每 3 秒轮询读一次
    this.notifyFallbackTimer = setTimeout(() => {
      if (this.notifyDataArrived) return;
      Logger.info(TAG, `${NOTIFY_FALLBACK_DELAY_MS}ms 内未收到通知，改为轮询读取 ${shortUuid(charUuid)}`);

      const poll = async (): Promise<void> => {
        if (this.gatt === null) return;
        if (this.notifyDataArrived) return;
        const ref = this.findCharacteristicRef(serviceUuid, charUuid);
        if (ref === null) return;
        try {
          const r = await this.gatt.readCharacteristicValue(ref);
          this.handleValue(serviceUuid, charUuid, toBytes(r.characteristicValue));
          Logger.info(TAG, `轮询读到 ${shortUuid(charUuid)}: ${toHex(toBytes(r.characteristicValue))}`);
        } catch (err) {
          const e = err as BusinessError;
          Logger.warn(TAG, `轮询读取失败 code=${e.code}`);
        }
        if (this.gatt !== null) {
          this.notifyFallbackTimer = setTimeout(() => {
            poll();
          }, NOTIFY_POLL_INTERVAL_MS);
        }
      };
      poll();
    }, NOTIFY_FALLBACK_DELAY_MS);
  }

  private stopNotifyFallback(): void {
    if (this.notifyFallbackTimer !== -1) {
      clearTimeout(this.notifyFallbackTimer);
      this.notifyFallbackTimer = -1;
    }
    this.notifyDataArrived = false;
    this.notifyFallbackSvc = '';
    this.notifyFallbackChr = '';
  }

  /** 把 SDK 的 GattService[] 映射成展示用结构 */
  private mapServices(raw: ble.GattService[]): DiscoveredService[] {
    const out: DiscoveredService[] = [];
    if (!raw) return out;
    for (const s of raw) {
      const known = findKnownService(s.serviceUuid);
      const chars: DiscoveredCharacteristic[] = [];
      const list = s.characteristics || [];
      for (const c of list) {
        const kc = findKnownCharacteristic(s.serviceUuid, c.characteristicUuid);
        chars.push({
          characteristicUuid: shortUuid(c.characteristicUuid),
          characteristicName: kc ? kc.name : '未知特征',
          properties: this.describeProperties(c.properties),
          subscribed: false,
          lastRawHex: ''
        });
      }
      out.push({
        serviceUuid: shortUuid(s.serviceUuid),
        serviceName: known ? known.name : '未知服务（私有协议）',
        isKnown: known !== null,
        characteristics: chars
      });
    }
    // 认识的服务排在前面，方便一眼看到有没有心率
    out.sort((a, b) => (a.isKnown === b.isKnown ? 0 : a.isKnown ? -1 : 1));
    return out;
  }

  private describeProperties(p?: ble.GattProperties): string[] {
    const out: string[] = [];
    if (!p) return out;
    if (p.read) out.push('读');
    if (p.write) out.push('写');
    if (p.notify) out.push('通知');
    if (p.indicate) out.push('指示');
    return out;
  }

  /**
   * 一次性打印完整的服务/特征清单。
   *
   * 为什么需要：日志是滚动的且界面倒序显示，逐条打印时"180D 在不在"这类关键信息
   * 很容易被后续日志挤出可见区域，造成"设备没暴露心率服务"的误判。
   * 这里把清单拼成一条日志，保证一眼能看全。
   */
  private logServiceInventory(): void {
    let lines = '';
    for (const s of this.services) {
      const props: string[] = [];
      for (const c of s.characteristics) {
        props.push(`${shortUuid(c.characteristicUuid)}[${c.properties.join('/')}]`);
      }
      lines += `\n  ${shortUuid(s.serviceUuid)} ${s.isKnown ? s.serviceName : '(未识别)'}` +
        `：${props.length > 0 ? props.join(' ') : '(无特征)'}`;
    }
    const hasHr = this.services.some((s) => s.serviceUuid === '180D');
    Logger.info(
      TAG,
      `【服务清单】心率服务180D=${hasHr ? '有 ✅' : '无 ❌'}，共 ${this.services.length} 个服务：${lines}`
    );
  }

  /**
   * 找出可传给 SDK 的 BLECharacteristic 引用。
   *
   * ⚠️ 必须返回 `getServices()` 返回的**原始对象**，不能自己 new。
   * 原因：启用通知依赖特征下的 CCCD 描述符（00002902-…）；
   * 自己构造时 `descriptors` 只能是空数组、`characteristicValue` 也只能给空 buffer，
   * SDK 在参数校验阶段就会拒绝并抛 **401 Invalid parameter**
   * （实测报错：`自动订阅 2A19 未成功 code=401`）。
   * 所以这里只在 [charRefs] 里查，查不到就明确返回 null 让调用方打印日志，不再"退路构造"。
   */
  private findCharacteristicRef(serviceUuid: string, charUuid: string): ble.BLECharacteristic | null {
    if (this.gatt === null) return null;
    const key = `${shortUuid(serviceUuid)}|${shortUuid(charUuid)}`;
    const hit = this.charRefs.get(key);
    return hit !== undefined ? hit : null;
  }

  /**
   * 用 `getServices()` 的原始返回值建立特征索引：
   * "短服务UUID|短特征UUID" → 真实 BLECharacteristic 对象。
   */
  private indexCharacterRefs(raw: ble.GattService[]): void {
    this.charRefs.clear();
    for (const s of raw) {
      const svc = shortUuid(s.serviceUuid);
      const list = s.characteristics || [];
      for (const c of list) {
        this.charRefs.set(`${svc}|${shortUuid(c.characteristicUuid)}`, c);
      }
    }
    Logger.info(TAG, `已索引 ${this.charRefs.size} 个特征（来自 ${raw.length} 个服务）`);
  }

  /** 统一的取值入口：刷新展示数据 + 抛给上层 */
  private handleValue(serviceUuid: string, charUuid: string, bytes: Uint8Array): void {
    const hex = toHex(bytes);
    // ⚠️ 只有"兜底订阅的那个特征"收到值，才算通知链路通了。
    //    不能无条件置 true —— 该方法会收到所有特征的值（含电量），
    //    否则一条电量通知就会把心率的轮询兜底停掉。
    if (
      this.notifyFallbackSvc.length > 0 &&
      uuidEquals(serviceUuid, this.notifyFallbackSvc) &&
      uuidEquals(charUuid, this.notifyFallbackChr)
    ) {
      this.notifyDataArrived = true;
    }
    Logger.info(TAG, `收到数据 ${shortUuid(serviceUuid)}/${shortUuid(charUuid)} = ${hex}`);
    for (const s of this.services) {
      if (!uuidEquals(s.serviceUuid, serviceUuid)) continue;
      for (const c of s.characteristics) {
        if (uuidEquals(c.characteristicUuid, charUuid)) {
          c.lastRawHex = hex;
        }
      }
    }
    this.emitCharacteristicValue(shortUuid(serviceUuid), shortUuid(charUuid), bytes);
  }

  private setState(state: BleConnectionState, deviceId: string): void {
    this._state = state;
    this.emitConnectionChange(state, deviceId);
  }

  /**
   * 把 SDK 的 ProfileConnectionState 映射成本项目的状态。
   *
   * 官方语义（@ohos.bluetooth.constant.d.ts）：
   *   0 STATE_DISCONNECTED  已断开
   *   1 STATE_CONNECTING    正在连接
   *   2 STATE_CONNECTED     已连接
   *   3 STATE_DISCONNECTING **正在断开**（过渡态，此时物理连接还在）
   *
   * ⚠️ 踩过的坑：原来把 3 也映射成 'disconnected'。
   *    而 connChangeCallback 收到 'disconnected' 会 emitError('与设备断开连接')，
   *    于是在"正在断开"的过渡瞬间就误报断开，UI 上看起来是"突然掉线"。
   *    这里把 3 映射为一个独立的过渡态，只在真正的 0 才认定断开。
   */
  private mapConnState(s: number): BleConnectionState {
    switch (s) {
      case 1:
        return 'connecting'; // STATE_CONNECTING
      case 2:
        return 'connected'; // STATE_CONNECTED
      case 3:
        return 'connecting'; // STATE_DISCONNECTING —— 过渡态，不当作已断开
      default:
        return 'disconnected'; // STATE_DISCONNECTED = 0
    }
  }

  /** 从广播数据里粗略提取服务 UUID（长度不足就直接放弃，不影响主流程） */
  private extractAdvertisedServices(r: ble.ScanResult): string[] {
    // 广播报文解析需要按 AD 结构逐段走，这里做保守处理：
    // 只把 16 位服务 UUID 的常见位置扫一遍，扫不到就返回空。
    // 真正的服务列表在连接后用 getServices() 拿，那才是权威数据。
    const out: string[] = [];
    try {
      const bytes = toBytes(r.data);
      let i = 0;
      while (i + 1 < bytes.length) {
        const len = bytes[i];
        if (len === 0) break;
        const type = bytes[i + 1];
        // 0x02/0x03 = 16 位服务 UUID 完整/不完整列表
        if ((type === 0x02 || type === 0x03) && len >= 3) {
          for (let j = i + 2; j + 1 < i + 1 + len && j + 1 < bytes.length; j += 2) {
            const u = (bytes[j + 1] << 8) | bytes[j];
            out.push(hex4(u));
          }
        }
        i += len + 1;
      }
    } catch (err) {
      // 广播解析失败无所谓
    }
    return out;
  }

  /**
   * 猜它像不像健康设备。只用于给列表排序/标注，不影响功能。
   * 依据：名字里带这些词，或广播了标准健康服务。
   */
  private guessIsHealthDevice(name: string, services: string[]): boolean {
    const n = (name || '').toLowerCase();
    // ArkTS 要求数组字面量元素类型可推断，这里显式标注 string[]
    const nameHints: string[] = ['watch', 'band', 'hr', 'heart', 'pulse', 'fit', 'sport', 'tracker', '手环', '手表', '心率'];
    for (const h of nameHints) {
      if (n.includes(h)) return true;
    }
    const healthServices: string[] = ['180D', '1822', '1810', '1809'];
    for (const s of services) {
      if (healthServices.includes(shortUuid(s))) return true;
    }
    return false;
  }

  /** 把蓝牙错误码翻译成人话 */
  private explainBleError(e: BusinessError, prefix: string): string {
    let hint = '';
    switch (e.code) {
      case 201:
        hint = '缺少 ohos.permission.ACCESS_BLUETOOTH 权限';
        break;
      case 2900001:
        hint = '蓝牙服务已停止';
        break;
      case 2900003:
        hint = '蓝牙未打开';
        break;
      case 2900099:
        hint = '操作失败（若发生在连接阶段，请看 explainConnectFailure 的详细提示）';
        break;
      case 801:
        hint = '该设备不支持此能力';
        break;
      default:
        break;
    }
    const msg = `${prefix}：code=${e.code} ${e.message}${hint ? `（${hint}）` : ''}`;
    Logger.error(TAG, msg);
    return msg;
  }
}
