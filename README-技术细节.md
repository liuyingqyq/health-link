> 📐 **这份文档是项目的技术细节记录**（架构取舍、逐项实测、踩过的坑）。
> 想先跑起来请看 [README.md](README.md)。

---
# HealthLink

把华为手机上的运动健康数据（心率 / 静息心率 / HRV / 血氧 / 压力 / 睡眠）
**在后台持续采集**，通过局域网实时上传到你自己的电脑；
电脑端再把数据**实时转发给其他人**（浏览器面板或第三方程序）。

> 📖 **新手先看** → [`docs/快速开始.md`](docs/快速开始.md)（5 分钟用模拟器跑通整条链路）
>
> ⚠️ **华为 API 与原始需求有 8 处偏差，其中 2 处会导致功能完全不生效、1 处会把深浅睡画反**
> → [`docs/新旧API对照与纠错.md`](docs/新旧API对照与纠错.md)

```
┌──────────────────────┐     ① WebSocket 长连接（手机主动外连）    ┌─────────────────────┐
│  HarmonyOS 手机 App   │ ──────────────────────────────────────▶ │  电脑端 HealthLink    │
│  HealthLink 采集端    │   hello / sample / batch / ping        │  Hub（接收 + 中继）   │
│                      │                                         │                     │
│  · @kit.HealthServiceKit 读健康数据                              │  ② 实时推送          │
│  · bluetoothInteraction 长时任务保活                             │  → 浏览器实时面板     │
│  · 断线退避重连 + 离线队列                                       │  ③ 主动转发          │
└──────────────────────┘                                         │  → 另一台电脑/服务    │
                                                                 └─────────────────────┘
```

---

## 两个端分别是什么

| | 手机端 | 电脑端 |
| --- | --- | --- |
| 技术栈 | HarmonyOS ArkTS（Stage 模型，API 12+） | Node.js（**零外部依赖**） |
| 目录 | [`mobile/harmonyos/`](mobile/harmonyos) | [`pc/`](pc) + [`pc/web/`](pc/web) |
| 采集 | `@kit.HealthServiceKit` 读心率/静息心率/HRV/血氧/压力/睡眠 | 接收、校验、环形缓冲、按 seq 重放 |
| 后台 | `bluetoothInteraction` + `dataTransfer` 长时任务，5 分钟进度续期 | 单进程常驻 + 断线不退出 |
| 上传 | WebSocket 长连接，断线指数退避 + 离线队列 | `/ingest` 接收 |
| 输出 | App 内实时状态、睡眠分期色带、运行日志 | 可视化面板 + REST + WebSocket 订阅 + 主动转发 |
| 测试 | 无真机，未拿到最终 HAP（见下） | **52 项端到端测试全部通过** |

---

## 电脑端：立刻可跑

**双击 `启动.cmd`**（或想让它顺手打开浏览器就用 `启动.cmd --open`）。

启动器会自己做完这些事：检查 Node.js → 生成访问令牌 → 启动服务 →
等端口就绪 → 把**手机要填的地址**和**面板地址**用框框标出来。关掉窗口即停止服务。

```
  ┌─────────────────────────────────────────────────────────────┐
  │  手机 App 里「电脑地址」填这一行（整行照抄）：              │
  └─────────────────────────────────────────────────────────────┘
      ws://192.168.1.100:18787/ingest?token=0123456789abcdef0123456789abcdef

  ┌─────────────────────────────────────────────────────────────┐
  │  本机浏览器打开面板（看实时数据）：                         │
  └─────────────────────────────────────────────────────────────┘
      http://127.0.0.1:18787/?token=0123456789abcdef0123456789abcdef
```

> 它会**只列出真正的局域网地址**。实测中直接枚举网卡会把 `198.18.x.x`（网络测试保留段）
> 和 `169.254.x.x`（链路本地）也列出来，用户照抄连不上 —— 所以按可用性分了组，
> 非局域网的地址单独标注为「可能是虚拟网卡」。

### 三种启动方式，按你的习惯选

| 你的习惯 | 怎么启动 |
| --- | --- |
| 文件资源管理器里**双击** | 双击 `启动.cmd`（想顺手开浏览器：把 `--open` 加在文件名后面不方便，改用下面两种） |
| 在 **cmd** 窗口里 | `启动.cmd` 或 `启动.cmd --open` |
| 在 **PowerShell** 窗口里 | `.\启动.ps1` 或 `.\启动.ps1 -OpenBrowser 1` |

