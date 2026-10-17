# HealthLink 传输协议 v1（冻结版）

> 本文件是**契约**：手机端、电脑端、下游消费者三方都必须遵守。
> 任何一方要改字段，必须先改本文件并把 `version` 升到 `1.x`。

---

## 0. 为什么是「手机连电脑」而不是「电脑连手机」

华为 HarmonyOS 的应用沙箱不允许电脑主动连接手机上的 App（没有可监听的公网端口、
也不允许应用在后台长时间监听入站连接）。因此**链路方向固定为：手机主动外连，
电脑被动监听**。电脑端要「实时更新」，靠的是手机端的长连接 + 电脑端的长时运行，
而不是电脑去轮询手机。

```
┌──────────────┐   ① 主动外连（WebSocket，长连接常驻）
│  HarmonyOS   │ ───────────────────────────────────────┐
│  手机 App    │   ③ 断线自动重连 + 离线补传（seq 续传） │
└──────────────┘                                        ▼
                                              ┌────────────────────┐
                                              │  电脑端 HealthLink  │
                                              │  Hub（接收 + 中继） │
                                              └─────────┬──────────┘
                                                        │ ② 实时推送（WebSocket）
                                                        │    + 按 seq 重放
                                                        ▼
                                              ┌────────────────────┐
                                              │ 下游订阅者/其他人   │
                                              │ 浏览器面板 / 程序   │
                                              └────────────────────┘
```

---

## 1. 传输层

* 协议：**WebSocket**（RFC 6455），文本帧，**每帧一条 JSON 消息**（不是 JSON Lines 文件流）。
* 手机 → 电脑：`ws://<电脑IP>:<port>/ingest?token=<设备令牌>`
* 下游 → 电脑：`ws://<电脑IP>:<port>/subscribe?token=<订阅令牌>&topic=health&since=<seq>`
* 浏览器面板：`http://<电脑IP>:<port>/`

### 1.1 为什么不用 MQTT / HTTP 轮询

| 方案 | 结论 |
| --- | --- |
| HTTP 轮询 | 手机端退后台后无法被定时唤醒，实时性差，且耗电。**不采用**。 |
| MQTT | 需要一个 Broker。局域网内多一个部署环节，收益为 0。**不采用**（但传输层已抽象，见第 6 节）。 |
| 裸 TCP + 自定义帧 | 省不了多少字节，却要自己处理分片、心跳、粘包。**不采用**。 |
| WebSocket | 手机与浏览器都原生支持，自带 ping/pong 心跳，一条连接双向。**采用**。 |

---

## 2. 消息信封（Envelope）

所有消息都是同一个信封结构：

```jsonc
{
  "v": 1,               // 协议版本，整数，当前固定 1
  "type": "sample",     // 消息类型，见第 3 / 4 节
  "seq": 1024,          // 单调递增序号，从 1 开始；由发送方维护
  "ts": 1730000000000,  // 发送方产生该消息的 Unix 毫秒时间戳
  "deviceId": "a1b2c3d4e5f60718",  // 设备稳定标识（见 2.1）
  "payload": { }        // 类型相关内容
}
```

* 字段缺失、`v != 1`、`type` 未知 → 接收方回 `nack`，**不得**静默丢弃。
* 未知的**额外**字段必须被忽略（向前兼容），不得因此报错。

### 2.1 deviceId 怎么来

手机端**不能**用 `Settings.Secure.ANDROID_ID`（那是 Android 的东西）。
HarmonyOS 上按以下优先级取值：

1. 应用自己持久化的随机 ID（首次启动生成 `crypto` 16 字节随机数 → hex），存在
   `preferences` 里。**这是默认且推荐的做法**：无需任何权限，卸载重装才会变。
2. 可选：`deviceInfo.udid`（需要 `ohos.permission.APP_TRACKING_CONSENT`，属于敏感权限，
   本项目**默认不申请**）。

