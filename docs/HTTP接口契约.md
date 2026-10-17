# HealthLink 电脑端 HTTP / WebSocket 接口契约

> **本文件是电脑端内部契约**，冻结于协议 v1。
> 可视化面板（`pc/web/*`）只允许依赖本文件，服务端核心（`pc/src/*`）负责满足它。

监听地址默认 `http://0.0.0.0:18787`，可用 `--port` / 环境变量 `HEALTHLINK_PORT` 覆盖。

---

## 1. 鉴权

所有 `/api/*` 需要令牌，二选一：

* 请求头 `X-Auth-Token: <token>`
* 查询参数 `?token=<token>`

令牌从 `pc/config.json` 的 `authToken` 读取；未配置时服务端自动生成一个随机令牌并打印在启动日志里（**不允许空令牌放行**）。

失败返回 `401`：

```json
{ "ok": false, "error": { "code": "unauthorized", "message": "missing or invalid token" } }
```

**`/` 与 `/assets/*` 静态资源不需要令牌**（面板本身要通过 `?token=` 把令牌交给前端，见第 6 节）。

---

## 2. 统一响应信封

成功：

```json
{ "ok": true, "data": { }, "ts": 1730000000000 }
```

失败：

```json
{ "ok": false, "error": { "code": "bad_request", "message": "limit must be 1..1000" }, "ts": 1730000000000 }
```

错误码枚举：`unauthorized` `bad_request` `not_found` `internal` `unsupported_version`。

---

## 3. REST 接口

### 3.1 `GET /api/health`（无需令牌）

```json
{ "ok": true, "data": { "service": "healthlink-hub", "version": "1.0.0", "protocol": 1, "uptimeMs": 123456, "startedAt": 1730000000000 }, "ts": 0 }
```

### 3.2 `GET /api/stats`

```json
{
  "ok": true,
  "data": {
    "uptimeMs": 123456,
    "devices": { "total": 2, "online": 1 },
    "subscribers": { "total": 3 },
    "forwards": { "total": 2, "enabled": 1, "queuedTotal": 17, "sentTotal": 4021, "failedTotal": 3, "droppedTotal": 0 },
    "ingest": { "samples": 4021, "bytes": 812345, "batches": 12, "rejected": 0 },
    "buffer": { "size": 4021, "capacity": 20000, "oldestSeq": 1, "newestSeq": 4021 }
  },
  "ts": 0
}
```

### 3.3 `GET /api/devices`

```json
{
  "ok": true,
  "data": [
    {
      "deviceId": "a1b2c3d4e5f60718",
      "online": true,
      "firstSeen": 1730000000000,
      "lastSeen": 1730000120000,
      "connectedAt": 1730000000000,
      "remoteAddress": "192.168.1.23",
      "hello": { "model": "HUAWEI Mate 60 Pro", "osVersion": "HarmonyOS 6.0.0", "appVersion": "1.0.0",
                 "collectIntervalMs": 60000, "backgroundMode": ["bluetoothInteraction", "dataTransfer"],
                 "healthStoreReady": true, "permissions": { "healthDataRead": true } },
      "lastSeq": 4021,
      "samplesReceived": 4021,
      "latest": {
        "heart_rate": { "value": 72, "unit": "bpm", "startTime": 1730000110000, "endTime": 1730000120000, "source": "healthStore", "receivedAt": 1730000120100 },
        "spo2": { "value": 97, "unit": "%", "startTime": 1730000110000, "endTime": 1730000120000, "source": "healthStore", "receivedAt": 1730000120100 }
      }
    }
  ],
  "ts": 0
}
```

* `online` 判定：连接存在，或 `now - lastSeen <= offlineAfterMs`（默认 120000）。
* `latest` 的键是 metric 名，值是 `sample.payload` 加一个 `receivedAt`。

### 3.4 `GET /api/samples`

查询参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `deviceId` | 空=全部 | 过滤设备 |
| `metric` | 空=全部 | 过滤指标，逗号分隔 |
| `since` | 空 | 只要 `seq > since` |
| `startTime` / `endTime` | 空 | 按数据点时间（毫秒）过滤 |
| `limit` | 100 | 1..1000 |
| `order` | `desc` | `desc` 或 `asc` |

```json
{
  "ok": true,
  "data": {
    "samples": [
      { "seq": 4021, "ts": 1730000120000, "deviceId": "a1b2c3d4e5f60718", "receivedAt": 1730000120100,
        "payload": { "metric": "heart_rate", "value": 72, "unit": "bpm", "startTime": 1730000110000, "endTime": 1730000120000, "source": "healthStore" } }
    ],
    "count": 1,
    "truncated": false
  },
  "ts": 0
}
```

### 3.5 `GET /api/latest`

```json
{ "ok": true, "data": { "a1b2c3d4e5f60718": { "heart_rate": { "value": 72, "unit": "bpm", "endTime": 1730000120000, "receivedAt": 1730000120100 } } }, "ts": 0 }
```

### 3.6 `GET /api/export?deviceId=&metric=&format=json|csv&limit=`

* `format=json` → `Content-Type: application/json`，`Content-Disposition: attachment; filename="healthlink-export-<时间戳>.json"`，内容为 `{ "exportedAt":…, "samples":[…] }`。
* `format=csv` → `text/csv; charset=utf-8`，**带 UTF-8 BOM**（Excel 中文兼容），表头固定为：
  `seq,deviceId,metric,value,unit,startTime,endTime,source,receivedAt,metricJson`
  其中 `metricJson` 是 `JSON.stringify(payload)` 并用双引号包裹转义后的结果。

