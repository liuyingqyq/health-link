# HealthLink Android 版（HUAWEI Research / SensorPro）

> 这是**另一个应用**，与 `mobile/harmonyos/`（HarmonyOS 版）并存，互不影响。
> 目的：走 HUAWEI Research 的 SensorPro SDK，从**穿戴设备**取真实数据。
> 电脑端（`pc/`）与传输协议**完全复用，一行没改**。

---

## 一、这个工程现在能做什么

| 能力 | 状态 |
| --- | --- |
| 连接电脑端（`/ingest` WebSocket、令牌鉴权、hello 握手） | ✅ 已实现 |
| 完整协议：`hello` / `sample` / `batch` / `ping` / `pong` / `ack` / `nack` | ✅ 已实现 |
| 离线队列（落盘、上限 20000、超限丢最旧、ack 后才提交） | ✅ 已实现 |
| 断线退避重连（1/2/4/8/16/30s）+ 30s 心跳、连续 2 次无 pong 判掉线 | ✅ 已实现 |
| 电脑端下发 `collectIntervalMs` 的远程调参 | ✅ 已实现 |
| 前台服务保活（= HarmonyOS「长时任务」的等价物） | ✅ 已实现 |
| 界面：地址、数据源、连接/采集开关、状态、运行日志 | ✅ 已实现 |
| **模拟数据源**（无需任何权限，用来验证整条链路） | ✅ 已实现 |
| **SensorPro 数据源**（扫描接口按官方签名） | ⚠️ 反射调用，需 SDK 到位 |
| 传感器数据订阅（心率等） | ⚠️ 待 SDK 到位后按实际 aar 补 |

**协议兼容性已实测**：`mobile/android/verify-protocol.js` 针对**真实电脑端服务**跑了 14 项断言，
全部通过（含 9 个合法 metric 全接受、5 类非法载荷全被正确拒绝、补传区间计算正确）。
重跑方式：

```powershell
cd <项目目录>
node mobile\android\verify-protocol.js
```

**构建已验证**：`mobile\android\build-apk.ps1` 在本机跑通，产出已签名的
`mobile\android\dist\healthlink-collector-debug.apk`（6.3 MB）。

> 说明：**SensorPro 数据源本身还没接真设备**（SDK 未到位，见第二节）。
> 现在这个 APK 能装、能跑，用「模拟数据」数据源可以端到端验证整条链路。

---

## 二、为什么 SensorPro 那部分用「反射」而不是直接 import

SensorPro SDK（`com.huawei.hiresearch.*`）**不是公开 Maven 依赖**，由 HUAWEI Research
平台在**研究项目过审后**下发 aar。

如果直接写 `import com.huawei.hiresearch.sensorprosdk.SensorProManager`，
在 SDK 到位之前**整个工程编译不过**——连模拟数据源那条能跑通的路也一起瘫掉。

所以 `SensorProSource.kt` 用反射 + 运行时探测：

- **今天（无 SDK）**：工程正常编译、正常运行，界面如实显示「未检测到 SensorPro SDK」，
  切到模拟数据源照样能跑通全链路；
- **明天（放入 aar）**：**无需改任何代码**，类一加载即被探测到；
- 所有 Java 类名/方法名集中在 `SensorProSource.Sdk` 常量表里，SDK 若有差异**只改那一处**。

> 已确认的官方签名（来自官方《扫描设备》文档）：
> ```java
> public void scanDevice(int deviceItemType, SensorProDeviceDiscoverCallback callback)
> ```
> 设备类型：`1`=WATCH GT 2 系列、`3`=HONOR BAND 5、`5`=Band 4 系列、`6`=Band 6/7、
> `7`=WATCH D、`8`=S-TAG、`9`=WATCH GT 3 系列。
> **前提**：手机开蓝牙 + 授予 APP **位置权限**，否则 SDK 不工作。

---

## 三、前置条件（你必须先具备）

1. **研究项目过审**。华为要求：*研究项目通过国家指定的伦理审查委员会的审批*。
   → 平台：HUAWEI Research 创新研究平台，提交项目信息 + **上传伦理报告**，审核约 1 周。
   过审后邮件给平台地址和邀请码（邀请码 3 天有效）。
2. **拿到 SDK**。过审后从平台下载 aar（以及可能需要的 `agconnect-services.json`）。
3. **装 Android 开发环境**。本机目前**没有** Android Studio / Android SDK / Gradle，
   我没法替你装。装 Android Studio 即可（会自带 SDK 与 Gradle）。

---

## 四、怎么构建

### 4.1 命令行构建（已验证可用）

**这个工程已经在本机成功构建出 APK 了**，用的是一条全自动脚本：

```powershell
cd <项目目录>
.\mobile\android\build-apk.ps1
```

产物：`mobile\android\dist\healthlink-collector-debug.apk`（约 6.3 MB，已用 Android Debug 证书签名）
实测：**27.6 秒、Kotlin 错误 0、警告 0**。

安装到手机：

```powershell
& 'D:\Android\Sdk\platform-tools\adb.exe' install -r "<项目目录>\mobile\android\dist\healthlink-collector-debug.apk"
```

> 脚本已经把 5 个环境坑都处理掉了（JDK 版本、user.home 权限、ANDROID_USER_HOME、
> 文件监听、SDK 平台版本），细节写在脚本开头的注释里。若你在自己电脑上构建遇到问题，
> 先看那份清单。

### 4.2 用 Android Studio 构建

1. 用 **Android Studio** 打开 `android` 这个目录（不是 `health-link`）
2. 等 Gradle Sync 完成（首次会下载依赖，需要网络）
3. 连上手机（开 USB 调试），点绿色 ▶ Run

