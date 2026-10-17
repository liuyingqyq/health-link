# 新旧 API 对照与纠错表

> 这份文档存在的唯一目的：**指出华为官方资料与你原始需求之间的偏差**，并说明本项目最终采用哪种写法、为什么。
>
> 每一条都经过两种独立核实：
> ① 逐行阅读本机 DevEco Studio 26 的 SDK 类型声明
> （`D:\Downloads\DevEco Studio\sdk\default\hms\ets\api\@hms.health.store.d.ts` 等）
> ② 对照华为官方文档（文档中心 + OpenHarmony docs 仓库）

---

## 0. 一句话结论

你给的参考代码是 **FA/JS 时代的旧版 HMSCore JS SDK**（npm 包 `@hw-hmscore/hms-js-health`），
而 HarmonyOS NEXT（5.0 / API 12 起）的实际可用 API 是**内置的 `@kit.HealthServiceKit`**。
两者不只是包名不同，**字段名、枚举值、权限模型、甚至"哪些字段存在"都不一样**。
本项目的手机端完全按新版实现，并由本机 SDK 真实编译验证。

---

## 1. 包与入口

| | 你的参考（旧） | 官方现行（新） | 本项目 |
| --- | --- | --- | --- |
| 包 | `@hw-hmscore/hms-js-health`（npm，需 `oh-package.json5` 引入） | `@kit.HealthServiceKit`（SDK 内置，无需装包） | ✅ 新版 |
| 类/命名空间 | `HMSHealthKit` | `healthStore` / `healthService` | ✅ `healthStore` |
| 初始化 | 隐式（首次调用时 SDK 自己拉起） | **必须显式** `await healthStore.init(context)`，且 context 只能是 UIAbility / UIExtensionAbility | ✅ 在 `EntryAbility` 里 await 完成 |
| 查最新数据 | `HMSHealthKit.readLatest(dataTypes)` | `healthStore.readData({ samplePointDataType, sortOrder: DESC, count: 1, ... })` | ✅ 用后者 |
| 查历史 | `new ReadOptions(start, end, types, null, null, "false")` + `read()` | `healthStore.readData({ samplePointDataType, startTime, endTime, count, offset, sortOrder })` | ✅ 用后者 |
| 查睡眠 | `HMSHealthKit.readSleepData()` | `healthStore.readData<sleepRecord.Model>({ healthSequenceDataType: healthSequenceHelper.sleepRecord.DATA_TYPE, readOptions: { withDetails: true } })` | ✅ 用后者 |

**新版额外硬约束（旧版文档里没有）**：

* 单次 `readData` 的**时间跨度不得超过 31 天**（官方 API 表原文）。本项目取 30 天保守值。
* 采样点查询用 `startTime` / `endTime`（毫秒）。`startLocalDate` / `endLocalDate` 在
  `SamplePointReadRequest` 里被 `Omit` 掉了，**传了也不生效**。
* 当 `samplePointDataType` 传数组时，**不能同时传 `fields`**。
* `healthStore.init()` 必须在所有其他 healthStore 调用之前 `await` 完成。

---

## 2. 数据类型常量

| | 你的参考（旧） | 官方现行（新） | 本项目 |
| --- | --- | --- | --- |
| 动态心率 | `HMSHealthKitDataType.DT_INSTANTANEOUS_HEART_RATE` | `healthStore.samplePointHelper.heartRate.DATA_TYPE` | ✅ 新版 |
| 静息心率 | `DT_INSTANTANEOUS_RESTING_HEART_RATE` | `healthStore.samplePointHelper.restingHeartRate.DATA_TYPE` | ✅ |
| 心率变异性 | `DT_INSTANTANEOUS_HEART_RATE_VARIABILITY` | `healthStore.samplePointHelper.heartRateVariability.DATA_TYPE`（**API 18+**） | ✅ 带版本降级 |
| 血氧 | `DT_INSTANTANEOUS_SPO2` | `healthStore.samplePointHelper.bloodOxygenSaturation.DATA_TYPE` | ✅ |
| 压力 | `DT_INSTANTANEOUS_STRESS` | `healthStore.samplePointHelper.stress.DATA_TYPE` | ✅ |
| 睡眠 | `readSleepData()` | `healthStore.healthSequenceHelper.sleepRecord.DATA_TYPE` | ✅ |

