# HealthLink PC 蓝牙桥（电脑直连心率设备）

让**电脑自己**通过蓝牙直连心率设备（如 CooSpo HW9 心率臂带），
把心率注入 HealthLink 服务端。**这样就不需要手机参与，也不需要网络穿透。**

---

## 它解决什么问题

原来的链路：

```
心率带 ──BLE──> 手机 App ──网络──> 电脑 ──> 面板/分享
                              ↑
                    这一段受 CGNAT、IPv6、USB 共享等一堆网络问题影响
```

用这个桥之后：

```
心率带 ──BLE──> 电脑 ──> 面板/分享
       ↑
   只有一段蓝牙，网络问题全部消失
```

**代价**：电脑不会跟着你走。你戴着心率带走动时，还是得用手机。

---

## 目录里是什么

| 文件 | 说明 |
|---|---|
| `BleHrBridge.cs` | 主程序：扫描 → 连接 → 订阅心率通知 → 输出 JSON Lines |
| `BleHrBridge.csproj` | 项目文件（目标 `net8.0-windows10.0.19041.0`） |
| `build-ble.ps1` | 一键编译脚本 |

---

## 为什么要用 C# 而不是 Node 的 BLE 库

试过三条路，只有 C# 走得通：

| 方案 | 结果 |
|---|---|
| Node 的 `noble` 等 BLE 库 | ❌ 需 npm 下载原生模块，本机 npm 源不可用；且与 Node 24 兼容性差 |
| .NET Framework 自带的 `csc.exe` | ❌ 它是 C# 5，编译 WinMD 时缺少 Windows 外观程序集，WinRT 异步 API 编译不过 |
| PowerShell 5.1 直接调 WinRT | ❌ 它不认识 WinRT 的泛型委托（`TypedEventHandler`）和异步扩展 |
| **.NET 8 SDK + `net8.0-windows10.0.19041.0`** | ✅ **内置 Windows SDK 投影，零 NuGet 包** |

`.NET 8` 对该 TFM 内置 WinRT 支持，所以**不需要任何 NuGet 包**——
与本项目"零外部依赖"的约束一致。

---

## 编译

### 前置条件：.NET SDK 8

```powershell
# 检查
dotnet --list-sdks

# 没有就装（一条命令）
winget install Microsoft.DotNet.SDK.8
```

> 注意：**运行时**（`Microsoft.NETCore.App`）通常系统已有，
> 但那只能"跑"，不能"编译"。**必须有 SDK**。

### 编译

```powershell
# 双击 build-ble.ps1，或者：
.\build-ble.ps1
```

产物：`bin\Release\net8.0-windows10.0.19041.0\win-x64\HealthLinkBle.exe`

> ⚠️ `bin\` 里有约 24 MB 的 Windows SDK 运行时 DLL，**不要手动删**——
> 它们是 exe 运行所需的，删了 exe 就跑不起来（重新编译即可恢复）。
> 该目录已被 `.gitignore` 忽略。

---

## 命令行用法

```
HealthLinkBle.exe [选项]

选项：
  --name <串>          设备名匹配（如 HW9）。留空则取第一个广播 180D 的设备
  --address <MAC>      直接指定蓝牙地址（如 AA:BB:CC:DD:EE:FF），跳过扫描
  --scan-timeout <秒>  扫描超时，默认 25
  --reconnect-delay <秒> 断线后重连间隔，默认 5
  --verbose            打印扫描到的每个设备（排错用）
```

### 先测试能不能发现设备

```powershell
# 项目根目录的 测试蓝牙.cmd（双击），或：
.\bin\Release\net8.0-windows10.0.19041.0\win-x64\HealthLinkBle.exe --verbose --scan-timeout 60
```

**看到 `广播180D=是` 就说明电脑发现了你的心率带。**

---

## 输出协议（JSON Lines）

每行一个 JSON，交给 Node 侧消费：

```jsonc
{"t":"ready"}                                      // 桥已启动
{"t":"scan"}                                       // 开始扫描
{"t":"found","name":"HW9-12345","id":"AA:BB:CC:DD:EE:FF"}
{"t":"connecting","id":"AA:BB:CC:DD:EE:FF"}        // 正在连接
{"t":"connected","name":"HW9-12345","id":"..."}    // 已连接并订阅成功
{"t":"battery","percent":85}                       // 电量（读失败则不发）
{"t":"hr","bpm":98,"rr":[800],"contact":true}      // 心率（核心数据）
{"t":"disconnected","reason":"设备侧断开"}
{"t":"error","msg":"..."}                          // 错误（附中文原因）
{"t":"log","msg":"..."}                            // 调试信息
```

### 心率数据格式（蓝牙 SIG 标准）

心跳带按标准格式上报，解析规则：

```
byte0 = flags
  bit0 = 0 → 心率是 uint8（byte1）
  bit0 = 1 → 心率是 uint16 小端（byte1~2）
  bit2 = 传感器接触状态（1=检测到皮肤接触）
  bit3 = 是否含能量消耗字段（跳过 2 字节）
  bit4 = 是否含 RR 间期（每个 2 字节，单位 1/1024 秒）
