/**
 * 健康数据源抽象。
 *
 * 这是本项目能"换数据源不动其他代码"的关键：
 *   CollectionService（采集编排 / 长时任务 / 离线队列 / 断线补传）
 *   只认这个接口，不认识具体是读华为 Health Kit 还是读 BLE 外设。
 *
 * 现有两个实现：
 *   · BleHealthSource      —— BLE GATT 直连，无需华为审批（当前默认）
 *   · HealthStoreClient    —— 华为 Health Service Kit，需 AGC 资质审核
 *
 * 将来再加数据源（手机传感器、手动录入）只要再实现一次本接口。
 */

import { HealthMetric, SamplePayload } from '../model/HealthTypes';

export interface HealthSourceInitResult {
  ready: boolean;
  message: string;
}

/** 数据源运行状态，给 UI 展示用 */
export interface HealthSourceStatus {
  /** 数据源自身的连接/就绪状态文字 */
  stateText: string;
  /** 已连上的设备名（BLE 用） */
  deviceName: string;
  /** 正在采集哪些指标 */
  activeMetrics: HealthMetric[];
  /** 最近一次收到数据的时间 */
  lastDataAt: number;
}

export interface HealthSource {
  /** 数据源名字，UI 上显示 */
  readonly name: string;

  /**
   * 初始化。
   * @param context UIAbility 的 context（HealthKit 需要，BLE 用不到）
   */
  init(context?: object): Promise<HealthSourceInitResult>;

  isReady(): boolean;

  getInitMessage(): string;

  /**
   * 开始采集。
   * 实现方在这里建立自己的连接（BLE 连接设备 / Kit 初始化授权等）。
   */
  start(): Promise<HealthSourceInitResult>;

  /** 停止采集并释放资源 */
  stop(): Promise<void>;

  /** 立刻采一轮（手动同步按钮用） */
  syncOnce(): Promise<SamplePayload[]>;

  /** 注册数据回调；每产生一条 payload 就调一次 */
  onSample(handler: (payload: SamplePayload) => void): void;

  /** 数据源状态 */
  getStatus(): HealthSourceStatus;

  /** 数据源是否正在采集 */
  isRunning(): boolean;
}
