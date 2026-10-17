/**
 * 长时任务（Continuous Task）管理。
 *
 * 官方依据（已核实）：
 *   - 权限：ohos.permission.KEEP_BACKGROUND_RUNNING，等级 normal，普通应用可直接申请
 *   - Stage 模型下**只有 UIAbility 能申请**长时任务
 *   - module.json5 必须同时在 abilities[].backgroundModes 声明对应配置项字符串
 *   - 申请成功后系统会在通知栏常驻显示，**用户删掉通知 = 系统自动停止长时任务**
 *   - DATA_TRANSFER 类型要求持续更新进度，**超过 10 分钟不更新会被系统取消**
 *   - ★ 你给的参考代码里的 ContinuousTaskExtensionAbility **官方查无此 API**，
 *     Stage 模型也不支持它，因此本项目不使用。
 *
 * 本项目的模式选择：
 *   主模式用 **BLUETOOTH_INTERACTION**（健康数据来自蓝牙穿戴设备，场景最匹配，
 *   且没有 10 分钟进度续期的硬要求）；同时叠加 DATA_TRANSFER，因为要持续上传数据。
 *   两种模式都通过 API 12 起的字符串数组重载一次性申请。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';

const TAG = 'ContinuousTask';

/** 通知 ID，需与 UI 展示一致 */
const NOTIFICATION_ID: number = 1001;

/** DATA_TRANSFER 续期周期。官方要求 < 10 分钟，这里取 5 分钟留足余量。 */
const PROGRESS_UPDATE_MS: number = 5 * 60 * 1000;

export type BackgroundModeName = 'bluetoothInteraction' | 'dataTransfer';

export interface ContinuousTaskState {
  running: boolean;
  modes: string[];
  startedAt: number;
  lastUpdateAt: number;
  lastError: string;
}

export class ContinuousTaskManager {
  private context: common.UIAbilityContext | null = null;
  private running: boolean = false;
  private modes: string[] = [];
  private startedAt: number = 0;
  private lastUpdateAt: number = 0;
  private lastError: string = '';
  private progressTimer: number = -1;
  private progressTick: number = 0;

  /** 必须在 UIAbility 里传入 this.context */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  getState(): ContinuousTaskState {
    return {
      running: this.running,
      modes: this.modes,
      startedAt: this.startedAt,
      lastUpdateAt: this.lastUpdateAt,
      lastError: this.lastError
    };
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * 申请长时任务。
   * @param modes 需要申请的模式；默认 ["bluetoothInteraction", "dataTransfer"]
   */
  async start(modes: string[] = ['bluetoothInteraction', 'dataTransfer']): Promise<ContinuousTaskState> {
    if (this.context === null) {
      this.lastError = '未设置 UIAbilityContext，无法申请长时任务';
      Logger.error(TAG, this.lastError);
      return this.getState();
    }
    if (this.running) {
      Logger.info(TAG, '长时任务已在运行，跳过重复申请');
      return this.getState();
    }

    try {
      // 1) 构造点击通知要拉起的页面
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);

      // 2) 申请长时任务（API 12+ 的字符串数组重载，一次申请多个模式）
      await backgroundTaskManager.startBackgroundRunning(this.context, modes, agent);

      this.running = true;
      this.modes = modes;
      this.startedAt = Date.now();
      this.lastUpdateAt = Date.now();
      this.lastError = '';
      Logger.info(TAG, `长时任务已启动，模式=[${modes.join(', ')}]`);

      // 3) 发一条常驻通知。注意：用户手动删除该通知会导致系统停止长时任务。
      await this.publishNotification('正在采集并上传健康数据');

      // 4) DATA_TRANSFER 需要定期更新进度，否则 10 分钟后被取消
      if (modes.indexOf('dataTransfer') >= 0) {
        this.startProgressTimer();
      }
    } catch (err) {
      const e = err as BusinessError;
      this.running = false;
      this.lastError = `申请长时任务失败 code=${e.code} msg=${e.message}`;
      Logger.error(TAG, this.lastError);
      this.explainFailure(e.code);
    }
    return this.getState();
  }

