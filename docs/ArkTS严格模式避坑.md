# ArkTS 严格模式避坑（真实编译错误记录）

> 这份文档里的每一条都是**本工程真实触发过的编译错误**，不是推测。
> 报错来源：DevEco Studio 26.0.0 / hvigor 6.26.4 / API 26。
> 日志位置：`mobile/harmonyos/.hvigor/outputs/build-logs/build.log`

---

## 为什么单独写一份

ArkTS 不是 TypeScript。它有一套**额外的严格规则**，很多在 TS 里完全正常的写法
在 ArkTS 里会直接编译失败。第一次编译本工程时，34 个错误里 **33 个**都属于下面三条规则。

这些错误有个共同特点：**报错位置和真正的原因经常不在一处**（一个匿名类型会让
它下面几十行全部报错），所以照着一行行改会很痛苦。

---

## 规则一：`arkts-no-untyped-obj-literals`

**对象字面量必须对应一个明确声明的 class 或 interface。**

### ❌ 错误写法

```typescript
// 1) 没有类型标注 —— 最常见的触发点
export const KEYS = {
  serverUrl: 'server_url',
  deviceId: 'device_id'
};

// 2) 赋给 object 类型的字段
interface Envelope { payload: object; }
const ping: Envelope = {
  payload: { rtt: null }        // ← 报错在这
};

// 3) 返回匿名类型
function find(name: string): { id: number } | null {
  return { id: 1 };             // ← 报错
}
```

### ✅ 正确写法

```typescript
// 1) 先声明 interface，再标注
export interface PrefKeys { serverUrl: string; deviceId: string; }
export const KEYS: PrefKeys = { serverUrl: 'server_url', deviceId: 'device_id' };

// 2) 先构造具名类型的变量，再传进去
export interface PingPayload { rtt: number | null; }
const pingPayload: PingPayload = { rtt: null };
const ping: Envelope = { payload: pingPayload };

// 3) 返回类型用具名 interface
export interface KnownCharacteristic { uuid: string; name: string; }
function find(name: string): KnownCharacteristic | null {
  const hit: KnownCharacteristic = { uuid: '2A37', name: '心率测量' };
  return hit;
}
```

### ⚠️ 一个反直觉的点：`Record<string, T>` **不算**具名类型

这条是实测出来的，跟直觉相反：

```typescript
// ❌ 编译失败（报 arkts-no-untyped-obj-literals）
export const SOURCE_LABELS: Record<string, string> = {
  ble: 'BLE 直连',
  healthStore: '华为 Health Service Kit'
};

// ✅ 改用 switch 函数，彻底绕开
export function sourceLabel(kind: string): string {
  switch (kind) {
    case 'ble': return 'BLE 直连';
    case 'healthStore': return '华为 Health Service Kit';
    default: return kind;
  }
}
```

> 有意思的是 `Record<number, string>`（数字键）**没有**报错。
> 但为了统一，本工程把这类映射表全部改成了 `switch` 函数 —— 走到哪都不会踩。

---

## 规则二：`arkts-no-obj-literals-as-types`

**不能用内联的对象类型当类型声明**，必须抽成具名 interface。

### ❌ 错误写法

```typescript
// 匿名内联类型
export interface KnownService {
  characteristics: Array<{ uuid: string; name: string; subscribable: boolean }>;
}

// 匿名返回类型
function find(uuid: string): { name: string } | null { ... }
```

### ✅ 正确写法

```typescript
export interface KnownCharacteristic {
  uuid: string;
  name: string;
  subscribable: boolean;
}

export interface KnownService {
  characteristics: KnownCharacteristic[];
}

function find(uuid: string): KnownCharacteristic | null { ... }
```

### 💡 关键经验：**这一条会引发级联报错**

本工程里这一条只出现 2 次，却导致了 **26 个报错**。

原因：`characteristics` 的类型是匿名对象 → 数组里每个元素字面量都找不到
"明确声明的类型" → 每个元素、每个嵌套数组都报一次
`arkts-no-untyped-obj-literals` 和 `arkts-no-noninferrable-arr-literals`。

**所以遇到大片报错时，先往上找那个匿名的类型声明 —— 修一处，消一片。**

---

## 规则三：`arkts-no-noninferrable-arr-literals`

**数组字面量的元素类型必须可推断。**

### ❌ 错误写法

```typescript
const nameHints = ['watch', 'band', 'heart'];   // 没有类型标注
const healthServices = ['180D', '1822'];
```

### ✅ 正确写法

```typescript
const nameHints: string[] = ['watch', 'band', 'heart'];
const healthServices: string[] = ['180D', '1822'];
```

**注意**：这条规则比想象中宽松。以下写法**实测没问题**（因为目标类型已知）：

```typescript
function startScan(services: string[] = []): void { ... }   // 形参有类型 ✅
this.background.start(['bluetoothInteraction', 'dataTransfer']);  // 形参是 string[] ✅
ForEach([1, 2, 3, 4], (n: number) => { ... })                // 元素类型可推断 ✅
```

---

## 额外发现：华为 SDK 自身的 `SlotType` 枚举不一致