> ⚠️ **PowerShell 里必须写 `.\` 前缀**。
> 直接敲 `启动.cmd` 会报"无法将'启动.cmd'项识别为 cmdlet…"——
> 这是 PowerShell 的**安全设计**：默认不从当前目录加载命令，与文件是否存在无关。
> 报错里 PowerShell 自己也会提示 "请改为键入 `.\启动.cmd`"。
>
> 另外 PowerShell 里推荐用 `.\启动.ps1`（参数风格更自然：`-OpenBrowser 1` 而不是 `--open`）。

不想用启动器也可以命令行启动：

```bash
cd pc
node src/index.js
```

不需要 `npm install`。然后用模拟器灌数据：

```bash
node tools/phone-sim.js --url "ws://127.0.0.1:18787/ingest?token=<令牌>" --interval 1000 --sleep
```

面板上立刻能看到设备、实时曲线、睡眠分期色带。详见 [`docs/快速开始.md`](docs/快速开始.md)。

### 电脑端的「长加载」怎么实现的

Android/HarmonyOS 那套长时任务是**移动端系统概念**，PC 上没有对应机制，
但目的一致（进程不退出、断线不放弃、数据不丢）。对应关系：

| 移动端机制 | 电脑端等价实现 | 位置 |
| --- | --- | --- |
| 长时任务保活 | 单进程常驻 + 未捕获异常兜底（记日志但**不退出**） | `pc/src/index.js` |
| 断线重连 | 转发目标各自长连接，1s→30s 指数退避，永不放弃 | `pc/src/relay.js` |
| 离线队列 | 发不出去进队列（默认 20000 条），恢复后按序补发 | `pc/src/relay.js` |
| 通知栏常驻 | 面板状态条 + `/api/stats` 实时指标 | `pc/web/app.js` |
| 被回收后恢复 | 转发目标持久化到 `forwards.json`，重启自动恢复 | `pc/src/relay.js` |

### 为什么电脑端连 WebSocket 都自己写

需求要求完全离线可跑。`ws` 包很好，但这里装不了；而所需功能只是 RFC 6455 的一个
小子集。自己实现反而更可控 —— 顺手在里面修掉了两个真实缺陷（见下）。

---

## 手机端：怎么装到手机上

**完整步骤见 → [`docs/手机端安装指南.md`](docs/手机端安装指南.md)**

简要流程（约 10 分钟）：

| # | 做什么 |
| --- | --- |
| 1 | 手机上：连点「版本号」7 次开开发者模式 → 打开 USB 调试 → 数据线连电脑 |
| 2 | DevEco Studio 打开 **`phone`** 目录 → `Project Structure → Signing Configs` → 勾选**自动生成签名** → 登录华为开发者账号 |
| 3 | 点绿色 ▶ Run，自动编译安装并启动 |

装完还需要在 AGC 申请健康数据权限才能真正采到数据（**人工审核约 15 个工作日**）。
**没有审批也能验证链路**：先用 `tools/phone-sim.js` 从电脑端灌模拟数据。

### 手机端 HAP：命令行就能构建 ✅

```powershell
# 双击 构建.cmd，或者：
.\tools\build-phone.ps1            # 增量构建
.\tools\build-phone.ps1 -Clean     # 全量重建
```

实测输出：

```
[OK] 构建成功（6.2 秒）
     ArkTS 错误 0 个，警告 0 个
  产物: mobile\harmonyos\entry\build\default\outputs\default\entry-default-unsigned.hap
  大小: 523.3 KB
