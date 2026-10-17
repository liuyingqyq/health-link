/**
 * 统一日志封装。
 * 用 hilog 输出，同时保留最近 N 条在内存里给 UI 显示（真机上没法方便地看 hilog）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0A61;
const APP_TAG: string = 'HealthLink';
const RING_SIZE: number = 200;

export interface LogLine {
  ts: number;
  level: string;
  tag: string;
  message: string;
}

export class Logger {
  private static ring: LogLine[] = [];

  private static push(level: string, tag: string, message: string): void {
    Logger.ring.push({ ts: Date.now(), level, tag, message });
    if (Logger.ring.length > RING_SIZE) {
      Logger.ring.shift();
    }
  }

  static debug(tag: string, message: string): void {
    hilog.debug(DOMAIN, APP_TAG, '[%{public}s] %{public}s', tag, message);
    Logger.push('D', tag, message);
  }

  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, APP_TAG, '[%{public}s] %{public}s', tag, message);
    Logger.push('I', tag, message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, APP_TAG, '[%{public}s] %{public}s', tag, message);
    Logger.push('W', tag, message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, APP_TAG, '[%{public}s] %{public}s', tag, message);
    Logger.push('E', tag, message);
  }

  /** 倒序返回最近日志（最新的在前），供 UI 展示 */
  static recent(limit: number = 50): LogLine[] {
    const out: LogLine[] = [];
    const start = Math.max(0, Logger.ring.length - limit);
    for (let i = Logger.ring.length - 1; i >= start; i--) {
      out.push(Logger.ring[i]);
    }
    return out;
  }

  static clear(): void {
    Logger.ring = [];
  }
}