  /** 结束长时任务 */
  async stop(): Promise<ContinuousTaskState> {
    this.stopProgressTimer();
    if (this.context === null || !this.running) {
      this.running = false;
      return this.getState();
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      Logger.info(TAG, '长时任务已停止');
    } catch (err) {
      const e = err as BusinessError;
      this.lastError = `停止长时任务失败 code=${e.code} msg=${e.message}`;
      Logger.error(TAG, this.lastError);
    }
    this.running = false;
    this.modes = [];
    await this.cancelNotification();
    return this.getState();
  }

  /**
   * 手动刷新一次通知进度。
   * 采集循环每轮都可调用，保证 DATA_TRANSFER 不会被判超时取消。
   */
  async updateProgress(detail: string): Promise<void> {
    this.lastUpdateAt = Date.now();
    if (!this.running) return;
    await this.publishNotification(detail);
  }

  private startProgressTimer(): void {
    this.stopProgressTimer();
    this.progressTimer = setInterval(() => {
      this.progressTick++;
      this.updateProgress(`后台采集进行中（已续期 ${this.progressTick} 次）`).catch(() => {
        Logger.warn(TAG, '通知进度续期失败');
      });
    }, PROGRESS_UPDATE_MS);
  }

  private stopProgressTimer(): void {
    if (this.progressTimer !== -1) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  private async publishNotification(text: string): Promise<void> {
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        Logger.warn(TAG, '通知未开启。长时任务的通知不可隐藏，用户删除通知会导致任务被系统停止，请在系统设置里允许通知。');
        return;
      }
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'HealthLink 正在后台运行',
            text: text,
            additionalText: '请勿删除本通知，删除后系统会停止后台采集'
          }
        },
        // 常驻、不可滑动删除（部分设备仍允许，系统行为以官方文档为准）
        isOngoing: true,
        isUnremovable: true,
        tapDismissed: false,
        // ⚠️ 这里刻意**不设置 slotType**，原因是华为 SDK 自身的不一致（编译器实测）：
        //     · notificationManager.NotificationRequest.slotType 的类型是
        //       `notification.SlotType`（@ohos.notification），而该枚举已标注
        //       `@deprecated since 9`，@useinstead 指向 notificationManager#SlotType
        //     · 但 slotType 的声明仍然引用那个**已废弃**的枚举，所以写
        //       `notificationManager.SlotType.SERVICE_INFORMATION` 会报
        //       10505001 "Type 'SlotType.SERVICE_INFORMATION' is not assignable to type 'SlotType'"
        //     slotType 是可选字段，不设置时系统会按通知类型自动分配，
        //     对长时任务的常驻通知没有影响。
        //     如果将来 SDK 修好了这个不一致，再按需补上。
        wantAgent: await this.buildNotificationAgent()
      };
      await notificationManager.publish(request);
      this.lastUpdateAt = Date.now();
    } catch (err) {
      const e = err as BusinessError;
      // 通知失败不应该中断采集：长时任务本身已经申请成功
      Logger.warn(TAG, `发布常驻通知失败 code=${e.code} msg=${e.message}`);
    }
  }

  private async buildNotificationAgent(): Promise<WantAgent | undefined> {
    if (this.context === null) return undefined;
    try {
      return await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (err) {
      return undefined;
    }
  }

  private async cancelNotification(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFICATION_ID);
    } catch (err) {
      // 通知本来就不存在时会报错，忽略
    }
  }

  /** 把错误码翻译成用户能看懂的话 */
  private explainFailure(code: number): void {
    let hint = '';
    if (code === 201) {
      hint = '缺少 ohos.permission.KEEP_BACKGROUND_RUNNING 权限，或 module.json5 的 backgroundModes 未声明对应模式';
    } else if (code === 202) {
      hint = '非系统应用不允许该操作';
    } else if (code === 401) {
      hint = '参数错误：context 必须是 UIAbility 的 context';
    } else if (code >= 9800001 && code <= 9800007) {
      hint = '长时任务相关错误（数量超限 / 类型不支持 / 已被取消等）';
    }
    if (hint.length > 0) {
      Logger.error(TAG, `可能原因：${hint}`);
    }
  }
}
