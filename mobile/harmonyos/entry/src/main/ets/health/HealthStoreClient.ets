/**
 * HealthStoreClient —— 封装华为 Health Service Kit（@kit.HealthServiceKit）。
 *
 * 全部 API 用法均已对照本机 SDK 声明（D:\Downloads\DevEco Studio\sdk\default\hms\ets\api\
 * @hms.health.store.d.ts）与官方文档核实，关键点：
 *
 *   1. healthStore.init(context) 必须在所有其他 healthStore 调用之前 await 完成；
 *      context 只接受 UIAbility / UIExtensionAbility 的 context。
 *   2. 读健康数据**不需要**在 module.json5 声明 ohos.permission.HEALTH_DATA_READ
 *      （该权限名官方查无来源）。真实模型是"AGC 申请的数据权限 ∩ 运行时用户授权"，
 *      运行时授权走 requestAuthorizations()。
 *   3. 单次 readData 时间跨度不得超过 31 天（官方限制），本项目取 30 天保守值。
 *   4. 采样点查询用 startTime/endTime（startLocalDate/endLocalDate 已被 Omit）。
 *   5. samplePointDataType 传数组时不能同时传 fields。
 *   6. 数据类型常量：samplePointHelper.<type>.DATA_TYPE / healthSequenceHelper.<type>.DATA_TYPE。
 *   7. HealthSequence 的统计数据在 **summaries**（不是 fields），明细在 **details**，
 *      且明细读取用 readOptions（withDetails / withPartialDetails）。
 *   8. 各类型字段名：HeartRate.bpm、RestingHeartRate.restBpm、HeartRateVariability.heartRateVariabilityRMSSD、
 *      BloodOxygenSaturation.spo2、Stress.stressScore、BodyTemperature.bodyTemperature。
 */

import { healthStore } from '@kit.HealthServiceKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';
import { HealthSource, HealthSourceInitResult, HealthSourceStatus } from './HealthSource';
import {
  HealthMetric,
  SamplePayload,
  SleepPayload,
  SleepSegmentPayload,
  METRIC_METAS,
  MetricMeta,
  clampInt,
  optInt,
  optStr
} from '../model/HealthTypes';

const TAG = 'HealthStoreClient';

/** 单次查询最大跨度：官方限制 31 天，这里取 30 天留余量。 */
const MAX_QUERY_SPAN_MS = 30 * 24 * 60 * 60 * 1000;

/** 睡眠记录查询窗口：晚睡场景回溯 36 小时足够覆盖"昨晚"。 */
const SLEEP_LOOKBACK_MS = 36 * 60 * 60 * 1000;

/**
 * 可从 HealthStore 读到的采样点指标。
 * 注意与 HealthMetric 的区别：HealthMetric 是**协议层**的指标枚举（含 sleep 等
 * 复合记录），而这里是**华为采样点 API** 能读的那些。
 */
export type SampleMetric =
  | 'heart_rate'
  | 'resting_heart_rate'
  | 'hrv'
  | 'spo2'
  | 'stress'
  | 'body_temperature';

/** 重新导出，保持向后兼容（旧代码/文档里用的是这个名字） */
export type { HealthSourceInitResult as HealthStoreInitResult };

export interface AuthorizationResult {
  granted: HealthMetric[];
  denied: HealthMetric[];
  message: string;
}

export class HealthStoreClient implements HealthSource {
  readonly name: string = '华为 Health Service Kit';

  private inited: boolean = false;
  private initMessage: string = '未初始化';
  private grantedMetrics: HealthMetric[] = [];
  private running: boolean = false;
  private sampleHandler: ((payload: SamplePayload) => void) | null = null;
  private latest: Map<string, SamplePayload> = new Map();
  private lastDataAt: number = 0;
  private statusText: string = '未启动';

  /** @param context 只接受 UIAbility / UIExtensionAbility 的 context */
  async init(context?: object): Promise<HealthSourceInitResult> {
    if (this.inited) {
      return { ready: true, message: this.initMessage };
    }
    if (context === undefined || context === null) {
      this.initMessage = 'Health Service Kit 需要一个 UIAbility 的 context 才能初始化';
      Logger.warn(TAG, this.initMessage);
      return { ready: false, message: this.initMessage };
    }
    try {
      await healthStore.init(context as common.Context);
      this.inited = true;
      this.initMessage = 'Health Service Kit 初始化成功';
      Logger.info(TAG, this.initMessage);
    } catch (err) {
      const e = err as BusinessError;
      this.inited = false;
      this.initMessage = `初始化失败 code=${e.code} msg=${e.message}`;
      Logger.error(TAG, this.initMessage);
    }
    return { ready: this.inited, message: this.initMessage };
  }