首次 Sync 若卡在下载，`settings.gradle` 里已配好阿里云镜像；若你走代理，删掉镜像那两行即可。

> ⚠️ **Android Studio 自带的 JBR 是 JDK 25，AGP 8.5 不认**（报
> `Unsupported class file major version 69`）。所以要在
> `File → Settings → Build, Execution, Deployment → Build Tools → Gradle → Gradle JDK`
> 里选 **JDK 17 或 21**（我这里用的是随工程下载的
> `mobile\android\.tooling\jdk-21.0.2`，你也可以让 Android Studio 自己下载一个 21）。

### 4.3 放入 SensorPro SDK

把 aar 复制到 `app/libs/`：

```
mobile/android/app/libs/<平台下发的>.aar
```

`app/build.gradle` 里已有：

```gradle
implementation fileTree(dir: 'libs', include: ['*.aar', '*.jar'])
```

若 SDK 需要 `agconnect-services.json`，放到 `app/` 目录下。

---

## 五、怎么用（先验证链路，再上真设备）

1. **电脑端先跑起来**：双击 `health-link\启动.cmd`，它会打印一行
   `ws://192.168.x.x:18787/ingest?token=...`
2. 手机 App 里把这行**整行**粘进「电脑地址」
3. 数据源先选 **模拟数据** → 点「连接电脑」→ 点「开始采集」
4. 看两个地方确认通了：
   - App 的「运行状态」变成 **已连接 · 采集中**，日志滚动，已发送条数增长
   - 电脑浏览器打开面板（启动器会给链接），能看到实时曲线
5. **退后台验证保活**：按 Home 键等 1~2 分钟再回来，已发送条数应继续增长，
   且通知栏有「健康互联」的常驻通知（**不要删它**，删了系统会停掉服务）
6. 链路确认后，再切到 **SensorPro** 数据源测真设备

> 离线能力可以这样验：先「开始采集」但**不连电脑**（或把电脑端关掉），
> 采一会儿再连上，App 会按 `batch` 把缓存补传上去，面板上能看到历史数据补齐。

---

## 六、目录结构

```
mobile/android/
├── app/
│   ├── build.gradle                    依赖（含 app/libs 的 aar 自动纳入）
│   ├── proguard-rules.pro              已保留 com.huawei.hiresearch.**
│   ├── libs/                           放 SensorPro aar（现在为空）
│   └── src/main/
│       ├── AndroidManifest.xml          权限按华为官方《权限设置》页配置
│       ├── java/com/healthlink/collector/
│       │   ├── protocol/                协议层（与电脑端契约逐字段对齐）
│       │   │   ├── Protocol.kt           信封、SamplePayload、工厂、metric 白名单
│       │   │   ├── DeviceIdentity.kt     16 字节随机 hex 设备 ID（不用系统标识）
│       │   │   ├── OfflineQueue.kt       落盘队列，ack 后提交
│       │   │   └── ProtocolClient.kt     seq / 握手 / 心跳 / 退避重连 / 补传
│       │   ├── net/LanWebSocketTransport.kt   OkHttp WebSocket
│       │   ├── source/
│       │   │   ├── HealthSource.kt        ★ 可插拔数据源接口
│       │   │   ├── SimulatedSource.kt     模拟源（现在就能跑）
│       │   │   └── SensorProSource.kt     SensorPro（反射调用，待 SDK）
│       │   ├── service/CollectorService.kt    前台服务保活
│       │   └── ui/MainActivity.kt             界面
│       └── res/                         布局 / 字符串 / 主题 / 图标
├── build.gradle / settings.gradle / gradle.properties
└── verify-protocol.js                  协议兼容性验证脚本（14 项断言）
```

---

## 七、与 HarmonyOS 版的对应关系

| HarmonyOS 版（`mobile/harmonyos/`） | Android 版（本工程） |
| --- | --- |
| `HealthStoreClient` / `BleHealthSource` | `SensorProSource` / `SimulatedSource` |
| `HealthSource` 接口 | `HealthSource` 接口（同名同职责） |
| `LanWsTransport`（`@kit.NetworkKit`） | `LanWebSocketTransport`（OkHttp） |
| `ContinuousTaskManager`（长时任务） | `CollectorService`（前台服务 + 常驻通知） |
| `@ohos.data.preferences` | `SharedPreferences` |
| `Prefs.ets` / `HealthTypes.ets` | `DeviceIdentity.kt` / `Protocol.kt` |

**电脑端与协议两边共用**，所以 `pc/` 目录一行都不用改。

---

## 八、已知限制（如实说明）

1. **本工程未经编译验证**。本机没有 Android 工具链，我无法编译。
   我已尽量按 Android/Kotlin 标准写法编写（并对照真实电脑端做了 14 项协议断言），
   但首次 Sync/Run 仍可能有版本或写法问题——报错发我，我改。
2. **SensorPro 的传感器订阅尚未实现**。官方《扫描设备》只覆盖扫描；
   订阅接口需以你拿到的 aar 声明为准。类名请核对 `SensorProSource.Sdk` 常量表。
3. **Research 路线拿到的是传感器原始数据**（ECG/PPG/加速度/心率等），
   **不是**睡眠得分、血氧百分比这类"带算法结论"的指标——那些要你自己做算法。
   如果你要的是结论型指标，应走 Health Service Kit（需 AGC 审批），
   或把 SensorPro 的原始数据在手机端算完再按本协议上传（协议本身不受影响）。
4. **`healthStoreReady` 字段名沿用了契约里的命名**（HarmonyOS 时代的历史包袱），
   Android 端语义等价地表示"数据源是否就绪"。改它要动契约，所以没改。