```

---

## 排错

### 扫描到 0 个包

**先确认电脑蓝牙是开的**（不是飞行模式）：

```
设置 → 蓝牙和其他设备 → 蓝牙开关应为「开」
```

### 扫到了别的设备，但就是没有心率带

按这个顺序排查：

| 检查 | 说明 |
|---|---|
| **1. 心率带戴在手臂上了吗** | 多数心率带**靠皮肤接触才通电广播**，不戴就完全不广播 |
| **2. 手机 App 停了吗** | **BLE 设备同一时刻只能被一个中心连接**。手机占着它，电脑永远扫不到 |
| **3. 手机蓝牙关了吗** | 最好直接在手机系统蓝牙里断开该设备 |
| **4. 靠电脑近一点吗** | BLE 有效距离约 10 米，隔墙会明显衰减 |

### 报"这个设备没有标准心率服务(0x180D)"

说明该设备（**华为手表就是这种**）把心率放在**厂商私有协议**里，
标准蓝牙读不到，需要厂商 SDK（HUAWEI Research SensorPro）。
**标准心率带（CooSpo、Polar、Garmin 等）不会有这个问题。**

### 编译报 "No .NET SDKs were found"

只装了运行时，没装 SDK。执行 `winget install Microsoft.DotNet.SDK.8`。

---

## 技术备注

### 为什么 `Start()` 之后 `Status` 还是 `Created`

`BluetoothLEAdvertisementWatcher.Start()` 是**异步**的，
立刻读 `Status` 会得到 `Created`。要等约 1 秒才变成 `Started`。
**所以不能靠读完 `Status` 就判断扫描是否成功。**

### 为什么不用 `--name` 也能找到设备

心率带常常**不广播设备名**（名字放在扫描响应里，或干脆没有）。
所以匹配逻辑是"**广播里带 180D 标准心率服务** 或 **名字匹配 `--name`**"，
两条判据取或。**按服务 UUID 判断比按名字可靠得多。**

### 扫描模式

默认用 `Passive`（被动）。实测本机 `Active` 模式偶发收不到包，
而 `Passive` 能稳定收到广播。代价：拿不到扫描响应里的名字，
所以更需要按 180D 判断（见上）。

---

## 当前进度

| 部分 | 状态 |
|---|---|
| C# 桥（扫描/连接/订阅/解析） | ✅ 完成，编译 0 警告 0 错误 |
| 实测发现并连接心率带 | ✅ **已实测成功**（HW9-12345，读到心率 + RR 间期 + 电量） |
| Node 侧消费（spawn + 注入 hub） | ✅ 完成（`pc/src/pcBleSource.js`） |
| 端到端验证 | ✅ **5/5 通过**（`pc/test/pc-ble-e2e.test.js`） |

---

## 接入服务端（怎么开启）

桥**默认关闭**（避免没编译 exe 时反复报错）。开启方式二选一：

**方式一：环境变量**
```powershell
$env:HEALTHLINK_PC_BLE = '1'
.\启动.ps1
```

**方式二：写进 `pc/config.json`**
```json
{
  "authToken": "你的令牌",
  "pcBle": {
    "enabled": true,
    "address": "AA:BB:CC:DD:EE:FF"
  }
}
```

### 可配置项

| 字段 | 作用 |
|---|---|
| `enabled` | 是否启用（也可用 `HEALTHLINK_PC_BLE=1` 临时开） |
| `deviceName` | 设备名匹配串（如 `HW9`）；留空则取第一个广播 `180D` 的设备 |
| `address` | **直接指定蓝牙地址，跳过扫描**（更稳，省 10-30 秒） |
| `scanTimeoutSec` | 扫描超时，默认 25 |
| `reconnectDelaySec` | 断线重连间隔，默认 5 |
| `exePath` | 自定义 exe 路径（一般不用写） |

### 开启后会发生什么

1. 服务启动 → 派生 `HealthLinkBle.exe` → 扫描并连接心率带
2. 设备以固定 ID `pc-ble-local-hr-0001` 注册进服务端
3. 心率（**以及从 RR 间期算出的 HRV**）开始入库
4. **面板、订阅者、分享页、转发目标全部能看到它**——和手机上报的设备完全一致

### 查看状态

```powershell
# 桥状态：设备名、连接状态、电量、最近心率、已入库条数
curl "http://127.0.0.1:18787/api/pcble?token=<你的令牌>"
```

---

## 端到端测试

```powershell
# 会自动起一个临时服务、开桥、等心率进来、再验证 REST 能读到
node pc\test\pc-ble-e2e.test.js
```

**注意**：跑测试前要确保手机 App 已停止、心率带已佩戴。

---

## 实际排错记录（都是真踩过的）

### `AccessDenied` —— 最坑的一个

现象：**能查到 180D 服务，但读 2A37 特征返回 `AccessDenied`，且只用了 9 毫秒**。

```
1800 设备信息     特征 4 个  ✅
fd00 厂商私有     特征 4 个  ✅
180f 电量         特征 1 个  ✅
180a 设备信息     特征 6 个  ✅
180d 心率服务     特征 0 个  ❌ AccessDenied     ← 只有它被拒
```

原因：**Windows 的 GATT 缓存陈旧**。设备被反复连接/断开过之后，缓存里会留下无法访问的状态。

**修法：改用 `BluetoothCacheMode.Uncached` 重新查询。** 现在桥里的逻辑是
"先默认查 → 失败则等 500ms 用 Uncached 重试"，实测能稳定绕过。

> 另一个佐证：**把电脑蓝牙开关关掉再打开**也能清除这个状态。两者都可以。

### 编译报 "文件被 HealthLinkBle 锁定"

说明**上一次运行留下了孤儿进程**。桥被 `kill()` 时子进程可能不会立刻退出。

```powershell
Get-Process -Name HealthLinkBle | Stop-Process -Force
```

然后再编译。**测试脚本也会留孤儿**，跑完测试建议顺手清一下。

### 扫描到 0 个包

**先确认电脑蓝牙是开的**（不是飞行模式）。另外注意：
`BluetoothLEAdvertisementWatcher.Start()` 是异步的，
立刻读 `Status` 会得到 `Created`，要等约 1 秒才变 `Started`。

---

## 2026-10-17 排错追加：一次真实的"连不上"到底卡在哪

现场日志长这样，每 5 秒一轮，能刷满整个控制台：

```
[pcBle] 发现设备 (ָ����ַ) [AA:BB:CC:DD:EE:FF]
[pcBle] 正在连接 [AA:BB:CC:DD:EE:FF]…
[pcBle] �޷���ȡ�豸���󣨿����ѱ���������ռ�ã�
[pcBle] 设备断开：�ȴ�����，等待重连
```

用 `tools\ble-diag` 探针逐层拆，结论分三件事，全部已修：

### ① 中文全是乱码 —— 子进程 stdout 编码不对

`Console.Out` 默认走控制台代码页（中文 Windows = GBK/936），Node 端按 UTF-8 解码，
于是 `(指定地址)` 变成 `(ָ����ַ)`，还被写进了 `/api/pcble` 和设备名里。

修法：`Main` 开头显式 `Console.OutputEncoding = new UTF8Encoding(false)`。
实测输出变成 `E6 A1 A5`（"桥"）的 UTF-8 字节，端点与面板都正常了。

### ② "无法获取设备对象" 是个死胡同，不是最终结论

`BluetoothLEDevice.FromBluetoothAddressAsync()` 只在这个地址**当前还在系统 LE 缓存里**
（设备正在广播，或刚广播过）时才返回对象，否则直接返回 `null` —— 而原来的代码
拿到 `null` 就报错、睡 5 秒、再来一遍，永远走不到"到底是设备没广播还是被占用"这一步。

现在的处理顺序：

1. 先用**一次短扫描**（默认 ≤10 秒）探路，把"收到多少个广播包"打出来：
   - 0 个包 → 明确说"问题在电脑蓝牙扫描栈，关一下蓝牙开关再打开"，不再让人猜
   - 有包但没目标 → 明确说"设备没戴/没电，或正被手机连着"
   - 见到目标 → 继续连（顺带把设备塞进系统缓存，下一步成功率更高）
2. 按地址取对象；拿不到 → 退回**系统已配对设备库**，用 `DeviceInformation` 查
   `DeviceId` 再 `FromIdAsync` 打开（已配对设备即使不在广播，这条路也常常能拿到）
3. 两条都不行才报错，并且报的是可操作的三种原因
4. 失败重连改成**退避**：5 → 10 → 20 → 40 → 60 秒封顶，不再 5 秒一轮刷屏

### ③ `AccessDenied` 会持续几十秒，是"上一次连接没散干净"

杀掉旧的 `HealthLinkBle`（或它崩了）之后立刻重连，Windows 侧会先返回一段时间的
`AccessDenied`（`GetCharacteristicsAsync` 状态 `AccessDenied`、特征数 0），
实测**约 40 秒后自动恢复**，不需要重启电脑，也不需要重新配对。

所以看到连续的 `AccessDenied` 先别动它，等一分钟；
真正卡住时的特征是"扫描 0 个广播包"（见 ②），而不是 `AccessDenied`。

### 一次性体检工具

不想读代码猜，直接跑探针，它会把无线电状态、适配器能力、Active/Passive 两种模式各收多少包、
按地址取对象的结果、GATT 服务列表、系统设备库命中情况一次打全：

```powershell
dotnet run --project tools\ble-diag -- AA:BB:CC:DD:EE:FF 8
```

正常的心率带应该看到 `svc=[180D]`，并且 GATT 列出 6 个服务（含 `180d`）。