### 3.7 转发目标管理

`GET /api/forward` → `{ "ok": true, "data": [ <目标对象> ] }`

`POST /api/forward`，body 为目标对象（`id` 必填，存在则更新，不存在则创建）：

```json
{
  "id": "oncall-pc",
  "enabled": true,
  "kind": "websocket",
  "url": "ws://192.168.1.50:8788/ingest?token=xxx",
  "deviceIds": [],
  "metrics": [],
  "batchMs": 2000,
  "retry": { "maxAttempts": 5, "backoffMs": 1000 }
}
```

* `kind`：`websocket`（默认，长连接）| `http`（每批一次 POST 到 `url`）。
* `batchMs=0` 表示不攒批，逐条发。
* 响应 `data` 为该目标的最新状态对象（含只读运行态字段）：

```json
{ "id": "oncall-pc", "enabled": true, "kind": "websocket", "url": "ws://…",
  "deviceIds": [], "metrics": [], "batchMs": 2000, "retry": { "maxAttempts": 5, "backoffMs": 1000 },
  "state": "connected", "queued": 0, "sentTotal": 4021, "failedTotal": 3, "droppedTotal": 0,
  "lastError": null, "lastSentAt": 1730000121000, "connectedAt": 1730000000000 }
```

`state` 枚举：`disabled` `connecting` `connected` `backoff` `error`。

`DELETE /api/forward?id=<id>` → `{ "ok": true, "data": { "removed": true } }`

`POST /api/forward/test`，body `{ "id": "…" }` → 立刻尝试连一次并返回 `{ "ok": true, "data": { "reachable": true, "latencyMs": 12, "error": null } }`。

转发出去的包体格式与手机上行**完全同构**（信封 + payload），这样对端可以直接复用手机端的解析代码。

---

## 4. WebSocket：`/subscribe`（面板与第三方消费）

`ws://<host>:<port>/subscribe?token=<token>&since=<seq>&topic=health`

* `since` 省略或 `0`：只要实时。
* `since=N>0`：先重放 `seq > N` 的历史，再转实时；缺口发 `gap`。
* 客户端可发 `subscribe_filter` / `query`，语义见 `docs/protocol/README.md` 第 5.3 节。

服务端消息类型（全部走同一信封）：

| type | 何时发 |
| --- | --- |
| `subscribed` | 连接鉴权通过、重放开始前 |
| `sample` | 每条实时样本（payload 同手机上行） |
| `device_event` | 设备上线/下线，`payload.event` = `online`/`offline` |
| `gap` | `since` 太旧，缓冲里已没有 |
| `query_result` | 回应 `query` |
| `pong` | 回应客户端 `ping` |
| `nack` | 鉴权失败/未知类型。`payload.reason` |

**鉴权失败**：服务端发一条 `nack`（`reason=unauthorized`）随后关闭，关闭码 `4401`。

---

## 5. WebSocket：`/ingest`（手机端上行）

`ws://<host>:<port>/ingest?token=<token>`

* 首条必须是 `hello`，否则 `nack` + 关闭码 `4400`。
* 支持 `hello` `sample` `batch` `ping` `ack`。
* 服务端回 `hello_ack` `pong` `ack` `nack`。
* 同一 `deviceId` 重复连接：**踢掉旧连接**（关闭码 `4409`），保留新连接。

---

## 6. 静态资源与令牌交接

* `GET /` → `pc/web/index.html`
* `GET /assets/<file>` → `pc/web/<file>`（禁止路径穿越）
* 面板 JS 从 `location.search` 读 `token`，之后所有 `/api/*` 与 WebSocket 都带上它。
* 若 URL 未带 token，面板显示「请输入访问令牌」输入框。

---

## 7. 面板必须展示的内容（验收点）

1. **顶部状态条**：服务是否在线、协议版本、运行时长、设备在线数、订阅者数、入站样本总数。
2. **设备卡片列表**：每台设备显示 `deviceId`（截断显示）、机型、在线/离线徽标、最后活跃时间、采集周期、长时任务模式标签、当前各指标最新值。
3. **实时曲线**：心率 / 静息心率 / HRV / 血氧 / 压力，各一条时间序列（Canvas 绘制，窗口默认最近 10 分钟，可切换 1/10/60 分钟）。曲线要能区分不同设备（不同颜色）。
4. **睡眠卡片**：展示最近一条 `metric=sleep`，画出 `sleepSegment` 分期色带（用 `sleepStatus` 官方取值配色），显示得分、时长、效率，缺失 `legacy` 字段时优雅降级。
5. **实时事件流**：最新 50 条样本/事件的滚动列表。
6. **转发目标面板**：列出 `GET /api/forward` 的结果，能新增/启停/删除，显示 `state`、队列深度、已发送/失败计数。
7. **导出按钮**：触发 `/api/export?format=csv` 与 `json` 下载。
8. **断线自动重连**：WebSocket 断开后指数退避重连，并把 `since` 设为最后收到的 `seq`（验证第 5.2 节重放）。

### 技术要求

* **零外部依赖**：只用原生 HTML / CSS / JS（ES2020），不引入任何框架或 CDN 资源（必须能完全离线打开）。
* 不写死 `localhost`：用 `location.host` 拼 WebSocket 地址。
* 单个文件不超过 400 行，拆成 `index.html` + `app.js` + `styles.css` + `chart.js`。
* 所有面向用户的文案用**中文**。
* 时间显示用本地时区，格式 `HH:mm:ss`。