```

⚠️ 命令行产出的是**未签名** HAP，不能直接装。**要装到手机上，须在 DevEco Studio 里
配置自动签名**（`File → Project Structure → Signing Configs` → 勾选
`Automatically generate signature` → 登录华为账号 → Apply → Run）。
原因：调试签名需要华为账号在线申请证书与 Profile，这一步无法离线代劳。

命令行构建有两个**必须**的环境变量（脚本已内置，手工敲命令时容易漏）：

| 变量 | 缺了会怎样 |
| --- | --- |
| `DEVECO_SDK_HOME` | 报 `Invalid value of 'DEVECO_SDK_HOME'` |
| `java` 在 `PATH` 里 | 报 `spawn java ENOENT`（在 `PackageHap` 阶段才报，前面编译都成功，**极易误判成代码问题**） |

首次在 DevEco 里编译时曾报 **34 个 ArkTS 错误**（ArkTS 的严格模式和 TypeScript 不同），
已全部修掉。每条规则、每个真实报错、修法都记在
[`docs/ArkTS严格模式避坑.md`](docs/ArkTS严格模式避坑.md) —— 一份很实用的避坑清单。

---

## 把数据分享给别人

分三种情况，按简单程度排列：

### ① 对方和你在同一个 Wi-Fi

```powershell
# 双击 分享链接.cmd —— 会列出所有网卡，并标注每条该发给谁
.\分享链接.cmd
```

它会自动枚举所有网卡（Wi-Fi、有线、虚拟机、蒲公英/Tailscale 虚拟网卡），
**逐条标注用途**并自测可达性，你只要挑标着「同一个 Wi-Fi 下的人用这条」的那条发出去。

也可以直接双击 `分享.cmd` 只拿最快的一条：

```powershell
.\分享.ps1
```

对方用浏览器打开即可，**不用装任何东西**。页面是纯只读的（无 `fetch`/XHR，已由
`tools/verify-share-page.js` 的 12 项断言验证）。

> ⚠️ **`192.168.x.x` 这类地址只有同一局域网能用。** 外地的人打开会报
> `ERR_CONNECTION_TIMED_OUT` —— 那不是故障，是私有地址本身无法被外网路由。
> 跨网络必须先组网（见下），再用 `分享链接.cmd` 里标着「组网工具地址」的那条。

### ② 对方在外地

先让对方运行**接收端包**：

```powershell
# 打包（生成 dist\HealthLink 健康数据接收端.zip，约 75 KB）
.\tools\build-receiver-package.ps1
```

把 zip 发给对方 → 他解压后双击 `启动.cmd` → 屏幕上会显示一行 `ws://...` 地址
→ 他发给你 → 你双击 `tools\远程共享\远程共享.cmd`，把那行地址粘进去。

向导会自动测连通性并登记为转发目标。**登记一次以后，每次启动服务都会自动连过去。**

> 跨网络还需要一条"通道"。最省事的是组网工具（蒲公英 / Tailscale / ZeroTier），
> 两边都装、加入同一网络，把地址里的 IP 换成组网 IP 即可。向导里也写了这一段。

### ③ 自己验证

```powershell
# 接收端包冒烟测试：解压 → 走真实启动路径 → 验证服务 → 清理
.\tools\test-receiver-package.ps1
```

---

## 让电脑直接用蓝牙连心率带（不需要手机）

**适用场景**：你主要在电脑前，不想让手机参与，也不想折腾网络穿透。

```
心率带 ──BLE──> 电脑 ──> 面板 / 分享页 / 转发
       ↑
   只有一段蓝牙，手机和网络问题全部消失
```

### 三步开启

```powershell
# 1) 编译（只需一次；要求 .NET SDK 8：winget install Microsoft.DotNet.SDK.8）
.\pc\ble\build-ble.ps1

# 2) 先确认电脑能发现心率带（戴好心率带、关掉手机 App！）
#    双击 测试蓝牙.cmd —— 看到 "广播180D=是" 就说明能发现

# 3) 开启桥
$env:HEALTHLINK_PC_BLE = '1'
.\启动.ps1
```

或者写进 `pc/config.json`（**可以跳过扫描，更快更稳**）：

```json
{
  "authToken": "你的令牌",
  "pcBle": { "enabled": true, "address": "AA:BB:CC:DD:EE:FF" }
}
```

开启后设备以固定 ID `pc-ble-local-hr-0001` 出现在**面板、订阅者、分享页、转发目标**里，
和手机上报的设备完全一视同仁。心率之外还会从 RR 间期算出 **HRV（RMSSD）**。

> ⚠️ **BLE 是独占的**：心率带同一时刻只能被一个"中心"持有。
> **手机 App 占着它，电脑就永远连不上**——必须先停手机 App。
>
> ⚠️ 若报 `AccessDenied`：这是 Windows 的 GATT 缓存陈旧，**桥已内置 Uncached 重试自动绕过**；
> 也可以把电脑蓝牙开关关掉再打开来清除。

