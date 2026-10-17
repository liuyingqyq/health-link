# HealthLink —— 手机健康数据采集 + 电脑端实时转发

把华为手机上的运动健康数据（心率 / 静息心率 / HRV / 血氧 / 压力 / 睡眠）
**在后台持续采集**，通过局域网实时上传到你自己的电脑；
电脑端再把数据**实时转发给其他人**（浏览器面板或第三方程序）。

```
┌──────────────────────┐        ① WebSocket 长连接（手机主动外连）        ┌─────────────────────┐
│  HarmonyOS 手机 App   │ ─────────────────────────────────────────────▶ │  电脑端 HealthLink    │
│  HealthLink 采集端    │   hello / sample / batch / ping               │  Hub（接收 + 中继）   │
│                      │                                                │                     │
│  · @kit.HealthServiceKit 读健康数据                                     │  ② 实时推送          │
│  · bluetoothInteraction 长时任务保活                                    │  ┌───────────────┐  │
│  · 断线退避重连 + 离线队列                                              │  │ 浏览器实时面板  │  │
└──────────────────────┘                                                │  └───────────────┘  │
                                                                        │  ③ 主动转发          │
                                                                        │  ┌───────────────┐  │
                                                                        │  │ 另一台电脑/服务 │  │
                                                                        │  └───────────────┘  │
                                                                        └─────────────────────┘
```

---

## 目录结构

```
health-link/
├── docs/                          # 全部中文文档
│   ├── README.md                  #   总览与架构
│   ├── 快速开始.md                 #   5 分钟跑通
│   ├── protocol/README.md         #   ★ 传输协议 v1（冻结契约）
│   ├── protocol/health-sample.schema.json
│   ├── HTTP接口契约.md             #   电脑端 REST / WS 接口契约
│   ├── 新旧API对照与纠错.md        #   ★ 官方 API 与你原始需求的偏差
│   ├── 长时任务与保活.md           #   后台保活的真实约束
│   └── 部署与验证.md               #   真机部署、离线构建说明
├── mobile/harmonyos/                         # HarmonyOS 手机端（ArkTS / Stage 模型）
│   ├── AppScope/
│   ├── entry/src/main/
│   │   ├── module.json5           #   权限 + backgroundModes 声明
│   │   ├── ets/
│   │   │   ├── entryability/      #   EntryAbility + MyAbilityStage（预加载检测）
│   │   │   ├── health/            #   HealthStoreClient（华为健康数据读取）
│   │   │   ├── service/           #   采集编排 + 长时任务管理
│   │   │   ├── transport/         #   传输抽象 + 局域网 WebSocket 实现
│   │   │   ├── model/             #   协议类型定义
│   │   │   ├── common/            #   日志 / 偏好存储
│   │   │   └── pages/Index.ets    #   主界面
│   │   └── resources/
│   └── build-profile.json5
├── pc/                            # 电脑端（Node.js，零外部依赖）
│   ├── src/
│   │   ├── ws.js                  #   自己实现的 WebSocket 服务端（RFC 6455 子集）
│   │   ├── wsclient.js            #   WebSocket 客户端（转发用，掩码发送）
│   │   ├── storage.js             #   环形缓冲 + 按 seq 重放
│   │   ├── hub.js                 #   设备注册 / 订阅者中继 / 断线补传
│   │   ├── relay.js               #   主动转发（队列 + 重试 + 持久化）
│   │   ├── server.js              #   HTTP + WebSocket 路由
│   │   ├── config.js              #   配置合并
│   │   └── index.js               #   启动入口
│   ├── web/                       #   零依赖可视化面板（原生 HTML/CSS/JS）
│   └── test/e2e.test.js           #   端到端测试（47 项）
└── tools/
    ├── phone-sim.js               # 手机端模拟器（无真机也能验证全链路）
    ├── offline-registry.js        # 离线 npm registry（离线构建 HAP 用）
    └── build-phone.ps1            # 一键离线构建 HAP
```