> 结论：`deviceId` = 16 字节随机数的 hex 字符串（32 个小写十六进制字符）。

---

## 3. 上行（手机 → 电脑）

### 3.1 `hello` — 连接建立后第一条

```jsonc
{
  "v": 1, "type": "hello", "seq": 1, "ts": 1730000000000,
  "deviceId": "a1b2c3d4e5f60718",
  "payload": {
    "protocol": 1,
    "model": "HUAWEI Mate 60 Pro",
    "osVersion": "HarmonyOS 6.0.0",
    "appVersion": "1.0.0",
    "collectIntervalMs": 60000,     // 当前采集周期
    "lastSeq": 1023,                // 断电前已发出的最大 seq，电脑据此判断是否需要补传
    "backgroundMode": ["bluetoothInteraction", "dataTransfer"],
    "healthStoreReady": true,       // healthStore.init() 是否成功
    "permissions": { "healthDataRead": true }
  }
}
```

* 手机必须在 `hello` 之后才开始发 `sample`。
* 电脑收到 `hello` 后回 `hello_ack`（见 4.1）。

### 3.2 `sample` — 一次采样

一条 `sample` 只承载**一个数据类型**，避免不同频率的数据互相拖累。

```jsonc
{
  "v": 1, "type": "sample", "seq": 1025, "ts": 1730000060000,
  "deviceId": "a1b2c3d4e5f60718",
  "payload": {
    "metric": "heart_rate",     // 见 3.5 枚举
    "value": 72,                // 数值；睡眠这类复合数据为 null
    "unit": "bpm",
    "startTime": 1730000058000, // 数据点自身的开始时间（毫秒）
    "endTime": 1730000060000,   // 数据点自身的结束时间（毫秒）
    "source": "healthStore",    // healthStore | mock | manual
    "sleep": null,              // 仅 metric=sleep 时非 null，见 3.4
    "extra": {}                 // 机型/传感器等自由字段
  }
}
```

### 3.3 `batch` — 补传（离线队列一次发送多条）

```jsonc
{
  "v": 1, "type": "batch", "seq": 1030, "ts": 1730001000000,
  "deviceId": "a1b2c3d4e5f60718",
  "payload": {
    "samples": [ /* 若干 sample 的 payload 字段（不含信封） */ ],
    "count": 12,
    "reason": "reconnect_backfill"   // reconnect_backfill | manual | app_resume
  }
}
```

> `batch` 里的每个元素**复用 `sample.payload` 的结构**，不含 `v/type/seq/ts/deviceId`。
> 电脑端必须按 `startTime` 升序重排后再入库，因为补传顺序可能乱。

### 3.4 `sleep` 复合数据（作为 `sample.payload.sleep` 出现）

**传输层采用华为新版 `healthStore.healthFields.Sleep` 的原始字段名与原始取值，
不做二次编码**，避免任何歧义。

```jsonc
{
  "fallAsleepTime": 1730000000000,   // 入睡时间，毫秒（官方：最早入睡时间）
  "wakeupTime": 1730028000000,       // 出睡时间，毫秒（官方：最晚醒来时间）
  "duration": 25200,                 // 夜间睡眠时长，秒
  "sleepScore": 80,                  // 睡眠得分 0-100
  "sleepEfficiency": 100,            // 睡眠效率 0-100
  "deepSleepContinuity": 55,         // 深睡连续性 0-100
  "respiratoryQualityScore": 78,     // 呼吸质量分 0-100
  "deepDuration": 5400,              // 深睡时长，秒
  "shallowDuration": 14400,          // 浅睡时长，秒
  "dreamDuration": 4200,             // REM 时长，秒
  "wakeDuration": 1200,              // 清醒时长，秒
  "wakeCount": 3,                    // 醒来次数
  "turnOverCount": 12,               // 翻身次数
  "sleepType": 1,                    // 1=TruSleep(科学睡眠) 2=普通睡眠 3=手动输入 4=手机记录
  "sleepEndReason": 1,               // 0=手动结束 1=自动结束 2=中断 3=低电量结束
  "sleepSegment": [                  // 睡眠分期明细（官方字段名）
    { "startTime": 1730006700000, "endTime": 1730008620000, "sleepStatus": 2 },
    { "startTime": 1730008620000, "endTime": 1730009220000, "sleepStatus": 1 }
  ]
}
```