详见 [pc/ble/README.md](pc/ble/README.md)（含完整排错记录）。

---

## 测试

```bash
node pc/test/e2e.test.js              # 52 项协议/并发/资源回收
node pc/test/bom-tolerance.test.js    # 9 项 BOM 容错
node pc/test/pc-ble-e2e.test.js       # 5 项 PC 蓝牙桥端到端（需心率带+停手机App）
node tools/verify-share-page.js       # 12 项只读分享页协议断言
```

**52 项全部通过。** 测试过程中**真实发现并修复了 5 个缺陷**：

| # | 缺陷 | 后果 |
| --- | --- | --- |
| 1 | `parseHeaders` 把 Node 的 `rawHeaders`（**扁平数组**）当成 `"Name: value"` 字符串数组 | **所有 WebSocket 握手返回 400**，上行链路完全不可用 |
| 2 | 协议错误后未停止解析，出错的那一帧一个字节都没被消费 | 同一帧被**反复解析**，error 刷屏、CLOSE 发不出、**CPU 打满** |
| 3 | 转发目标 `upsert` 替换时直接丢弃旧队列 | 已收到未发出的数据**永久丢失** |
| 4 | 订阅者重放用内部 `order` 比较业务 `seq` | 多设备时**重放错数据或漏数据** |
| 5 | 主动 close 后把对端回来的 CLOSE 帧一起挡掉 | 关闭码上报错误（4401 记成 1006） |

---

## 华为 API 纠错（最重要的 4 条）

| # | 你原始需求 | 实际情况 | 影响 |
| --- | --- | --- | --- |
| 1 | 权限名 `HEALTH_DATA_READ`，"个人可申请" | **该权限名官方查无来源**。真实模型是「AGC 申请数据权限（中文权限项）∩ 运行时 `requestAuthorizations()` 用户授权」；开放等级官方叫"基础/高阶" | 照原样写，权限**完全不生效** |
| 2 | 睡眠分期 `sleepState`：1=浅睡，3=深睡 | 字段名是 **`sleepStatus`**，且 **1=深睡、2=浅睡、3=REM、4=清醒** | 深浅睡**完全画反**，误导使用者 |
| 3 | `snoreFreq`/`avgHeartRate`/`avgOxygenSaturation`/`avgBreathRate`/`avgHrv` | 这 5 个字段在新版 `healthFields.Sleep` 里**不存在** | 取不到值，须另查后按时间窗对齐 |
| 4 | `ContinuousTaskExtensionAbility` 接系统回调 | **查无此 API**；Stage 模型长时任务**只有 UIAbility 能申请** | 编译不过 / 无效 |

另外 4 条（`WindowStage.onCreate` 不存在、`getAppPreloadType` 是 API 22+、
`AbilityStage` 必须在 module.json5 用 `srcEntry` 声明、`DATA_TRANSFER` 长时任务
10 分钟不更新进度会被取消）见 [`docs/新旧API对照与纠错.md`](docs/新旧API对照与纠错.md)。

---

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/快速开始.md](docs/快速开始.md) | 5 分钟用模拟器跑通 |
| [docs/README.md](docs/README.md) | 总览、架构、已知限制 |
| [docs/protocol/README.md](docs/protocol/README.md) | ★ 传输协议 v1 冻结契约 |
| [docs/protocol/health-sample.schema.json](docs/protocol/health-sample.schema.json) | 样本载荷 JSON Schema |
| [docs/HTTP接口契约.md](docs/HTTP接口契约.md) | 电脑端 REST / WebSocket 完整定义 |
| [docs/手机端安装指南.md](docs/手机端安装指南.md) | ★ 怎么把 App 装到手机上（含签名、hdc、错误码对照） |
| [docs/BLE直连模式.md](docs/BLE直连模式.md) | ★ BLE 直连读手表数据：能力边界、操作流程、排错 |
| [docs/版本兼容说明.md](docs/版本兼容说明.md) | ★ HarmonyOS 5/6/7 与 API level 对应、装不上时怎么改 |
| [docs/ArkTS严格模式避坑.md](docs/ArkTS严格模式避坑.md) | ★ 34 个真实 ArkTS 编译错误与修法（含 SDK 的 SlotType 缺陷） |
| [docs/新旧API对照与纠错.md](docs/新旧API对照与纠错.md) | ★ 8 处纠错 + 官方来源 URL |
| [docs/长时任务与保活.md](docs/长时任务与保活.md) | 后台保活约束、10 分钟续期、预加载 |
| [docs/部署与验证.md](docs/部署与验证.md) | 真机部署、命令行构建、故障排查 |
| [pc/web/README.md](pc/web/README.md) | 可视化面板说明 |
| [pc/ble/README.md](pc/ble/README.md) | ★ PC 蓝牙桥：让电脑直连心率设备（C#，需 .NET SDK 8） |
| [tools/README.md](tools/README.md) | tools 目录索引（构建/诊断/验证脚本怎么用） |
| [docs/樱花穿透部署指南.md](docs/樱花穿透部署指南.md) | ★ **电脑直连心率带 + 樱花穿透发给外地的人**（完整流程与排错） |