---

## 快速开始

### 1. 启动电脑端

```bash
cd health-link/pc
node src/index.js
```

输出会打印三样东西，**照着抄**：

```
HealthLink 电脑端已启动: http://0.0.0.0:18787/
访问令牌: 3f9a1c...
手机上行地址: ws://192.168.1.5:18787/ingest?token=3f9a1c...
本机打开面板： http://127.0.0.1:18787/?token=3f9a1c...
```

首次启动会自动生成访问令牌并写入 `pc/config.json`（**不会**出现"无令牌放行"的情况）。

### 2. 打开可视化面板

浏览器访问上面最后一行那个地址，能看到设备状态、实时曲线、睡眠分期色带、转发配置、导出按钮。

### 3. 没有真机？用模拟器验证全链路

```bash
node tools/phone-sim.js --url "ws://127.0.0.1:18787/ingest?token=3f9a1c..." --interval 1000 --sleep
```

模拟器**严格按协议 v1 说话**，所以它能让数据出现在面板上，就等于链路是通的。
它还支持故意制造故障：

```bash
# 前 5 秒假装没网，验证离线队列与补传
node tools/phone-sim.js --url "..." --offline 5
# 第 8 秒主动断开一次，验证退避重连
node tools/phone-sim.js --url "..." --disconnect 8
# 模拟两台设备同时上传
node tools/phone-sim.js --url "..." --devices 2
```

### 4. 真机部署

见 [`部署与验证.md`](部署与验证.md)。简要说：

1. 用 DevEco Studio 打开 `mobile/harmonyos/` 目录。
2. 配置你自己的签名（`build-profile.json5` 里的 `signingConfigs` 是空的，需要你在
   DevEco 里用「自动签名」生成）。
3. **重要**：健康数据需要先在 AGC 申请权限，详见
   [`新旧API对照与纠错.md` 第 4 节](新旧API对照与纠错.md)。
4. 编译安装后，把电脑端打印的 `ws://...` 整行粘进 App 的「电脑地址」输入框，点保存，
   再点「请求健康数据授权」，最后点「开始采集」。

---

## 这个项目相对你原始需求做了哪些修正

**这不是照抄，有 8 处官方事实与原始材料不符，都已纠正并写明依据。**
完整版见 [`新旧API对照与纠错.md`](新旧API对照与纠错.md)，这里列最关键的 4 条：

| # | 原始材料 | 实际情况 | 影响 |
| --- | --- | --- | --- |
| 1 | 权限名 `HEALTH_DATA_READ`，"个人可申请" | **该权限名官方查无来源**。真实模型是「AGC 申请数据权限（中文权限项）∩ 运行时 `requestAuthorizations()` 用户授权」；开放等级官方叫法是"基础/高阶" | 照原样写会导致权限完全不生效 |
| 2 | 睡眠分期 `sleepState`：1=浅睡，3=深睡 | 字段名是 **`sleepStatus`**，且 **1=深睡、2=浅睡、3=REM、4=清醒** | 深浅睡会被**完全画反**，直接误导使用者 |
| 3 | `snoreFreq`/`avgHeartRate`/`avgOxygenSaturation`/`avgBreathRate`/`avgHrv` | 这 5 个字段在新版 `healthFields.Sleep` 里**不存在** | 取不到值；要用独立数据类型另查后按时间窗对齐 |
| 4 | `ContinuousTaskExtensionAbility` 接收系统回调 | **该 API 查无官方来源**；Stage 模型长时任务**只有 UIAbility 能申请** | 写了编译不过 / 无效 |

另外 4 条（`WindowStage.onCreate` 不存在、`getAppPreloadType` 是 API 22+、
`AbilityStage` 必须在 module.json5 用 `srcEntry` 声明、`DATA_TRANSFER` 长时任务
10 分钟不更新进度会被取消）见纠错文档。

