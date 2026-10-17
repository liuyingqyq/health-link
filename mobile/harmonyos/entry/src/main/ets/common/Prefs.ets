/**
 * 轻量键值存储封装（基于 @ohos.data.preferences）。
 *
 * 为什么不用 AppStorage：AppStorage 是内存态，进程被杀就丢，
 * 而"电脑地址 / 设备 ID / 采集周期"必须跨进程重启保留。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from './Logger';

const TAG = 'AppPrefs';
const STORE_NAME = 'healthlink_prefs';

export class AppPrefs {
  private static store: preferences.Preferences | null = null;

  static async init(context: common.Context): Promise<void> {
    if (AppPrefs.store !== null) return;
    try {
      AppPrefs.store = await preferences.getPreferences(context, STORE_NAME);
      Logger.info(TAG, '偏好存储已就绪');
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `偏好存储初始化失败 code=${e.code} msg=${e.message}`);
    }
  }

  static getString(key: string, defValue: string): string {
    if (AppPrefs.store === null) return defValue;
    try {
      const value = AppPrefs.store.getSync(key, defValue) as string;
      return value === undefined || value === null ? defValue : value;
    } catch (err) {
      Logger.warn(TAG, `读取 ${key} 失败`);
      return defValue;
    }
  }

  static getNumber(key: string, defValue: number): number {
    if (AppPrefs.store === null) return defValue;
    try {
      const value = AppPrefs.store.getSync(key, defValue) as number;
      return Number.isFinite(value) ? value : defValue;
    } catch (err) {
      Logger.warn(TAG, `读取 ${key} 失败`);
      return defValue;
    }
  }

  static getBool(key: string, defValue: boolean): boolean {
    if (AppPrefs.store === null) return defValue;
    try {
      const value = AppPrefs.store.getSync(key, defValue) as boolean;
      return typeof value === 'boolean' ? value : defValue;
    } catch (err) {
      Logger.warn(TAG, `读取 ${key} 失败`);
      return defValue;
    }
  }

  static async put(key: string, value: string | number | boolean): Promise<void> {
    if (AppPrefs.store === null) {
      Logger.warn(TAG, `偏好存储未初始化，${key} 只保存在内存中`);
      return;
    }
    try {
      AppPrefs.store.putSync(key, value);
      await AppPrefs.store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `写入 ${key} 失败 code=${e.code} msg=${e.message}`);
    }
  }

  /** 清空（调试用） */
  static async clear(): Promise<void> {
    if (AppPrefs.store === null) return;
    try {
      AppPrefs.store.clearSync();
      await AppPrefs.store.flush();
      Logger.info(TAG, '偏好存储已清空');
    } catch (err) {
      Logger.error(TAG, '清空偏好存储失败');
    }
  }
}

/**
 * 配置键的类型声明。
 * ArkTS 严格模式要求对象字面量必须对应**具名**的类或接口
 * （arkts-no-untyped-obj-literals），所以这里必须先声明接口。
 */
export interface PrefKeys {
  serverUrl: string;
  deviceId: string;
  seq: string;
  collectIntervalMs: string;
  autoStart: string;
  healthyOnly: string;
  backgroundMode: string;
  lastConnectedAt: string;
  sourceKind: string;
  bleDeviceId: string;
  bleDeviceName: string;
}

/** 配置键集中定义，避免拼写错误散落各处 */
export const KEYS: PrefKeys = {
  serverUrl: 'server_url',
  deviceId: 'device_id',
  seq: 'last_seq',
  collectIntervalMs: 'collect_interval_ms',
  autoStart: 'auto_start',
  healthyOnly: 'healthy_only',
  backgroundMode: 'background_mode',
  lastConnectedAt: 'last_connected_at',
  /** 数据源种类：'ble' | 'healthStore'（默认 ble，不需要华为审批） */
  sourceKind: 'source_kind',
  /** BLE 上次连接的设备，方便重连时提示 */
  bleDeviceId: 'ble_device_id',
  bleDeviceName: 'ble_device_name'
};
