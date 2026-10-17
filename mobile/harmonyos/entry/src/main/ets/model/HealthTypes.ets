/**
 * HealthLink 手机端数据模型与协议类型。
 *
 * metric 枚举、单位、时序语义与 docs/protocol/README.md 第 3 节严格一致。
 * 改动这里必须同步改协议文档并升版本号。
 */

import { healthStore } from '@kit.HealthServiceKit';

/** 协议版本，与电脑端 PROTOCOL_VERSION 一致 */
export const PROTOCOL_VERSION: number = 1;

export type HealthMetric =
  | 'heart_rate'
  | 'resting_heart_rate'
  | 'hrv'
  | 'spo2'
  | 'stress'
  | 'sleep'
  | 'sleep_nap'
  | 'body_temperature';

/**
 * 数据来源标记，写进每条 sample 的 payload.source。
 *
 * · `ble`         —— BLE GATT 直连外设（无需华为审批，心率可实时订阅）
 * · `healthStore` —— 华为 Health Service Kit（需 AGC 资质审核）
 * · `mock`        —— 模拟数据（tools/phone-sim.js 用）
 * · `manual`      —— 用户在应用内手动录入
 */
export type SampleSource = 'ble' | 'healthStore' | 'mock' | 'manual';

/** 用户可选的数据源种类 */
export type SourceKind = 'ble' | 'healthStore';

/**
 * 数据源种类的显示名。
 *
 * ⚠️ 这里刻意用 switch 而不是 `Record<string, string>` 常量表：
 * ArkTS 严格模式报 `arkts-no-untyped-obj-literals`，字符串键的 Record
 * 对象字面量不满足"必须对应具名 class/interface"的要求（编译器实测确认）。
 */
export function sourceLabel(kind: string): string {
  switch (kind) {
    case 'ble':
      return 'BLE 直连';
    case 'healthStore':
      return '华为 Health Service Kit';
    default:
      return kind;
  }
}

/** 一次采样的完整载荷（= 协议 sample.payload） */
export interface SamplePayload {
  metric: HealthMetric;
  value: number | null;
  unit: string | null;
  startTime: number;
  endTime: number;
  source: SampleSource;
  sleep?: SleepPayload | null;
}

/** 睡眠分期明细（官方 SleepSegment 的传输表示） */
export interface SleepSegmentPayload {
  startTime: number;
  endTime: number;
  /** 官方 sleepStatus：0未知 1深睡 2浅睡 3REM 4清醒 5小睡 6卧床 7手动记录 */
  sleepStatus: number;
}

/**
 * 睡眠复合载荷。
 * 字段名与官方 healthFields.Sleep 完全一致，不做二次编码。
 */
export interface SleepPayload {
  fallAsleepTime: number;
  wakeupTime: number;
  duration: number;
  sleepScore?: number | null;
  sleepEfficiency?: number | null;
  deepSleepContinuity?: number | null;
  respiratoryQualityScore?: number | null;
  deepDuration?: number | null;
  shallowDuration?: number | null;
  dreamDuration?: number | null;
  wakeDuration?: number | null;
  wakeCount?: number | null;
  turnOverCount?: number | null;
  onBedDuration?: number | null;
  recordDuration?: number | null;
  sleepType?: number | null;
  sleepEndReason?: number | null;
  sleepSymptoms?: string | null;
  sleepSegment?: SleepSegmentPayload[];
  /** 官方 sleep 字段里没有的旧版字段，能算出来才填 */
  legacy?: Record<string, number>;
}

/** 指标元信息 */
export interface MetricMeta {
  metric: HealthMetric;
  label: string;
  unit: string | null;
  /** 官方数据类型常量 */
  dataType: healthStore.DataType;
  /** true=采样点（readData<SamplePoint>），false=健康记录（readData<HealthSequence>） */
  isSamplePoint: boolean;
  /** 该指标需要的最低 API 版本（HRV 需要 18） */
  minApiLevel: number;
}

/**
 * 全部指标清单。顺序即采集顺序。
 * 注意：sleep 用 healthSequenceHelper，其余用 samplePointHelper。
 */
export const METRIC_METAS: MetricMeta[] = [
  {
    metric: 'heart_rate',
    label: '动态心率',
    unit: 'bpm',
    dataType: healthStore.samplePointHelper.heartRate.DATA_TYPE,
    isSamplePoint: true,
    minApiLevel: 12
  },
  {
    metric: 'resting_heart_rate',
    label: '静息心率',
    unit: 'bpm',
    dataType: healthStore.samplePointHelper.restingHeartRate.DATA_TYPE,
    isSamplePoint: true,
    minApiLevel: 12
  },
  {
    metric: 'hrv',
    label: '心率变异性',
    unit: 'ms',
    dataType: healthStore.samplePointHelper.heartRateVariability.DATA_TYPE,
    isSamplePoint: true,
    minApiLevel: 18
  },
  {
    metric: 'spo2',
    label: '血氧饱和度',
    unit: '%',
    dataType: healthStore.samplePointHelper.bloodOxygenSaturation.DATA_TYPE,
    isSamplePoint: true,
    minApiLevel: 12
  },
  {
    metric: 'stress',
    label: '压力得分',
    unit: 'score',
    dataType: healthStore.samplePointHelper.stress.DATA_TYPE,
    isSamplePoint: true,
    minApiLevel: 12
  },
  {
    metric: 'sleep',
    label: '睡眠',
    unit: null,
    dataType: healthStore.healthSequenceHelper.sleepRecord.DATA_TYPE,
    isSamplePoint: false,
    minApiLevel: 12
  }
];