  // ------------------------------------------------ HealthSource 接口实现

  async start(): Promise<HealthSourceInitResult> {
    if (!this.inited) {
      return { ready: false, message: '未初始化，无法开始采集' };
    }
    this.running = true;
    this.statusText = '采集中';
    return { ready: true, message: 'Health Service Kit 采集已启动' };
  }

  async stop(): Promise<void> {
    this.running = false;
    this.statusText = '已停止';
  }

  /** 让 CollectionService 能统一按接口使用 */
  syncOnce(): Promise<SamplePayload[]> {
    return this.readAllMetrics();
  }

  onSample(handler: (payload: SamplePayload) => void): void {
    this.sampleHandler = handler;
  }

  getStatus(): HealthSourceStatus {
    const metrics: HealthMetric[] = [];
    for (const key of this.latest.keys()) {
      metrics.push(key as HealthMetric);
    }
    return {
      stateText: this.statusText,
      deviceName: '',
      activeMetrics: metrics,
      lastDataAt: this.lastDataAt
    };
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * 读取全部指标一轮。
   * 这是原来的采集逻辑（逐个 readLatestSample + 单独读睡眠），只是改成了
   * "返回结果 + 通过 onSample 回调推送"的形式，以便和 BLE 数据源统一。
   */
  async readAllMetrics(): Promise<SamplePayload[]> {
    const out: SamplePayload[] = [];
    if (!this.inited) return out;

    const metrics: string[] = ['heart_rate', 'resting_heart_rate', 'hrv', 'spo2', 'stress'];
    for (const metric of metrics) {
      try {
        const payload = await this.readLatestSample(metric as SampleMetric);
        if (payload !== null) {
          out.push(payload);
          this.publish(payload);
        }
      } catch (err) {
        const e = err as BusinessError;
        Logger.warn(TAG, `读取 ${metric} 失败: ${e.message}`);
      }
    }

    try {
      const sleep = await this.readLatestSleep();
      if (sleep !== null) {
        const payload: SamplePayload = {
          metric: 'sleep',
          value: null,
          unit: null,
          startTime: sleep.fallAsleepTime,
          endTime: sleep.wakeupTime,
          source: 'healthStore',
          sleep: sleep
        };
        out.push(payload);
        this.publish(payload);
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `读取睡眠失败: ${e.message}`);
    }

    return out;
  }

  /** 记录最新值并按需回调 */
  private publish(payload: SamplePayload): void {
    this.latest.set(payload.metric, payload);
    this.lastDataAt = Date.now();
    if (this.running && this.sampleHandler !== null) {
      this.sampleHandler(payload);
    }
  }

  isReady(): boolean {
    return this.inited;
  }

  getInitMessage(): string {
    return this.initMessage;
  }

  /**
   * 请求健康数据读取授权（会弹用户授权框）。
   * 注意：这里能通过的前提是**已在 AGC 申请过对应数据权限**。
   */
  async requestAuthorizations(context: common.UIAbilityContext): Promise<AuthorizationResult> {
    if (!this.inited) {
      return { granted: [], denied: [], message: '未初始化，无法请求授权' };
    }
    try {
      const request: healthStore.AuthorizationRequest = {
        readDataTypes: buildDataTypeList(),
        writeDataTypes: []
      };
      const response: healthStore.AuthorizationResponse =
        await healthStore.requestAuthorizations(context, request);
      return this.collectResult(response.readDataTypes, '授权请求完成');
    } catch (err) {
      const e = err as BusinessError;
      const msg = `请求授权失败 code=${e.code} msg=${e.message}`;
      Logger.error(TAG, msg);
      return { granted: [], denied: [], message: msg };
    }
  }

  /** 只查询已有授权，不弹窗 */
  async getAuthorizations(): Promise<AuthorizationResult> {
    if (!this.inited) {
      return { granted: [], denied: [], message: '未初始化' };
    }
    try {
      const response = await healthStore.getAuthorizations({
        readDataTypes: buildDataTypeList(),
        writeDataTypes: []
      });
      return this.collectResult(response.readDataTypes, '查询授权完成');
    } catch (err) {
      const e = err as BusinessError;
      return { granted: [], denied: [], message: `查询授权失败 code=${e.code} msg=${e.message}` };
    }
  }

  private collectResult(readTypes: healthStore.DataType[], prefix: string): AuthorizationResult {
    const granted: HealthMetric[] = [];
    const denied: HealthMetric[] = [];
    for (const meta of METRIC_METAS) {
      if (containsType(readTypes, meta.dataType)) granted.push(meta.metric);
      else denied.push(meta.metric);
    }
    this.grantedMetrics = granted;
    const message = `${prefix}：通过 ${granted.length} 项，未通过 ${denied.length} 项`;
    Logger.info(TAG, message);
    return { granted, denied, message };
  }

  getGrantedMetrics(): HealthMetric[] {
    return this.grantedMetrics;
  }

  /**
   * 读取最近一条采样数据。
   * @param metric 指标
   * @param lookbackMs 向前回溯多久（默认 24 小时）
   * @returns 归一化 payload；无数据返回 null
   */
  async readLatestSample(metric: SampleMetric, lookbackMs: number = 24 * 60 * 60 * 1000): Promise<SamplePayload | null> {
    if (!this.inited) return null;
    const meta = findMeta(metric);
    if (!meta) return null;

    const now = Date.now();
    const span = Math.min(Math.max(lookbackMs, 60 * 1000), MAX_QUERY_SPAN_MS);
    try {
      const request: healthStore.SamplePointReadRequest = {
        samplePointDataType: meta.dataType,
        startTime: now - span,
        endTime: now,
        sortOrder: healthStore.SortOrder.DESC,
        count: 1
      };
      // 用具体 helper 模型做泛型参数，保证 fields 有明确属性名
      const rows = await healthStore.readData<healthStore.samplePointHelper.heartRate.Model>(request);
      if (!rows || rows.length === 0) return null;
      const row = rows[0];
      const value = readScalar(metric, row);
      if (value === null) return null;
      return {
        metric: meta.metric,
        value,
        unit: meta.unit,
        startTime: row.startTime,
        endTime: row.endTime,
        source: 'healthStore'
      };
    } catch (err) {
      const e = err as BusinessError;
      throw new Error(`读取 ${metric} 失败 code=${e.code} msg=${e.message}`);
    }
  }

  /**
   * 读取最近一条夜间睡眠记录。
   *
   * 官方字段是 **sleepStatus**（不是 sleepState），枚举 1=深睡 2=浅睡 3=REM 4=清醒
   * 5=小睡 6=卧床 7=手动记录 0=未知。
   * 新版 healthFields.Sleep **没有** snoreFreq / avgHeartRate / avgOxygenSaturation /
   * avgBreathRate / avgHrv，这五项要作为独立数据类型另行读取后按时间窗对齐。
   */
  async readLatestSleep(): Promise<SleepPayload | null> {
    if (!this.inited) return null;
    const now = Date.now();
    try {
      const request: healthStore.HealthSequenceReadRequest<healthStore.healthFields.SleepDetail> = {
        healthSequenceDataType: healthStore.healthSequenceHelper.sleepRecord.DATA_TYPE,
        startTime: now - SLEEP_LOOKBACK_MS,
        endTime: now,
        sortOrder: healthStore.SortOrder.DESC,
        count: 1,
        readOptions: { withDetails: true }
      };
      const rows = await healthStore.readData<healthStore.healthSequenceHelper.sleepRecord.Model>(request);
      if (!rows || rows.length === 0) return null;
      return mapSleep(rows[0]);
    } catch (err) {
      const e = err as BusinessError;
      throw new Error(`读取睡眠失败 code=${e.code} msg=${e.message}`);
    }
  }

  /**
   * 读取指定时间窗内的心率序列（用于给睡眠记录做"平均心率"这类关联统计）。
   * 官方 sleep 字段里没有 avgHeartRate，所以只能这样算。
   * @returns 平均值；窗口内无数据返回 null
   */
  async readAverageHeartRate(startTime: number, endTime: number): Promise<number | null> {
    if (!this.inited) return null;
    const span = Math.min(endTime - startTime, MAX_QUERY_SPAN_MS);
    if (span <= 0) return null;
    try {
      const request: healthStore.SamplePointReadRequest = {
        samplePointDataType: healthStore.samplePointHelper.heartRate.DATA_TYPE,
        startTime: startTime,
        endTime: startTime + span,
        sortOrder: healthStore.SortOrder.ASC
      };
      const rows = await healthStore.readData<healthStore.samplePointHelper.heartRate.Model>(request);
      if (!rows || rows.length === 0) return null;
      let sum = 0;
      let n = 0;
      for (const row of rows) {
        const bpm = optInt(row.fields.bpm);
        if (bpm !== null && bpm > 0) {
          sum += bpm;
          n++;
        }
      }
      return n === 0 ? null : Math.round(sum / n);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `读取睡眠窗口平均心率失败 code=${e.code}`);
      return null;
    }
  }
}