---

## 目录结构

```
health-link/
├── 启动.cmd                       ★ 双击即用（电脑端服务 + 面板）
├── 启动.ps1                       ★ PowerShell 入口：.\启动.ps1 -OpenBrowser 1
├── 构建.cmd                       ★ 双击即用（构建鸿蒙端 HAP）
├── 管理.cmd / 管理.ps1             ★ 中文菜单：查看信息 / 转发目标管理 / 统计
├── 分享.cmd / 分享.ps1             ★ 生成只读分享链接（给同一局域网的人看）
├── 分享链接.cmd                    ★ 列出所有网卡的分享链接，并标注该发给谁
├── 测试蓝牙.cmd                    ★ 测电脑能否直接发现心率带（PC 蓝牙桥）
├── dist/                          分发包输出（打包脚本生成，已 gitignore）
│   └── HealthLink 健康数据接收端.zip   ★ 直接发给外地的家人
├── docs/                          全部中文文档
│   ├── 手机端安装指南.md           ★ 手机端怎么装
│   ├── BLE直连模式.md              ★ BLE 直连能力边界与排错
│   ├── ArkTS严格模式避坑.md        ★ 34 个真实编译错误与修法
│   └── protocol/                  协议契约
├── mobile/                        ★ 手机端（两个平台放一起）
│   ├── harmonyos/                 鸿蒙工程（ArkTS / Stage 模型）
│   │   ├── hvigorfile.ts          DevEco 识别工程所必需（缺了会报"不包含项目"）
│   │   ├── AppScope/
│   │   └── entry/
│   │       ├── hvigorfile.ts
│   │       └── src/main/
│   │           ├── module.json5   权限（含蓝牙）+ backgroundModes + AbilityStage 声明
│   │           ├── ets/
│   │           │   ├── entryability/  EntryAbility + MyAbilityStage（预加载检测）
│   │           │   ├── ble/           BleClient（扫描/连接/GATT/订阅通知/心率解析）
│   │           │   ├── health/        HealthSource 接口 + BLE 与 HealthKit 两个实现
│   │           │   ├── service/       采集编排 + 长时任务管理
│   │           │   ├── transport/     传输抽象 + 局域网 WebSocket 实现
│   │           │   ├── model/         协议类型定义
│   │           │   ├── common/        日志 / 偏好存储
│   │           │   └── pages/         Index（主界面）+ BleDevices（蓝牙设备页）
│   │           └── resources/
│   └── android/                   安卓工程（Kotlin / Gradle）
│       ├── build-apk.ps1          ★ 一键编译 APK（内置 JDK/Gradle 环境变量）
│       ├── app/src/main/java/com/healthlink/collector/
│       │   ├── source/            HealthSource 接口 + 模拟/BLE/华为 SensorPro 三实现
│       │   ├── protocol/          信封 / 离线队列 / 序号 / 设备标识
│       │   ├── net/               OkHttp WebSocket 传输
│       │   ├── service/           前台服务（采集 + 上传）
│       │   └── ui/                MainActivity
│       ├── dist/                  编译出的 APK
│       └── verify-protocol.js     14 项协议断言
├── pc/                            电脑端（Node.js，零外部依赖）
│   ├── src/                       ws / wsclient / storage / hub / relay / server / config / index
│   ├── web/                       零依赖可视化面板（原生 HTML/CSS/JS）
│   ├── ble/                       ★ PC 蓝牙桥（C#）：让电脑直连心率设备
│   │   ├── BleHrBridge.cs         扫描→连接→订阅 180D/2A37→输出 JSON Lines
│   │   ├── BleHrBridge.csproj     目标 net8.0-windows10.0.19041.0（零 NuGet 包）
│   │   ├── build-ble.ps1          一键编译（含 .NET SDK 前置检查）
│   │   └── README.md              为什么要 C#、怎么排错
│   └── test/                      端到端测试
│       ├── e2e.test.js            52 项协议/并发/资源回收测试
│       └── bom-tolerance.test.js  9 项 BOM 容错测试
└── tools/
    ├── launcher-core.ps1          启动器的实际逻辑（两个入口都调它）
    ├── 远程共享/                     ★ 远程共享向导（中文问答，给外地家人用）
    │   └── 远程共享.cmd / .ps1     双击即用：粘贴对方地址 → 自动测连通 → 登记转发
    ├── receiver-template/          ★ 接收端包的模板（启动脚本 + 说明）
    │   ├── 启动.ps1 / 分享.ps1     接收方用的一键启动与分享
    │   └── 说明-给*.md             接收方 / 分享方各一份中文说明
    ├── build-receiver-package.ps1  ★ 打包接收端 zip（含 BOM 校验与中文路径校验）
    ├── test-receiver-package.ps1   ★ 接收端包冒烟测试（解压→启动→验证→清理）
    ├── check-encoding.ps1          ★ 编码规范终检（.ps1 / .cmd / .json 的 BOM 与行尾）
    ├── 分享链接.ps1                 ★ 枚举所有网卡生成分享链接，并标注「该发给谁」
    ├── netcheck.js                 网络诊断：公网 IP / CGNAT / UDP / 组网工具可达性
    ├── share-url.js                生成给对方的浏览器网址，并逐条实测
    ├── pgy-scan.js                 扫描蒲公英虚拟网段，看对方是否已加入
    ├── phone-sim.js               手机端模拟器（无真机也能验证全链路）
    ├── make-icons.js              生成 216x216 应用图标（纯 Node，无依赖）
    ├── verify-share-page.js       只读分享页的 12 项协议断言
    ├── offline-registry.js        离线 npm registry（已不再需要，保留备查）
    └── build-phone.ps1            命令行构建 HAP（内置必需的环境变量）
```

