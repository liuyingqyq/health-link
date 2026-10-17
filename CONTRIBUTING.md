# 给贡献者的说明

先说结论：**这个项目对"能不能跑起来"的要求比一般项目高**，因为它同时涉及
Node.js、C#（WinRT 蓝牙）、HarmonyOS ArkTS、Android Kotlin 四种东西，
而且有几个**编码/换行**的硬规矩（踩过坑，见下）。花两分钟看完这篇能省你半天。

---

## 1. 环境要求

| 你要改的部分 | 需要装什么 |
|---|---|
| 电脑端（`pc/`） | **Node.js ≥ 18**（零第三方依赖，不用 `npm install`） |
| PC 蓝牙桥（`pc/ble/`） | **.NET SDK 8**（`winget install Microsoft.DotNet.SDK.8`） |
| 鸿蒙端（`mobile/harmonyos/`） | DevEco Studio（含 HarmonyOS SDK） |
| 安卓端（`mobile/android/`） | Android SDK + JDK 17/21（`mobile/android/build-apk.ps1` 会自己找） |

只改电脑端的话，装个 Node 就能干活，其余都可以不装。

---

## 2. 跑起来 & 跑测试

```bash
# 启动电脑端（Win 双击 启动.cmd 也一样）
node pc/src/index.js

# 不需要任何硬件就能跑的核心测试
node pc/test/e2e.test.js            # 协议 / 并发 / 资源回收（52 项）
node pc/test/bom-tolerance.test.js  # BOM 容错（9 项）
node pc/test/pcble-source-logic.test.js  # 蓝牙数据源纯逻辑（10 项，不需要蓝牙带）
node tools/verify-share-page.js     # 只读分享页断言（12 项）
node mobile/android/verify-protocol.js   # 安卓端协议断言（14 项）
```

需要真机的测试（不装硬件跑会失败，别当 bug）：

- `node pc/test/pc-ble-e2e.test.js` —— 需要心率带 + 手机 App 已停
- `dotnet run --project tools/ble-diag -- AA:BB:CC:DD:EE:FF 8` —— BLE 体检探针

---

## 3. ⚠️ 编码规矩（最容易把仓库改坏的一条）

Windows 上的 PowerShell / 批处理对编码极其敏感，仓库里有一份自动检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check-encoding.ps1
```

| 文件类型 | 编码 | BOM | 行尾 |
|---|---|---|---|
| `.ps1` | UTF-8 | **必须有 BOM** | 任意 |
| `.cmd` | **GBK (cp936)** | **必须没有 BOM** | CRLF |
| `.json` | UTF-8 | 不要 BOM | 任意 |
| `.js` / `.md` / `.cs` / `.kt` / `.ets` | UTF-8 | 不要 BOM | 任意 |

原因：`.ps1` 少了 BOM，Windows PowerShell 5.1 会按 GBK 读 → 中文变乱码字节 → 一堆语法错误；
`.cmd` 加了 BOM，cmd.exe 会把 BOM 当命令 → 窗口一闪就关。

**提交前请跑一遍上面的检查脚本**，它会把不合格的文件列出来。

---

## 4. 提交约定

- 一个 PR 只做一件事。修 bug 和重构不要混在一起。
- 提交信息用中文或英文都行，但要说清**改了什么、为什么改**。
- 新增/修改行为请补测试（纯逻辑测试不需要硬件，优先走这条）。
- 不要提交这些（`.gitignore` 已覆盖，但别用 `git add -f` 绕过）：
  - `pc/config.json`、`pc/forwards.json`（含令牌）
  - `pc/ble/bin|obj/`、`mobile/android/.tooling/`、`dist/`、`mobile/android/dist/`
  - 任何 `.p12/.p7b/.cer/.jks` 证书与 `build-profile.json5` 里的口令
- 涉及用户数据的改动，先读 [`SECURITY.md`](SECURITY.md)。

---

## 5. 代码风格

- 电脑端：CommonJS、`'use strict'`、4 空格缩进、**不引入第三方依赖**
  （项目刻意保持"下载即可跑"，加依赖需要充分理由）。
- 注释写**为什么**，不写"这里给变量赋值"这种废话。
- 中文文案保持简体中文；标识符、命令、日志字段用英文。

---

## 6. 报告问题

开 issue 请带上：

1. 你跑的命令 + 完整输出（日志请整段贴，不要只贴错误那一行）
2. 电脑端：`node --version`、`/api/health` 的返回
3. 蓝牙相关：`tools/ble-diag` 的输出（会打印无线电状态、扫描包数、GATT 服务列表）
4. 手机端：机型、HarmonyOS/Android 版本、`hdc`/`adb` 报错原文

安全相关问题请走私密渠道，见 [`SECURITY.md`](SECURITY.md)。