**这不属于 ArkTS 规则，是一个真实的 SDK 缺陷**，很容易卡住人：

```
@ohos.notification 的 SlotType 标注 @deprecated since 9
  @useinstead ohos.notificationManager/notificationManager#SlotType

但 @ohos.notificationManager 的 NotificationRequest.slotType
  类型仍然是 notification.SlotType（那个已废弃的）
```

结果：写 `notificationManager.SlotType.SERVICE_INFORMATION` 会报

```
10505001
Type 'SlotType.SERVICE_INFORMATION' is not assignable to type 'SlotType'
```

**两个枚举名字和成员完全一样，但是两个不同的类型。**

**本工程的解法**：`slotType` 是**可选字段**，直接不设置，让系统按通知类型自动分配。
对长时任务的常驻通知没有影响。

```typescript
const request: notificationManager.NotificationRequest = {
  id: NOTIFICATION_ID,
  content: { ... },
  // 刻意不写 slotType —— 原因见上
  wantAgent: await this.buildNotificationAgent()
};
```

---

## 额外发现：`fill()` 需要 SDK 26，但工程最低是 API 12

编译时会警告：

```
The 'fill' API is supported since SDK version 26.0.0.
However, the current compatible SDK version is 5.0.0(12).
```

原因：`circle.d.ts:144` 的 `fill(value: ResourceColor | ColorMetrics)` 重载标注了
`@since 26`（因为多了 `ColorMetrics`），而本工程 `compatibleSdkVersion` 是 `5.0.0(12)`。

**本工程的解法**：画小圆点不用 `Circle().fill()`，改用「方块 + 圆角」：

```typescript
// ❌ 会报警告，且低版本设备不可用
Circle({ width: 8, height: 8 }).fill('#1FA84F')

// ✅ 全版本可用，视觉一致
Row()
  .width(8)
  .height(8)
  .borderRadius(4)
  .backgroundColor('#1FA84F')
```

---

## 剩下的警告：都是"API 比最低版本新"，无害

编译完还会剩 22 个同类警告，都是这个形式：

```
The 'XxxApi' API is supported since SDK version N. However, the current
compatible SDK version is 5.0.0(12). It is recommended to use apiAvailable
to safeguard API compatibility.
```

涉及：

| API | 需要版本 | 在哪 | 是否安全 |
| --- | --- | --- | --- |
| `AppPreloadType` / `PRELOAD` / `UNSPECIFIED` / `TYPE_CREATE_*` | 20~23 | `MyAbilityStage.ets` 预加载检测 | ✅ 已用 `try/catch` 兜住 |
| `heartRateVariability` / `DATA_TYPE` | 5.1.0 | Health Kit 数据源 | ✅ 仅切到 Kit 模式才用 |

**为什么保留 `compatibleSdkVersion: 5.0.0(12)`**：它决定"最低能装在什么系统上"。
设成 12 意味着 HarmonyOS 5.0 及以上都能装；为了消掉几个警告而提高它，
会让一堆老设备装不上，不划算。详见 [`版本兼容说明.md`](版本兼容说明.md)。

---

## 排查这类问题的正确姿势

1. **别只看 DevEco 面板上的那几条** —— 它会截断。完整日志在
   `mobile/harmonyos/.hvigor/outputs/build-logs/build.log`，里面有每条错误的
   文件、行号、列号、规则名。
2. **按规则名归类**，不要按文件。同一条规则往往集中在少数几个根因上。
3. **先修"匿名类型"，再看剩下什么** —— 级联报错修掉根因后会一起消失。
4. 本次实战：**34 个错误 → 5 处根因修复 → 0 错误**。

---

## 本次修复清单（备查）

| # | 文件 | 问题 | 修法 |
| --- | --- | --- | --- |
| 1 | `common/Prefs.ets` | `KEYS` 无类型标注 | 加 `PrefKeys` interface |
| 2 | `model/HealthTypes.ets` | `SOURCE_LABELS: Record<string, string>` | 改 `switch` 函数 |
| 3 | `model/HealthTypes.ets` | `OPTIONAL_METRIC_MIN_API: Record<string, number>` | 改 `metricMinApiLevel()` 函数 |
| 4 | `model/HealthTypes.ets` | `SLEEP_STATUS_LABELS: Record<number, string>` | 改 `switch`（预防性） |
| 5 | `ble/BleClient.ets` | `characteristics: Array<{...}>` 匿名类型 | 抽 `KnownCharacteristic`（**消掉 26 个报错**） |
| 6 | `ble/BleClient.ets` | `): { name: string } \| null` 匿名返回类型 | 改 `KnownCharacteristic \| null` |
| 7 | `transport/LanWsTransport.ets` | `payload: { rtt: null }` ×2 | 先构造 `PingPayload`/`PongPayload` 变量 |
| 8 | `service/ContinuousTaskManager.ets` | `slotType` 枚举不匹配 | 移除该字段 |
| 9 | `pages/Index.ets` ×2、`pages/BleDevices.ets` | `Circle().fill()` 需 SDK 26 | 改方块 + `borderRadius` |