> ⚠️ **编码规则（踩过坑，务必照做）**：
>
> | 文件 | 编码 | BOM | 行尾 |
> |---|---|---|---|
> | `.ps1` | UTF-8 | **必须有** | 任意 |
> | `.cmd` | **GBK(cp936)** | **必须没有** | CRLF |
>
> - `.ps1` 少了 BOM，Windows PowerShell 5.1 会按 GBK 读 → 中文变坏字节 → 一堆语法错误。
> - `.cmd` 加了 BOM，cmd.exe 会把 BOM 当成命令的一部分 → **窗口一闪就关**。
> - `.cmd` 存成 UTF-8 也不行：cmd 按系统代码页读批处理，中文（含中文文件名引用）
>   会被拆坏。**所以 `.cmd` 一律用 GBK 存，且内容尽量纯 ASCII**，中文界面交给 `.ps1`。
> - 打包脚本 `build-receiver-package.ps1` 已内置 BOM 校验，不合格会直接拒绝打包。

> 整个项目是**自包含、可移动**的：所有构建缓存都写在项目内的 `.build-cache/`，
> 不会往用户目录或上级目录丢任何东西。把 `health-link` 整个拷到别处即可继续用。
> `mobile/harmonyos/local.properties` 记录的是本机 DevEco 路径，换机器时参考
> `mobile/harmonyos/local.properties.example` 重建（该文件已被 `.gitignore` 忽略）。

---

## 许可

本项目代码为示例/教学性质。文档中引用的华为 API 名称、字段枚举与错误码归华为所有，
已注明官方来源 URL。`tools/offline-registry.js` 仅打包 DevEco Studio 随包提供的
第三方依赖，供本机离线构建使用，请勿再分发。