> `healthStore.healthDataTypes.HEART_RATE` 这类常量**确实存在**，但官方示例一律使用
> `samplePointHelper.*.DATA_TYPE` 形式（后者同时挂在类型信息上，泛型推导更顺）。
> 本项目采用官方示例写法。

---

## 3. ⚠️ 睡眠字段：三处需要纠正

### 3.1 字段名是 `sleepStatus`，不是 `sleepState`

* 官方：`healthFields.SleepDetail.sleepSegment: SleepSegment[]`，
  每个 `SleepSegment` 的字段是 **`sleepStatus`**（外加继承来的 `startTime` 与 `endTime`）。
* 你原文里的 `sleepDetail[].sleepState` 属于旧版 SDK。

### 3.2 枚举值：1 = 深睡，不是浅睡

官方 `SleepSegment.sleepStatus` 全量取值：

| 值 | 官方含义 |
| --- | --- |
| 0 | 未知 |
| **1** | **深睡** |
| **2** | **浅睡** |
| **3** | REM |
| 4 | 清醒 |
| 5 | 小睡（零星小睡） |
| 6 | 卧床 |
| 7 | 睡眠（手动记录） |

你原文写的是「1=浅睡，3=深睡」——**1 和 2 正好相反**，3 也不是深睡而是 REM。

**这个偏差的后果很严重**：如果按旧语义画睡眠分期图，深浅睡会被完全画反，直接误导使用者。
本项目**原样透传官方取值**（不做二次编码），
手机端 `model/HealthTypes.ets` 与电脑端 `pc/web/chart.js` 都用同一张官方配色表。

### 3.3 这 5 个字段在新版里**不存在**

| 你列的字段 | 核实结果 |
| --- | --- |
| `sleepScore` | ✅ 存在（`healthFields.Sleep.sleepScore`，0-100） |
| `sleepEfficiency` | ✅ 存在（0-100） |
| `snoreFreq` | ❌ **不存在** |
| `avgHeartRate` | ❌ **不存在** |
| `avgOxygenSaturation` | ❌ **不存在** |
| `avgBreathRate` | ❌ **不存在**（最接近的是 `respiratoryQualityScore` 呼吸质量分） |
| `avgHrv` | ❌ **不存在** |

我一个一个 grep 过 SDK 声明确认。`healthFields.Sleep` 的官方字段全清单是：

```
fallAsleepTime  wakeupTime  duration  bedTime  risingTime  prepareSleepTime
shallowDuration deepDuration dreamDuration wakeDuration wakeCount onBedDuration
recordDuration  sleepEfficiency sleepScore deepSleepContinuity
respiratoryQualityScore turnOverCount sleepEndReason sleepSymptoms sleepType
```

**心率 / 血氧 / HRV 在官方模型里是独立数据类型**，不会随睡眠记录返回。
要得到"睡梦中的平均心率"，正确做法是：按睡眠记录的 `[fallAsleepTime, wakeupTime]`
时间窗**另外查一次 `heartRate` 采样点**再自己求平均。
本项目在 `HealthStoreClient.readAverageHeartRate(startTime, endTime)` 里提供了这个方法，
但**默认不启用**（避免每次采集都多打一次接口）。

传输层的处理：把旧字段定义为**可选扩展 `legacy`**，能取到就填、取不到就省略，
并在 JSON Schema 里明确标注"下游必须允许缺失"，绝不假装它们存在。

---

## 4. ⚠️ 权限模型：最大的一个坑

### 你原文的写法

> | 心跳 | `HEALTH_DATA_READ` | 个人可申请 |

### 实际情况

1. **`ohos.permission.HEALTH_DATA_READ` 在官方文档中查无此权限名。**
   它既不在 OpenHarmony《开放权限（系统授权）》全表，也不在《受限开放权限》全表，
   华为 Health 文档中同样没有出现。**本项目没有把它写进 `module.json5`**——
   写一个不存在的权限会导致配置校验失败或静默无效。

