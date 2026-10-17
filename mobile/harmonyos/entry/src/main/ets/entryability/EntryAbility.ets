/**
 * EntryAbility —— 应用入口。
 *
 * 重要：Stage 模型下**只有 UIAbility 能申请长时任务**，所以采集服务必须拿到
 * 这里的 this.context。同时 HealthStore.init() 也只接受 UIAbility / UIExtensionAbility
 * 的 context，所以初始化也放在这里。
 */

import { AbilityConstant, UIAbility, Want, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';

import { Logger } from '../common/Logger';
import { AppPrefs, KEYS } from '../common/Prefs';
import { CollectionService } from '../service/CollectionService';
import { detectPreloadType } from './MyAbilityStage';

const TAG = 'EntryAbility';

/** 需要动态申请的权限（均为 normal 等级，普通应用可直接申请） */
const RUNTIME_PERMISSIONS: Permissions[] = [
  'ohos.permission.INTERNET',
  'ohos.permission.GET_NETWORK_INFO',
  'ohos.permission.KEEP_BACKGROUND_RUNNING',
  // BLE 直连需要的权限。华为要求：使用蓝牙须声明对应的**开放权限**
  // （ACCESS_BLUETOOTH），同时按需声明系统授权权限（USE_/DISCOVER_）。
  // 这三条都已在 module.json5 里声明。
  'ohos.permission.ACCESS_BLUETOOTH'
];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const preload = detectPreloadType();
    Logger.info(TAG, `onCreate，启动原因=${launchParam.launchReason}，预加载=${preload.label}`);
    if (launchParam.launchReason === AbilityConstant.LaunchReason.PRELOAD) {
      Logger.info(TAG, '本次由预加载拉起，直接复用已就绪的进程');
    }
    Logger.info(TAG, 'HealthLink 采集端启动');
  }

  onDestroy(): void {
    const service = CollectionService.getInstance();
    service.stop().catch((e: Error) => {
      Logger.warn(TAG, `onDestroy 停止采集失败: ${e.message}`);
    });
    Logger.info(TAG, 'EntryAbility 已销毁');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 主窗口加载完成后立刻做重活初始化，避免阻塞首帧
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(TAG, `加载首页失败 code=${err.code} msg=${err.message}`);
        return;
      }
      Logger.info(TAG, '首页已加载');
      this.bootstrapService().catch((e: Error) => {
        Logger.error(TAG, `服务初始化失败: ${e.message}`);
      });
    });
  }

  onWindowStageDestroy(): void {
    Logger.info(TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info(TAG, 'onForeground（回到前台）');
  }

  onBackground(): void {
    // 官方：应用退后台超 3 秒即被系统挂起并冻结软硬件资源。
    // 长时任务就是用来突破这个限制的，所以这里只提示，不停止采集。
    const service = CollectionService.getInstance();
    if (service.isRunning()) {
      Logger.info(TAG, 'onBackground：采集继续（依赖长时任务保活）');
    } else {
      Logger.warn(TAG, 'onBackground：采集未启动，进程很快会被系统挂起');
    }
  }

  /** 初始化偏好存储 → HealthStore → 采集服务 → 若用户开启自动启动则拉起 */
  private async bootstrapService(): Promise<void> {
    await AppPrefs.init(this.context);
    await this.requestRuntimePermissions();

    const service = CollectionService.getInstance();
    service.setAbilityContext(this.context);

    // 恢复上次填写的电脑地址
    const savedUrl = AppPrefs.getString(KEYS.serverUrl, '');
    if (savedUrl.length > 0) {
      service.getTransport().setUrl(savedUrl);
      Logger.info(TAG, `已恢复电脑地址 ${savedUrl}`);
    }

    await service.bootstrap();

    // 首次启动给一个默认值，方便对照电脑端启动日志
    if (AppPrefs.getNumber(KEYS.collectIntervalMs, 0) === 0) {
      await AppPrefs.put(KEYS.collectIntervalMs, 60000);
    }

    if (AppPrefs.getBool(KEYS.autoStart, false) && savedUrl.length > 0) {
      Logger.info(TAG, '自动启动已开启，正在拉起采集');
      await service.start();
    }
  }

  /**
   * 动态申请权限。
   * 注意：这三个都是 normal / system_grant 权限，通常无需弹窗即可获得；
   * 健康数据读取权限不在这里——它走 HealthStore 的 OAuth 授权流程
   * （见 HealthStoreClient.requestAuthorizations）。
   */
  private async requestRuntimePermissions(): Promise<void> {
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const tokenId = bundleInfo.appInfo.accessTokenId;
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(this.context, RUNTIME_PERMISSIONS);
      const denied: string[] = [];
      for (let i = 0; i < result.permissions.length; i++) {
        if (result.authResults[i] !== 0) {
          denied.push(result.permissions[i]);
        }
      }
      if (denied.length > 0) {
        Logger.warn(TAG, `以下权限被拒绝: ${denied.join(', ')}。没有 INTERNET 权限时无法上传数据。`);
      } else {
        Logger.info(TAG, `运行时权限已就绪（tokenId=${tokenId}）`);
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `申请运行时权限失败 code=${e.code} msg=${e.message}`);
    }
  }
}
