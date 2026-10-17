# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [1.0.0] - 2026-10-17

首次公开发布。

### 新增

- **电脑端 Hub**（Node.js，零第三方依赖）：`/ingest` WebSocket 接收、环形缓冲、
  断线重放、REST 查询、`/subscribe` 实时推送、主动转发、零依赖可视化面板与只读分享页。
- **手机端 · HarmonyOS**（ArkTS / Stage 模型，API 12+）：`@kit.HealthServiceKit` 采集心率 /
  静息心率 / HRV / 血氧 / 压力 / 睡眠，`bluetoothInteraction` 长时任务保活，断线指数退避 + 离线队列。
- **手机端 · Android**（Kotlin / Gradle）：同协议的采集端，含模拟 / BLE / 华为 SensorPro 三种数据源。
- **PC 蓝牙桥**（C#，.NET SDK 8，零 NuGet 包）：电脑直接连标准心率设备
  （服务 `0x180D` / 特征 `0x2A37`），输出 JSON Lines 交给 Hub；支持按名称或按地址直连。
- **分享与穿透**：局域网分享链接生成器、接收端打包（给远方家人双击即用）、
  樱花穿透地址生成器（`tools/sakura-url.js`）。
- **诊断工具**：`tools/ble-diag`（蓝牙体检探针）、`tools/netcheck.js`（公网/CGNAT/组网探测）、
  `tools/phone-sim.js`（无真机模拟手机）、`tools/check-encoding.ps1`（编码终检）。
- **文档**：协议 v1 冻结契约 + JSON Schema、HTTP 接口契约、ArkTS 严格模式 34 个报错修法、
  华为 API 8 处纠错、BLE 直连排错、长时任务保活、部署与验证、穿透部署。

### 修复（发布前真实发现并修掉的缺陷）

- `parseHeaders` 把 Node 的扁平 `rawHeaders` 当成 `"Name: value"` 字符串数组 →
  **所有 WebSocket 握手返回 400**，上行链路完全不可用。
- 协议错误后未停止解析、出错帧一个字节都没消费 → 同一帧被反复解析，
  error 刷屏、CLOSE 发不出、**CPU 打满**。
- 转发目标 `upsert` 替换时丢弃旧队列 → 已收到未发出的数据**永久丢失**。
- 订阅者重放用内部 `order` 比较业务 `seq` → 多设备时**重放错数据或漏数据**。
- 主动 close 后把对端回的 CLOSE 帧一起挡掉 → 关闭码上报错误（4401 记成 1006）。
- PC 蓝牙桥：中文输出未声明 UTF-8，GBK 字节被 Node 按 UTF-8 解码 → 设备名/错误信息乱码并写进面板。
- PC 蓝牙桥：`FromBluetoothAddressAsync` 在设备未广播时返回 `null`，
  原逻辑直接报错死循环 → 增加"系统已配对设备库"兜底 + 短扫描诊断（能区分
  「扫描 0 个包 = 蓝牙栈卡死」与「有包但没目标 = 设备没戴/被手机占用」）+ 重连退避。
- PC 蓝牙桥：连接成功后不清 `lastError` → 面板显示"明明连着却还在报错"。
- 验证脚本 `tools/verify-share-page.js` / `mobile/android/verify-protocol.js` 依赖
  Node 21+ 才有的全局 `WebSocket` → **CI 在 Node 18/20 上 `ReferenceError` 直接失败**
  （本地 Node 24 却通过，属于典型的"只在 CI 上红"）。新增 `tools/mini-ws.js` 垫片，
  18/20 走项目自带的 `WsClient`，22+ 走原生 `WebSocket`，两条路径都在 CI 矩阵里覆盖。