// ------------------------------------------------------------------ 辅助函数

function buildDataTypeList(): healthStore.DataType[] {
  const list: healthStore.DataType[] = [];
  for (const meta of METRIC_METAS) {
    list.push(meta.dataType);
  }
  return list;
}

function findMeta(metric: HealthMetric): MetricMeta | null {
  for (const meta of METRIC_METAS) {
    if (meta.metric === metric) return meta;
  }
  return null;
}

/** DataType 是对象而非枚举值，只能用引用相等判断 */
function containsType(list: healthStore.DataType[], target: healthStore.DataType): boolean {
  if (!list) return false;
  for (const item of list) {
    if (item === target) return true;
  }
  return false;
}

/**
 * 从采样点 fields 里取标量。
 * 不同指标的字段名不同，这里显式分别取，避免依赖 Record 索引签名。
 */
function readScalar(metric: SampleMetric, row: healthStore.samplePointHelper.heartRate.Model): number | null {
  const fields = row.fields as Record<string, number>;
  if (!fields) return null;
  const raw = fields[fieldNameOf(metric)];
  return optInt(raw);
}

function fieldNameOf(metric: SampleMetric): string {
  switch (metric) {
    case 'heart_rate':
      return 'bpm';
    case 'resting_heart_rate':
      return 'restBpm';
    case 'hrv':
      return 'heartRateVariabilityRMSSD';
    case 'spo2':
      return 'spo2';
    case 'stress':
      return 'stressScore';
    case 'body_temperature':
      return 'bodyTemperature';
    default:
      return 'bpm';
  }
}

