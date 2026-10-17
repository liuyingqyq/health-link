/**
 * AbilityStage —— 应用预加载检测点。
 *
 * 官方依据（已核实）：
 *   - application.getAppPreloadType() 起始 API 22（不是 12），
 *     SystemCapability.Ability.AbilityRuntime.Core
 *   - 只有在**首次执行 AbilityStage.onCreate 完成之前**调用该接口才能拿到真实类型；
 *     AbilityStage 创建完成后预加载数据会被清除，之后调用只返回 UNSPECIFIED
 *   - 应用预加载从 API 20 起、**仅 2in1 设备**、**仅 entry 模块**生效，是否预加载由系统决定
 *
 * 对数据采集的影响：被预加载时进程已经起来了，AbilityStage.onCreate 里就可以把
 * 偏好存储这类"冷启动开销"提前做掉，用户点开时采集服务能更快就绪。
 */

import { AbilityStage, application, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';
import { AppPrefs } from '../common/Prefs';

const TAG = 'MyAbilityStage';

export interface PreloadInfo {
  type: number;
  label: string;
  /** 是否由预加载触发 */
  preloaded: boolean;
}

export default class MyAbilityStage extends AbilityStage {
  private preloadInfo: PreloadInfo = { type: 0, label: '未预加载', preloaded: false };

  onCreate(): void {
    // ★ 必须在这里调用，晚一点就只能拿到 UNSPECIFIED
    this.preloadInfo = detectPreloadType();
    Logger.info(TAG, `AbilityStage.onCreate，预加载类型=${this.preloadInfo.label}`);

    // 预加载路径下提前把偏好存储准备好，省掉用户点开后的等待
    const context = this.context as common.Context;
    AppPrefs.init(context)
      .then(() => {
        Logger.info(TAG, '偏好存储已提前初始化完成');
      })
      .catch((e: Error) => {
        Logger.warn(TAG, `偏好存储初始化失败: ${e.message}`);
      });

    if (this.preloadInfo.preloaded) {
      Logger.info(TAG, '本次由系统预加载触发，采集服务可以更快就绪');
    }
  }
}

/**
 * 读取预加载类型。
 * 注意：API < 22 时该接口不存在，必须用 try/catch 兜住，
 * 否则在低版本设备上会直接抛错导致 stage 创建失败。
 */
export function detectPreloadType(): PreloadInfo {
  try {
    const type = application.getAppPreloadType();
    return { type: type, label: describePreloadType(type), preloaded: type !== application.AppPreloadType.UNSPECIFIED };
  } catch (err) {
    const e = err as BusinessError;
    // 低版本设备上这是预期行为，不当作错误
    Logger.info(TAG, `getAppPreloadType 不可用（需 API 22+）code=${e.code}`);
    return { type: -1, label: '当前系统不支持预加载查询', preloaded: false };
  }
}

function describePreloadType(type: number): string {
  switch (type) {
    case application.AppPreloadType.UNSPECIFIED:
      return '未预加载（或预加载数据已清除）';
    case application.AppPreloadType.TYPE_CREATE_PROCESS:
      return '预加载到进程创建完成';
    case application.AppPreloadType.TYPE_CREATE_ABILITY_STAGE:
      return '预加载到 AbilityStage 创建完成';
    case application.AppPreloadType.TYPE_CREATE_WINDOW_STAGE:
      return '预加载到 WindowStage 创建完成';
    case application.AppPreloadType.TYPE_CREATE_BACKGROUND_ABILITY:
      return '预加载到 onBackground 执行完成';
    default:
      return `未知类型 ${type}`;
  }
}