2. **真实模型是"两条腿"的交集**：

   ```
   能读到的数据 = AGC 申请到的数据权限  ∩  用户运行时授权的权限
   ```

   * **腿一（AGC 侧）**：在华为开发者联盟管理中心申请 Health Service Kit 服务，
     勾选中文命名的数据权限项，例如「心率数据（读）」「睡眠数据（读）」
     「血氧数据（读）」「压力数据（读）」。
     开放等级官方叫法是**「基础」/「高阶」**（不是"个人可申请/受限开放"）：
     企业实缴注册资本 ≥50 万（基础）/ ≥500 万（高阶）、主体成立 ≥1 年；
     **个人开发者拿不到高阶**，且应用需已上架华为应用市场。
     审核约 15 个工作日，测试阶段限前 100 位用户。
   * **腿二（运行时）**：`healthStore.requestAuthorizations(context, request)`，
     弹用户授权框。本项目在首页提供「请求健康数据授权」按钮触发。

3. **`module.json5` 里真正需要声明的是这些**：

   | 权限 | 等级 | 用途 |
   | --- | --- | --- |
   | `ohos.permission.INTERNET` | normal | 把数据上传到电脑（不声明则完全无法联网） |
   | `ohos.permission.GET_NETWORK_INFO` | normal | 判断是否同局域网，给出可读的失败原因 |
   | `ohos.permission.KEEP_BACKGROUND_RUNNING` | **normal** | 申请长时任务。普通应用可直接申请，不需要 system_basic |

   这三个都是 normal / system_grant，在 `EntryAbility.requestRuntimePermissions()` 里
   用 `abilityAccessCtrl.requestPermissionsFromUser` 申请。

### 常见错误码与对应处置（本项目已内置提示）

| 错误码 | 官方含义 | 处理 |
| --- | --- | --- |
| 201 | 鉴权失败（应用指纹不对 / 缺权限 / 仅白名单 / 测试用户数满） | 检查 AGC 配置与申请状态 |
| 401 | 参数错误 | 检查 context 与请求参数 |
| 801 | 设备不支持 | 该机型能力不足 |
| 1002700001 / 1002700002 | 系统内部错误 / 数据库错误 | 重试 |
| 1002701001 | 网络不可用 | 检查网络；也提示 INTERNET 权限 |
| **1002702001** | **用户未登录华为账号** | 引导登录 |
| **1002703001** | **用户隐私未同意**（官方原文：可能原因是"用户从未启动过运动健康 App"） | **引导用户启动一次华为运动健康 App** |

---

## 5. ⚠️ 长时任务：`ContinuousTaskExtensionAbility` 不存在

### 你原文的示例 4

```typescript
import { ContinuousTaskExtensionAbility } from '@kit.BackgroundTasksKit';
export default class MyContinuousTaskExtensionAbility extends ContinuousTaskExtensionAbility { ... }
```

### 核实结果

**这个 API 查无官方来源，不要使用。** 两条反证（都是官方明文）：

1. 长时任务开发指南：「Stage 模型中，**长时任务仅支持 UIAbility 申请**；
   FA 模型中，长时任务仅支持 ServiceAbility 申请。」
2. `module.json5` 的 `extensionAbilities.type` 合法值全表里**没有 `continuousTask`**。
   后台服务扩展的官方对应物是 `AppServiceExtensionAbility`（`type: appService`，API 20），
   但它**不是**长时任务机制。

→ 本项目**不使用**任何 Extension Ability，长时任务全部在 `EntryAbility` +
`ContinuousTaskManager` 里完成。

### 其他需要澄清的点

| 你原文 | 核实结果 |
| --- | --- |
| `backgroundTaskManager.BackgroundMode.DATA_TRANSFER` | ✅ 写法正确。`BackgroundMode` 一直是 `@ohos.resourceschedule.backgroundTaskManager` 自己的枚举，不是"新版才移进来" |
| `["dataTransfer", "audioPlayback", "location", "bluetoothInteraction"]` | ⚠️ 这些是 `module.json5` 的**配置项字符串**，与 API 侧枚举是两套东西。合法值共 12 个：`dataTransfer` `audioPlayback` `audioRecording` `location` `bluetoothInteraction` `multiDeviceConnection` `wifiInteraction`(仅系统应用) `voip` `taskKeeping` `avPlaybackAndRecord` `specialScenarioProcessing` `nearlink` |
| 通知栏常驻 | ✅ 正确，但官方还有一句更狠的：**「用户删除通知栏消息时，系统会自动停止长时任务」** |
| 「长时任务期间通知栏必须常驻显示，不可隐藏」 | ✅ 正确 |
| 「后台默认运行时间窗口仅 10 分钟」 | ✅ 正确，长时任务可突破 |