**`sleepStatus` 取值（官方 `SleepSegment.sleepStatus`，本项目原样透传）**：

| 值 | 含义 |
| --- | --- |
| 0 | 未知 |
| 1 | **深睡** |
| 2 | **浅睡** |
| 3 | REM |
| 4 | 清醒 |
| 5 | 小睡 |
| 6 | 卧床 |
| 7 | 睡眠（手动记录） |

> ⚠️ **两处必须注意的偏差（已在本项目修正）**
>
> 1. 你原始需求里写的是「`sleepState`: 1=浅睡，3=深睡」。那是**旧版 JS SDK
>    （`@hw-hmscore/hms-js-health`）** 的语义。新版 `@kit.HealthServiceKit` 的字段叫
>    **`sleepStatus`**（不是 `sleepState`），且 **1=深睡、2=浅睡、3=REM** —— 1 和 2 正好相反。
>    本项目以新版 SDK 声明为准，原样透传，不做有损映射。详见 `docs/新旧API对照.md`。
> 2. 你原始需求里的 `snoreFreq`、`avgHeartRate`、`avgOxygenSaturation`、`avgBreathRate`、
>    `avgHrv` 这 5 个字段，在**新版 `healthFields.Sleep` 中不存在**（我逐个 grep 过 SDK 声明）。
>    它们只属于旧版 SDK。本项目把它们定义为**可选扩展字段 `legacy`**，手机端能取到就填、
>    取不到就省略，下游必须按「可能缺失」处理：
>
>    ```jsonc
>    "legacy": { "snoreFreq": 2, "avgHeartRate": 61, "avgOxygenSaturation": 97,
>                "avgBreathRate": 14, "avgHrv": 62 }
>    ```

### 3.5 metric 枚举（冻结）

| metric | 含义 | unit | 华为 healthStore 数据源 |
| --- | --- | --- | --- |
| `heart_rate` | 动态心率 | `bpm` | `samplePointHelper.heartRate.DATA_TYPE` |
| `resting_heart_rate` | 静息心率 | `bpm` | `samplePointHelper.restingHeartRate.DATA_TYPE` |
| `hrv` | 心率变异性 | `ms` | `samplePointHelper.heartRateVariability.DATA_TYPE`（API 18+） |
| `spo2` | 血氧饱和度 | `%` | `samplePointHelper.bloodOxygenSaturation.DATA_TYPE` |
| `stress` | 压力得分 | `score` | `samplePointHelper.stress.DATA_TYPE` |
| `sleep` | 睡眠（复合） | `null` | `healthSequenceHelper.sleepRecord` |
| `sleep_nap` | 零星小睡（复合） | `null` | `healthSequenceHelper.sleepNapRecord` |
| `body_temperature` | 体温 | `°C` | `samplePointHelper.bodyTemperature` |
| `heart_rate_series` | 心率采样序列（可选扩展） | `bpm` | `samplePointHelper.heartRate`（多条合并） |

> **`sleep_nap` 的 `payload.sleep`** 结构与 `sleep` 相同，但官方 `healthFields.SleepNap` 只有
> `noonDuration`（小睡时长，秒）与 `noonRecordDuration`，`fallAsleepTime`/`wakeupTime` 取该记录的起止时间。
> 下游渲染时必须允许这些字段缺失。

### 3.6 `ack` / `nack` / `ping` / `pong`（手机 → 电脑方向）