---

## 电脑端"长加载 / 长时任务"怎么落地的

你提到电脑端也要"走安卓的长加载逻辑"。Android/HarmonyOS 那套长时任务是
**移动端系统概念**，PC 上没有对应机制，但**目的一致**：进程不退出、断线不放弃、数据不丢。
电脑端用这三样等价物实现：

| 移动端的机制 | 电脑端的等价实现 | 代码位置 |
| --- | --- | --- |
| 长时任务保活 | 单进程常驻 + `uncaughtException`/`unhandledRejection` 兜底（记日志但**不退出**） | `pc/src/index.js` |
| 断线重连 | 转发目标各自维护长连接，1s/2s/4s/8s/16s/30s 指数退避，永不放弃 | `pc/src/relay.js` |
| 离线队列 | 转发失败进本地队列（默认上限 20000 条），恢复后按序补发；超限丢最旧并计数 | `pc/src/relay.js` |
| 通知栏常驻 | 面板顶部状态条 + `/api/stats` 实时指标 | `pc/web/app.js` |
| 进程被回收后恢复 | 转发目标持久化到 `forwards.json`，重启自动恢复 | `pc/src/relay.js` |

---

## 电脑端零外部依赖

`pc/` 下**没有任何 npm 依赖**，包括 WebSocket：

* `pc/src/ws.js` —— 自己实现的 RFC 6455 服务端子集（握手、帧编解码、掩码、分片、心跳、1002/4401/4409 关闭码）
* `pc/src/wsclient.js` —— 客户端方向（发送掩码），转发目标用

原因：需求要求完全离线可运行。`ws` 包很好，但这里装不了，而所需功能只是
RFC 6455 的一个小子集，自己实现反而更可控（而且顺手修掉了两个真实缺陷，见下）。

---

## 测试

```bash
cd health-link
node pc/test/e2e.test.js
```

**52 项端到端测试，全部通过（退出码 0）**，覆盖：环形缓冲语义、配置合并、HTTP 鉴权、
路径穿越防护、WebSocket 握手与帧编解码、上行协议校验、断线重放（按 seq）、
订阅者过滤与历史查询、CSV/JSON 导出（含 UTF-8 BOM 与转义）、转发 CRUD 与真实 HTTP 投递、
队列恢复重发、JSONL 归档、大帧（>64KB）与超大帧（>1MB 拒绝并回 1002）、
多设备并发、僵尸连接清理。

测试过程中**真实发现并修复了 5 个缺陷**（不是测试写法问题，是实现问题）：

| # | 缺陷 | 后果 | 修复位置 |
| --- | --- | --- | --- |
| 1 | `parseHeaders` 把 Node 的 `rawHeaders` 当成 `"Name: value"` 字符串数组，实际是**扁平数组** | **所有 WebSocket 握手都返回 400**，整个上行链路不可用 | `pc/src/ws.js` |
| 2 | 协议错误后没有停止解析，出错的那一帧一个字节都没被消费 | 同一帧被**反复解析**，error 事件刷屏、CLOSE 帧发不出去、对端只看到 1006，**CPU 打满** | `pc/src/ws.js` |
| 3 | 转发目标 `upsert` 替换时直接丢弃旧队列 | 已收到但未发出的数据**永久丢失**（与"断线不丢数据"目标矛盾） | `pc/src/relay.js` |
| 4 | 订阅者重放用内部 `order` 去比较业务 `seq` | 多设备/有补传时**重放错数据或漏数据** | `pc/src/storage.js` |
| 5 | 主动 close 后把对端回来的 CLOSE 帧一起挡掉 | 关闭码上报错误（把 4401 记成 1006），问题排查困难 | `pc/src/ws.js` |

---

## 已知限制（如实说明，未粉饰）