### ⚠️ DATA_TRANSFER 的 10 分钟续期要求（旧文档没有）

官方对 `DATA_TRANSFER` 的原话：

> 在数据传输过程中，应用需要更新进度。**如果超过 10 分钟未更新进度，
> DATA_TRANSFER 类型的长时任务将被取消。** 进度更新的通知类型必须为**实况窗**。

你原文的 `startContinuousTask()` 示例**没有做任何进度更新**，
按字面实现的话，长时任务会在 10 分钟后被系统取消，采集随之中断。

本项目的处理（见 `service/ContinuousTaskManager.ets`）：

* 用 API 12 起的字符串数组重载**一次申请两种模式**：
  `startBackgroundRunning(context, ['bluetoothInteraction', 'dataTransfer'], agent)`
  —— 健康数据来自蓝牙穿戴设备，`bluetoothInteraction` 是场景最匹配的主模式；
  `dataTransfer` 用于持续上传。
* 每 **5 分钟**（< 10 分钟硬限，留足余量）刷新一次常驻通知的进度文案。
* 采集循环每轮也会调用 `updateProgress()`，把"已采集 N 项 + 最近一项"写进通知。
* 通知使用 `isOngoing: true` + `isUnremovable: true`，
  并在文案里明确写「请勿删除本通知，删除后系统会停止后台采集」。

> **⚠️ 需要如实告知的风险**：官方明确说「系统会检测业务真实性，若未实际执行对应
> 业务，可能取消长时任务并挂起应用」。本应用做的是"周期性读取健康数据并上传"，
> 是否被系统判定为真实的 `bluetoothInteraction` / `dataTransfer` 业务，
> **需要在真机上实测**（本项目没有真机，无法验证这一点）。
> 如果被判定不实，可在 `CollectionService.start()` 里调整模式组合。

---

## 6. ⚠️ 应用预加载：两个说法要纠正

| 你原文 | 核实结果 |
| --- | --- |
| 「初始化至 `AbilityStage.onCreate` 或 `WindowStage.onCreate`」 | ❌ **不存在 `WindowStage.onCreate`**。官方正确的是 **`UIAbility.onWindowStageCreate(windowStage)`** |
| `application.getAppPreloadType()` | ✅ 存在，但**起始版本是 API 22**（不是 12），`SystemCapability.Ability.AbilityRuntime.Core` |

补充（官方明文）：

* 预加载机制**从 API 20 起**，**仅 2in1 设备**，**仅 entry 模块**的 AbilityStage / UIAbility。
* 是否预加载、什么时机，**由系统按用户习惯与资源自行决定，开发者无法干预**。
* **只有在进程首次执行 `AbilityStage.onCreate` 完成之前**调用 `getAppPreloadType()`
  才能拿到真实类型；`AbilityStage` 创建完成后预加载数据会被清除，
  之后调用只会返回 `UNSPECIFIED`。
* `AppPreloadType` 取值：`UNSPECIFIED=0`、`TYPE_CREATE_PROCESS=1`、
  `TYPE_CREATE_ABILITY_STAGE=2`、`TYPE_CREATE_WINDOW_STAGE=3`、
  `TYPE_CREATE_BACKGROUND_ABILITY=4`（API 23+）。

本项目的处理（`entryability/MyAbilityStage.ets`）：

* 在 `AbilityStage.onCreate()` 的**第一件事**就调用 `getAppPreloadType()`，并用 `try/catch`
  兜住低版本设备（API < 22 上该接口不存在，不 catch 会直接让 stage 创建失败）。
* 预加载路径下**提前初始化偏好存储**，省掉用户点开后的等待——这正是"预加载可加速
  采集服务就绪"的落地方式。
* 顺带纠正一个配置陷阱：`AbilityStage` 必须在 `module.json5` 里用
  **`"srcEntry": "./ets/entryability/MyAbilityStage.ets"`** 声明，否则 `onCreate` 根本不会执行。
  你原文的 `module.json5` 片段里没有这一项。

---

## 7. 其他细节差异