```jsonc
{ "v":1, "type":"ack",  "seq":0, "ts":1730000000000, "deviceId":"…", "payload":{ "ackSeq": 1030 } }
{ "v":1, "type":"ping", "seq":0, "ts":1730000000000, "deviceId":"…", "payload":{ "rtt": null } }
```

---

## 4. 下行（电脑 → 手机）

### 4.1 `hello_ack`

```jsonc
{
  "v": 1, "type": "hello_ack", "seq": 0, "ts": 1730000000000, "deviceId": "a1b2c3d4e5f60718",
  "payload": {
    "serverTime": 1730000000000,
    "accepted": true,
    "needBackfillFrom": 1024,      // 电脑侧缺口起点；-1 表示无需补传
    "collectIntervalMs": 60000,    // 电脑下发的采集周期（可远程调参）
    "metrics": ["heart_rate","resting_heart_rate","hrv","spo2","stress","sleep"]
  }
}
```

* **`collectIntervalMs` 由电脑下发**，手机端必须尊重（这就是「电脑端控制手机端采集节奏」）。
* 手机端即使不实现远程调参，也必须解析该字段并不报错。

### 4.2 `ping` / `pong` / `nack`

同上，方向相反。心跳周期 **30 秒**，连续 2 次无 `pong` 判定断线并重连。

---

## 5. 下游订阅协议（电脑 → 其他人/程序）

连接：`ws://<电脑IP>:<port>/subscribe?token=<订阅令牌>&since=<seq|0>&topic=health`

### 5.1 服务端 → 订阅者的消息

```jsonc
// 订阅成功
{ "v":1,"type":"subscribed","seq":0,"ts":…,"deviceId":"*",
  "payload":{ "topic":"health","replayed":120,"live":true,"devices":["a1b2…"] } }

// 实时推送（与上行 sample 同构，便于下游直接复用解析器）
{ "v":1,"type":"sample","seq":1031,"ts":…,"deviceId":"a1b2c3d4e5f60718",
  "payload":{ "metric":"spo2","value":97,"unit":"%","startTime":…,"endTime":…,"source":"healthStore" } }

// 设备上下线通知
{ "v":1,"type":"device_event","seq":0,"ts":…,"deviceId":"a1b2…",
  "payload":{ "event":"online","model":"HUAWEI Mate 60 Pro" } }
```

### 5.2 `since` 语义（断线续传）

* `since=0`：只要实时数据，不重放。
* `since=N`（N>0）：先把电脑端环形缓冲里 `seq > N` 的消息**按序重放**，再转入实时。
* 缓冲不够（`N` 太旧）时，服务端先发一条 `gap` 消息告知缺口，再转入实时：

```jsonc
{ "v":1,"type":"gap","seq":0,"ts":…,"deviceId":"*",
  "payload":{ "requestedSince":10,"oldestAvailable":900,"lost":890 } }
```

### 5.3 订阅者 → 服务端的控制消息

```jsonc
// 只订阅部分设备 / 部分指标（不设则全量）
{ "v":1,"type":"subscribe_filter","seq":0,"ts":…,"deviceId":"*",
  "payload":{ "deviceIds":["a1b2…"], "metrics":["heart_rate","spo2"] } }
// 拉取历史
{ "v":1,"type":"query","seq":0,"ts":…,"deviceId":"*",
  "payload":{ "requestId":"q1","deviceIds":[],"metrics":[],"startTime":0,"endTime":0,"limit":500 } }
```

对应回包：

```jsonc
{ "v":1,"type":"query_result","seq":0,"ts":…,"deviceId":"*",
  "payload":{ "requestId":"q1","samples":[ /* sample.payload 数组 */ ], "truncated":false } }
```

