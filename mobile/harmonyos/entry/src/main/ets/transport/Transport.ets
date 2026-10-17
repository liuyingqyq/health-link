/**
 * 传输层。
 *
 * 这里刻意把"怎么把信封发出去"抽象出来，业务层（采集、队列、协议）完全不认识
 * WebSocket。日后要换成公网中继，只需要再写一个实现 Transport 接口的类，
 * 业务代码一行都不用改（见 docs/protocol/README.md 第 6 节）。
 */

import { Envelope } from '../model/HealthTypes';

export type TransportState = 'idle' | 'connecting' | 'open' | 'closed';

export interface TransportEvents {
  /** 连接建立 */
  onOpen?: () => void;
  /** 连接断开 */
  onClose?: (code: number, reason: string) => void;
  /** 收到一条下行信封（已 JSON.parse） */
  onMessage?: (envelope: Envelope) => void;
  /** 发生错误（不一定断开） */
  onError?: (message: string) => void;
  /** 状态变化，用于刷新 UI */
  onStateChange?: (state: TransportState) => void;
}

export interface Transport {
  readonly state: TransportState;
  connect(): Promise<void>;
  send(envelope: Envelope): Promise<void>;
  close(): void;
  setEvents(events: TransportEvents): void;
}