1. **手机端没有拿到最终 HAP**。代码写到依赖解析全部通过，但止步于工具链：
   hvigor 用 `child_process.fork()` 启动子进程，本会话沙箱**禁止创建 IPC 命名管道**
   （`spawn EPERM`）；同时本机访问不了 npm registry，而 hvigor 依赖的两个包
   （`@ohos/hvigor` / `@ohos/hvigor-ohos-plugin`）**不在 npmjs 上**。
   我用 `tools/offline-registry.js` 把 DevEco 自带的包做成本地 registry，
   解决了 3 个真实问题后 pnpm 成功解析 298 个包，最后卡在传递依赖
   `brace-expansion@^1.1.7`（DevEco 只自带 2.1.4，本机拉不到公网）。
   → **请在有外网的机器上用 DevEco Studio 打开 `mobile/harmonyos/` 构建**，
   完整踩坑记录见 [`部署与验证.md` 第三节](部署与验证.md)。
2. **没有真机验证**。"华为账号是否已登录、运动健康 App 是否启动过、
   AGC 数据权限是否批下来、长时任务会不会被判定业务不实而取消"，
   这些都**只能在真机上验证**，`部署与验证.md` 第 2.5 节给了 10 项验证清单。
3. **手机端无法补传断线期间的全部历史**。App 只在内存里保留最近一轮采集样本
   （没有可靠的长期本地队列实现条件），所以 `batch` 补传覆盖最近一轮，
   更早的缺口用 `gap` 消息**如实告知电脑端**，不假装补全。
   电脑端环形缓冲默认 20000 条，够覆盖较长时间的重连窗口。
4. **跨公网未实现**。传输层已抽象成 `Transport` 接口并预留 `CloudRelayTransport`，
   但公网中继需要一台服务器。本项目交付**局域网直连**（你选定的方案）。
5. **电脑端面板没有在真实浏览器里点过**。面板逻辑用 Node + 迷你 DOM 夹具
   做了 60 条断言验证，静态资源可达性也确认过，但像素级渲染需要你自己开一次浏览器。
6. **`bluetoothInteraction` 长时任务的业务真实性**未经真机验证；
   若被系统判定不实，调整方法见 [`长时任务与保活.md` 2.6](长时任务与保活.md)。

---

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [快速开始.md](快速开始.md) | 5 分钟跑通（含模拟器验证） |
| [手机端安装指南.md](手机端安装指南.md) | ★ 怎么把 App 装到手机上（签名、hdc、错误码对照） |
| [BLE直连模式.md](BLE直连模式.md) | ★ BLE 直连读手表数据：能力边界、操作流程、排错 |
| [版本兼容说明.md](版本兼容说明.md) | ★ HarmonyOS 5/6/7 与 API level 对应、装不上时怎么改 |
| [ArkTS严格模式避坑.md](ArkTS严格模式避坑.md) | ★ 34 个真实 ArkTS 编译错误与修法（含 SDK 的 SlotType 缺陷） |
| [protocol/README.md](protocol/README.md) | ★ 传输协议 v1 冻结契约：信封、metric 枚举、睡眠字段、重连与重放规则 |
| [HTTP接口契约.md](HTTP接口契约.md) | 电脑端 REST / WebSocket 接口完整定义 |
| [新旧API对照与纠错.md](新旧API对照与纠错.md) | ★ 新旧华为 API 对照 + 8 处纠错 + 官方来源 URL |
| [长时任务与保活.md](长时任务与保活.md) | 后台保活的官方约束、10 分钟续期、预加载 |
| [部署与验证.md](部署与验证.md) | 真机部署步骤、命令行构建 HAP、故障排查 |
| [../pc/web/README.md](../pc/web/README.md) | 可视化面板使用说明 |
| [../README.md](../README.md) | 项目总览（回到根目录） |

## 相关指南

- [樱花穿透部署指南.md](樱花穿透部署指南.md) —— 电脑直连心率带后，如何让外地的人用浏览器看到数据（完整流程与排错）