### 5.4 REST（给不方便用 WebSocket 的下游）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/health` | 服务存活、版本、运行时长 |
| `GET` | `/api/devices` | 设备列表 + 在线状态 + 最后活跃时间 + 最新各指标值 |
| `GET` | `/api/samples?deviceId=&metric=&limit=100&since=` | 历史样本（倒序） |
| `GET` | `/api/latest?deviceId=` | 每指标最新一条 |
| `GET` | `/api/export?deviceId=&format=json|csv` | 导出 |
| `POST` | `/api/forward` | 配置主动转发目标，见 5.5 |
| `GET` | `/api/stats` | 收发计数、队列深度、订阅者数量 |

所有 REST 需要请求头 `X-Auth-Token: <订阅令牌>` 或查询参数 `?token=<订阅令牌>`。
令牌在电脑端 `config.json` 里配置。

### 5.5 主动转发（电脑 → 另一台电脑/服务）

电脑端除了「等别人来订阅」，还必须能**主动推**。转发目标的完整字段与状态机见
`docs/HTTP接口契约.md` 第 3.7 节（`kind` 决定走 WebSocket 长连接还是 HTTP 定时推送；
两者都只用一个 `url` 字段，不用 `httpUrl`）：

```jsonc
POST /api/forward
{
  "id": "oncall-pc",
  "enabled": true,
  "kind": "websocket",                                // websocket（长连接）| http（定时 POST）
  "url": "ws://192.168.1.50:8788/ingest?token=xxx",   // kind=http 时写 http://…
  "deviceIds": ["a1b2c3d4e5f60718"],                   // 空数组=全部
  "metrics": ["heart_rate"],                           // 空数组=全部
  "batchMs": 2000,                                      // 攒批间隔，0=不攒批
  "retry": { "maxAttempts": 5, "backoffMs": 1000 }
}
```

* 每个转发目标独立维护**长连接 + 发送队列 + 重试**（这就是电脑端的「长加载/长时任务」等价物）。
* 转发失败进队列，恢复后继续，不丢数据；队列有上限（默认 20000 条），
  超限丢最旧并计入 `droppedTotal`。
* 电脑端自身也提供 `POST /api/ingest` 作为 **HTTP 接收端**，方便对端不支持 WebSocket 时使用。

---

## 6. 传输层抽象（为「日后换公网中继」留的口子）

手机端把「怎么把信封发出去」抽象成一个接口：

```
interface Transport {
  connect(): Promise<void>
  send(envelope: Envelope): Promise<void>
  close(): void
  onMessage(handler: (env: Envelope) => void): void
  readonly state: 'idle' | 'connecting' | 'open' | 'closed'
}
```

* `LanWebSocketTransport`：直连电脑 IP（默认实现，本仓库已提供）。
* `CloudRelayTransport`：把同样的信封发到公网中继（**接口已留，未实现**）。
  换成它只需改一行构造代码，业务层（采集、队列、协议）完全不动。

---

## 7. 错误与重连规则（冻结）

| 场景 | 手机端行为 | 电脑端行为 |
| --- | --- | --- |
| WebSocket 断开 | 1s/2s/4s/8s/16s/30s 退避重连，上限 30s | 保留该设备的历史，标 `offline` |
| 重连成功 | 发 `hello`，带 `lastSeq`；随后按电脑 `needBackfillFrom` 发 `batch` | 回 `hello_ack`，算缺口 |
| 电脑磁盘满/写库失败 | 无感知（协议不依赖写库成功） | 记日志，仍尝试推送下游 |
| 手机被系统挂起 | 依赖长时任务保活（见 `docs/长时任务与保活.md`） | 超过 `offlineAfterMs` 标离线，不删数据 |
| 下游订阅者断开 | — | 保留其 `since` 游标；重连时按 5.2 重放 |

---

## 8. 版本演进

* `v` 字段不变、只加字段 → 小版本，双方忽略未知字段即可。
* 删字段或改语义 → 必须升 `v`，且电脑端要能同时接受 `v=1` 与 `v=2`。
* 电脑端收到不认识的 `v`：回 `nack`，`payload.reason = "unsupported_version"`。
