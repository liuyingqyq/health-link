# HealthLink · 健康数据采集与实时转发

把手机上的健康数据（心率 / 静息心率 / HRV / 血氧 / 压力 / 睡眠）**在后台持续采集**，
通过局域网实时上传到你自己的电脑；电脑端再把数据**实时推给浏览器面板、只读分享页、或第三方程序**。

整条链路都在你自己的设备上：**不经过任何云端，不需要注册账号，电脑端零第三方依赖。**

![license](https://img.shields.io/badge/license-MIT-blue.svg)
![node](https://img.shields.io/badge/Node.js-%E2%89%A518-339933)
![deps](https://img.shields.io/badge/third--party%20deps-0-brightgreen)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20HarmonyOS%20%7C%20Android-lightgrey)

[![CI](https://github.com/liuyingqyq/health-link/actions/workflows/ci.yml/badge.svg)](https://github.com/liuyingqyq/health-link/actions/workflows/ci.yml)

```
┌──────────────────────┐   ① WebSocket 长连接（手机主动外连）   ┌──────────────────────┐
│  HarmonyOS / Android │ ───────────────────────────────────▶ │   电脑端 HealthLink   │
│  采集端 App          │   hello / sample / batch / ping      │   Hub（接收 + 中继）   │
│                      │                                      │                      │
│ · HealthServiceKit   │                                      │  ② 实时推送           │
│ · 长时任务保活       │                                      │  → 浏览器面板 / 分享页 │
│ · 断线退避 + 离线队列│                                      │  ③ 主动转发           │
└──────────────────────┘                                      │  → 另一台电脑 / 服务   │
                                                              └──────────────────────┘
        另外还支持：心率带 ──BLE──▶ 电脑（不经手机，见「PC 蓝牙直连」）
```

---

## 它解决什么问题

| 痛点 | 这个项目的做法 |
|---|---|
| 各家健康 App 的数据都在云端，导不出来、也不实时 | 手机端本机读取 → **直连你自己的电脑**，全程不出局域网 |
| 想在电脑大屏上看实时心率 / 给别人看 | 电脑端自带**零依赖面板**和**只读分享页**，对方浏览器打开即可 |
| 不想为看个心率装一堆服务、跑容器、配数据库 | 电脑端是**单文件 Node 服务，零第三方依赖**（真的没有 `npm install`） |
| 想要原始数据做自己的分析 | REST / WebSocket 订阅 / 主动转发三种出口，协议公开且带 JSON Schema |
| 不想让手机参与 | **PC 蓝牙桥**：电脑直接连标准心率设备（`0x180D`/`0x2A37`） |

---

## 特性

**电脑端（`pc/`，Node.js ≥ 18，零第三方依赖）**

- `/ingest` WebSocket 接收，`/subscribe` 实时推送，REST 查询 / 导出（JSON / CSV）
- 环形缓冲 + 按 `seq` 断线重放，设备上下线事件，心跳与死连接清理
- 主动转发到另一台电脑/服务（WebSocket 或 HTTP，带队列重试，不丢数据）
- 原生 HTML/CSS/JS 可视化面板 + **只读**分享页（页面内无任何写操作）
- 自写的最小 WebSocket 实现（服务端 + 客户端），不引 `ws` 包

**手机端（两套，协议一致）**

- HarmonyOS（ArkTS / Stage 模型，API 12+）：`@kit.HealthServiceKit` 采集 + `bluetoothInteraction` 长时任务保活
- Android（Kotlin / Gradle）：OkHttp WebSocket，前台服务常驻
- 共用行为：断线指数退避、离线队列、序号续传、设备标识稳定

**PC 蓝牙桥（`pc/ble/`，C#，需 .NET SDK 8）**

- 直连标准心率设备，输出 JSON Lines 交给 Hub；顺带用 RR 间期算 **HRV（RMSSD）**
- 自带诊断：能区分「扫描 0 个包 = 蓝牙栈卡死」与「有包但没目标 = 设备没戴/被手机占用」

---

## 快速开始（电脑端，3 分钟）

需要 **Node.js ≥ 18**（只用标准库，不用 `npm install`）。

```powershell
# Windows：双击 启动.cmd 即可；或命令行：
node pc/src/index.js
```

启动后屏幕会打印三样东西：**手机 App 要填的地址**、**面板地址**、**访问令牌**。

```bash
# 对端/自测都可以先确认服务活着（这个接口无需令牌）
curl "http://127.0.0.1:18787/api/health"
```

没有真机也能验证整条链路——用内置的手机模拟器：

```bash
node tools/phone-sim.js --url ws://127.0.0.1:18787/ingest?token=<你的令牌> --interval 1000
# 然后打开 http://127.0.0.1:18787/?token=<你的令牌> 看面板动起来
```

细节见 [`docs/快速开始.md`](docs/快速开始.md)。

---

## 三种使用方式

### ① 手机 + 同一 WiFi（最简单）

1. 启动电脑端，记下打印的 `ws://<局域网IP>:18787/ingest?token=…`
2. 手机 App 首页把这个地址粘进去
3. 面板 / 分享页都能看到实时数据

### ② 电脑直连心率带（不需要手机）

```powershell
# 1) 编译一次（要求 .NET SDK 8：winget install Microsoft.DotNet.SDK.8）
.\pc\ble\build-ble.ps1

# 2) 先确认电脑能发现心率带（戴好、手机 App 必须停掉）
.\测试蓝牙.cmd

# 3) 开启桥：写进 pc\config.json 或设环境变量后启动
$env:HEALTHLINK_PC_BLE = '1'; node pc/src/index.js
```

配置示例见 [`pc/config.example.json`](pc/config.example.json)：

```json
{ "pcBle": { "enabled": true, "address": "AA:BB:CC:DD:EE:FF" } }
```

> ⚠️ BLE 是**独占**的：心率带同一时刻只能被一个中心连接。手机 App 占着它，电脑永远连不上。
> 排错见 [`pc/ble/README.md`](pc/ble/README.md)（含 `tools/ble-diag` 体检探针）。

### ③ 给外地的人看

- **同局域网**：`.\分享链接.cmd` 列出所有网卡并标注「该发给谁」
- **跨网络**：内网穿透（如樱花穿透）+ 只读分享页，用
  [`tools/sakura-url.js`](tools/sakura-url.js) 自动拼出 HTTPS 地址；App 上传则要用 `wss://`
- 完整流程与踩坑见 [`docs/樱花穿透部署指南.md`](docs/樱花穿透部署指南.md)

---

## 测试

```bash
node pc/test/e2e.test.js               # 53 项：协议 / 并发 / 资源回收 / 关闭流程
node pc/test/bom-tolerance.test.js     #  9 项：BOM 容错
node pc/test/pcble-source-logic.test.js# 10 项：蓝牙数据源纯逻辑（不需要硬件）
node tools/verify-share-page.js        # 12 项：只读分享页断言
node mobile/android/verify-protocol.js # 14 项：安卓端协议断言
pwsh ./tools/check-encoding.ps1        # 编码规范（.ps1 需 BOM、.cmd 需 GBK+CRLF）
```

需要真实硬件的测试（跑不过属正常，别当 bug）：

```bash
node pc/test/pc-ble-e2e.test.js        # 需要心率带 + 手机 App 已停
dotnet run --project tools/ble-diag -- AA:BB:CC:DD:EE:FF 8
```

CI 在 Node 18/20/22 × Ubuntu/Windows 上跑上面这些**不需要硬件**的用例。

---

## 目录结构（精简版）

```
health-link/
├── 启动.cmd / 启动.ps1            双击即启（服务 + 面板）
├── 分享链接.cmd / 分享.ps1        生成只读分享链接
├── 测试蓝牙.cmd                   PC 蓝牙桥体检
├── pc/                            电脑端（Node.js，零依赖）
│   ├── src/                       ws / wsclient / storage / hub / relay / server / config / index
│   ├── web/                       原生 HTML/CSS/JS 面板 + 只读分享页
│   ├── ble/                       PC 蓝牙桥（C#，net8.0-windows）
│   └── test/                      端到端与纯逻辑测试
├── mobile/
│   ├── harmonyos/                 鸿蒙采集端（ArkTS / Stage 模型）
│   └── android/                   安卓采集端（Kotlin / Gradle）
├── tools/                         启动器、打包、诊断、模拟器、穿透地址生成
├── docs/                          协议契约、接口契约、部署与各类排错笔记
└── legal/                         应用内使用的用户协议 / 隐私政策页面
```

完整目录说明见 [`README-技术细节.md`](README-技术细节.md)。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/快速开始.md](docs/快速开始.md) | 5 分钟用模拟器跑通整条链路 |
| [docs/protocol/README.md](docs/protocol/README.md) | ★ 传输协议 v1 冻结契约（含 JSON Schema） |
| [docs/HTTP接口契约.md](docs/HTTP接口契约.md) | 电脑端 REST / WebSocket 完整定义 |
| [docs/手机端安装指南.md](docs/手机端安装指南.md) | 把 App 装到手机上（签名、hdc/adb、错误码） |
| [docs/BLE直连模式.md](docs/BLE直连模式.md) | BLE 直连手表的能力边界与操作流程 |
| [docs/ArkTS严格模式避坑.md](docs/ArkTS严格模式避坑.md) | 34 个真实 ArkTS 编译错误与修法 |
| [docs/新旧API对照与纠错.md](docs/新旧API对照与纠错.md) | 华为健康 API 的 8 处纠错（附官方来源） |
| [docs/长时任务与保活.md](docs/长时任务与保活.md) | 后台保活约束与 10 分钟续期 |
| [docs/部署与验证.md](docs/部署与验证.md) | 真机部署、命令行构建、故障排查 |
| [docs/樱花穿透部署指南.md](docs/樱花穿透部署指南.md) | 给外地的人看数据：完整流程与排错 |
| [pc/ble/README.md](pc/ble/README.md) | PC 蓝牙桥：为什么用 C#、完整排错记录 |
| [docs/README.md](docs/README.md) | 文档总览与架构说明 |

---

## 已知限制

- **数据种类受限于手机系统**：心率普遍可得；血氧/睡眠/压力取决于机型与权限，读不到时会明确报「无此能力」而不是编数据。
- **HarmonyOS 端需要你自己签名**：仓库不含任何证书；首次用 DevEco 打开工程会自动生成调试签名。
- **BLE 独占**：一个心率带同一时刻只能被一个中心（手机或电脑）连接。
- **电脑端不做鉴权体系**：只有一个访问令牌，没有多用户/角色。这是局域网自用场景的刻意取舍，见 [`SECURITY.md`](SECURITY.md)。
- **不会把数据同步到云**：没有云，也没有账号系统。想要异地查看请自行加穿透（文档里有指引）。

---

## 安全与隐私

- 访问令牌即钥匙：**不要把 `pc/config.json` 提交或贴出去**（`.gitignore` 已忽略，示例见 `pc/config.example.json`）。
- 分享页是只读的，但同样认令牌；对外暴露请走带 TLS 的通道，别直接做端口映射。
- 漏洞请走私密渠道报告，见 [`SECURITY.md`](SECURITY.md)。

---

## 贡献

欢迎 issue / PR。**动手前请先看 [`CONTRIBUTING.md`](CONTRIBUTING.md)** ——
这个项目有几条硬性的编码规矩（`.ps1` 必须带 BOM、`.cmd` 必须 GBK+CRLF），
不了解的话很容易把脚本改坏。

---

## 许可

代码以 [MIT](LICENSE) 许可发布。

文档中引用的华为 API 名称、字段枚举、错误码归华为所有，相关文档均已注明官方来源链接；
`tools/offline-registry.js` 仅用于打包 DevEco Studio 随附的第三方依赖供本机离线构建，**请勿再分发**。

本项目与华为、CooSpo 等厂商**没有隶属或背书关系**，仅为个人自用的数据采集工具，
不能替代任何医疗设备或医疗建议。