| 项 | 说明 |
| --- | --- |
| 机型字段 | `deviceInfo.marketName`（面向用户的机型名），**没有 `deviceInfo.model`**。旧代码里常见的 `deviceInfo.model` 在新 SDK 里是 `productModel` / `marketName` |
| `deviceId` | 不要指望 `Settings.Secure.ANDROID_ID`（Android 的）。本项目用 `util.generateRandomBinaryUUID()` 生成 16 字节随机 ID 并持久化，无需任何权限 |
| 休眠/休眠间隔 | 官方建议避免频繁唤醒，**间隔 ≥ 1 分钟**。本项目默认采集周期 60 秒 |
| 通知开关 | 发布常驻通知前先 `notificationManager.isNotificationEnabled()`；未开启时只记日志不阻断采集（长时任务本身已申请成功） |

---

## 9. 附：HarmonyOS 系统版本与 API level 对应

华为同时用**两套**版本号，填工程配置时最容易混：

| HarmonyOS 系统版本 | API level | 工程里的版本字符串 |
| --- | --- | --- |
| HarmonyOS 5.0 | API 12 | `5.0.0(12)` |
| HarmonyOS 6.0 | API 20 | `6.0.0(20)` |
| HarmonyOS 6.1 | API 23 | `6.1.0(23)` |
| **HarmonyOS 7** | **API 26** | `26.0.0(26)` |

> **HarmonyOS 7 = API 26** 已核实（[华为官方公告：HarmonyOS 7 正式发布，建议开展 API 26 升级评估](https://developer.huawei.com.cn/consumer/cn/notice/detail/?id=9002210958618976001)）。
> 本机 SDK 的 `sdk-pkg.json` 里是 `"apiVersion": "26"`、`"platformVersion": "26.0.0"`、
> `"displayName": "HarmonyOS 26.0.0"`，与之一致。

因此工程里的版本策略是：

```json5
// mobile/harmonyos/build-profile.json5
"compatibleSdkVersion": "5.0.0(12)"   // 最低 API 12 → HarmonyOS 5.0 及以上都能装
// 不写 targetSdkVersion：交给构建时的 SDK 决定，避免"目标版本低于设备"触发安装报错

// mobile/harmonyos/AppScope/app.json5
"minAPIVersion": 12
// 不写 targetAPIVersion，同上
```

**为什么最低是 12**：HealthServiceKit 全部接口都是 `@since 5.0.0(12)`，这是硬下限。
其余用到的接口更低（长时任务 / preferences 是 API 9）。
`getAppPreloadType` 需要 API 22，但代码里 `try/catch` 兜住了，不影响低版本启动。

完整分析（含装不上时的排查步骤）见 [`docs/版本兼容说明.md`](版本兼容说明.md)。

---

## 10. 参考来源

**SDK 声明（本机，已逐行核对）**
* `D:\Downloads\DevEco Studio\sdk\default\hms\ets\api\@hms.health.store.d.ts`
* `D:\Downloads\DevEco Studio\sdk\default\hms\ets\kits\@kit.HealthServiceKit.d.ts`
* `D:\Downloads\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.resourceschedule.backgroundTaskManager.d.ts`
* `D:\Downloads\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.app.ability.application.d.ts`
* `D:\Downloads\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.webSocket.d.ts`
* `D:\Downloads\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.deviceInfo.d.ts`

**华为官方文档页面**
* healthStore（init / readData / 31 天限制）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/health-api-healthstore
* healthFields（Sleep / SleepSegment / sleepStatus 枚举）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/health-api-healthfields
* healthSequenceHelper（sleepRecord）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/health-api-healthsequencehelper
* samplePointHelper（heartRate 等）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/health-api-samplepointhelper
* 权限说明（数据类型 ↔ 权限项）：
  https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/health-permission-description
* 申请运动健康服务（开放等级 / 资质 / 审核）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/health-apply
* Health Service Kit 错误码：
  https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/errorcode-healthservice
* 长时任务开发指南（backgroundModes 配置项、通知栏、UIAbility 限制）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/continuous-task
* backgroundTaskManager API：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-resourceschedule-backgroundtaskmanager
* 开放权限（KEEP_BACKGROUND_RUNNING = normal）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/permissions-for-all
* 受限开放权限：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/restricted-permissions
* 应用预加载指南：
  https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/preload-application
* application.getAppPreloadType / AppPreloadType：
  https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-app-ability-application
* 旧版 JS SDK（npm 元数据）：
  https://registry.npmjs.org/@hw-hmscore/hms-js-health