/** 把 HealthSequence<Sleep, SleepDetail> 映射成协议里的 sleep payload */
function mapSleep(row: healthStore.healthSequenceHelper.sleepRecord.Model): SleepPayload {
  const s = row.summaries;
  const payload: SleepPayload = {
    fallAsleepTime: Math.round(s.fallAsleepTime || row.startTime),
    wakeupTime: Math.round(s.wakeupTime || row.endTime),
    duration: Math.round(s.duration || 0),
    sleepScore: optInt(s.sleepScore),
    sleepEfficiency: optInt(s.sleepEfficiency),
    deepSleepContinuity: optInt(s.deepSleepContinuity),
    respiratoryQualityScore: optInt(s.respiratoryQualityScore),
    deepDuration: optInt(s.deepDuration),
    shallowDuration: optInt(s.shallowDuration),
    dreamDuration: optInt(s.dreamDuration),
    wakeDuration: optInt(s.wakeDuration),
    wakeCount: optInt(s.wakeCount),
    turnOverCount: optInt(s.turnOverCount),
    onBedDuration: optInt(s.onBedDuration),
    recordDuration: optInt(s.recordDuration),
    sleepType: optInt(s.sleepType),
    sleepEndReason: optInt(s.sleepEndReason),
    sleepSymptoms: optStr(s.sleepSymptoms)
  };

  const segments: SleepSegmentPayload[] = [];
  const details = row.details;
  if (details && details.sleepSegment) {
    for (const seg of details.sleepSegment) {
      const start = Math.round(seg.startTime || 0);
      const end = Math.round(seg.endTime || start);
      segments.push({
        startTime: start,
        endTime: end,
        // 官方取值 0-7，原样透传，不做有损映射
        sleepStatus: clampInt(seg.sleepStatus, 0, 7)
      });
    }
  }
  if (segments.length > 0) payload.sleepSegment = segments;
  return payload;
}