/**
 * 某个指标需要的最低 API 版本（0 表示没有额外要求）。
 *
 * ⚠️ 同样刻意用 switch 而不是 Record 常量表，原因见 sourceLabel 的注释。
 */
export function metricMinApiLevel(metric: string): number {
  switch (metric) {
    case 'hrv':
      return 18;
    default:
      return 0;
  }
}

// ------------------------------------------------------------------ 协议信封

/**
 * ping 的载荷。
 * 单独声明接口是必须的：ArkTS 严格模式不允许把对象字面量直接赋给
 * 没有具名类型的字段（arkts-no-untyped-obj-literals）。
 */
export interface PingPayload {
  /** 上一次测得的往返时延；首次发送时为 null */
  rtt: number | null;
  /** 对端回 pong 时携带的原时间戳 */
  echo?: number;
}

/** pong 的载荷 */
export interface PongPayload {
  echo: number;
}

/** ack 的载荷（电脑确认收到上行消息） */
export interface AckPayload {
  ackSeq: number;
  accepted?: number;
  rejected?: number;
}

/** nack 的载荷（电脑拒绝上行消息） */
export interface NackPayload {
  reason: string;
  detail?: string;
}

/** 上行信封（手机 -> 电脑） */
export interface Envelope {
  v: number;
  type: string;
  seq: number;
  ts: number;
  deviceId: string;
  /**
   * 载荷。这里用 object 而不是联合类型，是为了让上下行都能共用同一个信封；
   * 但**赋值时不能写对象字面量**，必须先构造具名类型的变量再传进来
   * （ArkTS 的 arkts-no-untyped-obj-literals 规则）。
   */
  payload: object;
}

/** hello 的 payload */
export interface HelloPayload {
  protocol: number;
  model: string;
  osVersion: string;
  appVersion: string;
  collectIntervalMs: number;
  lastSeq: number;
  backgroundMode: string[];
  healthStoreReady: boolean;
  permissions: PermissionsPayload;
}

export interface PermissionsPayload {
  healthDataRead: boolean;
  internet: boolean;
  keepBackgroundRunning: boolean;
}

/** batch 的 payload */
export interface BatchPayload {
  samples: SamplePayload[];
  count: number;
  reason: string;
}

/** 电脑下发的 hello_ack 载荷（手机端解析后用于远程调参） */
export interface HelloAckPayload {
  serverTime: number;
  accepted: boolean;
  needBackfillFrom: number;
  collectIntervalMs: number;
  metrics: string[];
}

/** 采样记录（带信封，用于离线队列） */
export interface QueuedSample {
  seq: number;
  ts: number;
  deviceId: string;
  payload: SamplePayload;
}

// ------------------------------------------------------------------ 取值辅助

/** 把可能为 undefined/null/NaN 的值安全转成整数 */
export function optInt(value: number | undefined | null): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  return Math.round(value);
}

export function optNum(value: number | undefined | null): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  return value;
}

export function optStr(value: string | undefined | null): string | null {
  if (value === undefined || value === null || value.length === 0) return null;
  return value;
}

export function clampInt(value: number | undefined | null, min: number, max: number): number {
  const v = optInt(value);
  if (v === null) return min;
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

export function requiredNumber(value: number | undefined | null, fallback: number): number {
  if (value === undefined || value === null || !Number.isFinite(value)) return fallback;
  return Math.round(value);
}

// ------------------------------------------------------------------ 睡眠分期

/**
 * 睡眠分期状态的显示名。
 *
 * 取值按官方 `sleepStatus` 语义：
 *   0=未知 1=深睡 2=浅睡 3=REM 4=清醒 5=小睡 6=卧床 7=手动记录
 * （注意字段名是 `sleepStatus`，不是 `sleepState`）
 *
 * ⚠️ 用 switch 而非 Record 常量表，原因见 sourceLabel 的注释。
 */
export function sleepStatusLabel(status: number): string {
  switch (status) {
    case 0:
      return '未知';
    case 1:
      return '深睡';
    case 2:
      return '浅睡';
    case 3:
      return 'REM';
    case 4:
      return '清醒';
    case 5:
      return '小睡';
    case 6:
      return '卧床';
    case 7:
      return '手动记录';
    default:
      return `未知(${status})`;
  }
}
