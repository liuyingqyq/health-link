# HealthLink 法律文档（隐私政策 / 用户协议）

这里存放 AGC 申请 Health Service Kit 时必填的两个链接页面对应的源文件。

| 文件 | 对应 AGC 字段 | AGC 表单里的题注 |
| --- | --- | --- |
| `privacy.html` | **隐私政策链接** | 您的应用对用户公开的隐私政策链接 |
| `agreement.html` | **协议链接** | 您的应用对用户公开的用户协议链接 |
| `index.html` | （入口页，非必填） | 两篇文档的导航页 |

## 内容依据

页面里的数据处理描述**不是套模板写的**，是与代码逐条核对后的实际行为：

| 声明 | 核对来源 |
| --- | --- |
| 读取心率/睡眠/血氧/情绪/实时心率/近一周历史 | AGC 已勾选权限 |
| 读睡眠用 `healthSequenceHelper.sleepRecord`，其余用 `samplePointHelper` | `mobile/harmonyos/entry/src/main/ets/health/HealthStoreClient.ets` |
| 指标清单（含压力 stress） | `mobile/harmonyos/entry/src/main/ets/model/HealthTypes.ets` 的 `METRIC_METAS` |
| 睡眠分期字段与 `sleepStatus` 取值 | `docs/protocol/health-sample.schema.json` |
| **不采集**硬件标识，设备 ID 为首次启动随机生成 | `transport/LanWsTransport.ets` 的 `ensureDeviceId()`（`util.generateRandomBinaryUUID`） |
| 本地保存的配置项（地址、设备 ID、seq、BLE 设备名等） | `common/Prefs.ets` 的 `KEYS` |
| 局域网 WebSocket 直传、不经云端 | `transport/LanWsTransport.ets`（`@kit.NetworkKit` webSocket） |

**已填好**：联系邮箱 `liuyingqyq@outlook.com`、开发者署名 `liuyingqyq`（三页各一处 `mailto:` + 页脚）。
以后要换邮箱/换署名，直接在这三页里全局替换即可：

```powershell
Get-ChildItem legal\*.html | ForEach-Object {
  $t = [IO.File]::ReadAllText($_.FullName)
  [IO.File]::WriteAllText($_.FullName, $t.Replace('旧邮箱@example.com', '新邮箱@example.com'), (New-Object Text.UTF8Encoding($false)))
}
```

（如果不打算把 App 分发给别人，整个 `legal/` 目录可以删掉，同时去掉 App 内跳转协议页的入口。）

## 本地预览

```powershell
cd <项目目录>
node legal\serve.js          # 需自备极简静态服务器，或用下面任一种
python -m http.server 8790 --directory legal
```

然后浏览器打开 <http://127.0.0.1:8790/>。

## 发布到公网（AGC 需要的是公网可访问的 https 链接）

两个页面是纯静态 HTML，无需数据库与后端，任选一种：

### 方式一：GitHub Pages（推荐，免费且稳定）

1. 登录 GitHub，新建**公开**仓库，例如 `healthlink-legal`
2. 上传 `index.html`、`privacy.html`、`agreement.html`（网页上拖拽即可，不用命令行）
3. 仓库 `Settings` → `Pages` → Source 选 `Deploy from a branch`，分支选 `main`、目录选 `/ (root)` → `Save`
4. 等 1~2 分钟，得到：

   ```
   https://<你的GitHub用户名>.github.io/healthlink-legal/privacy.html
   https://<你的GitHub用户名>.github.io/healthlink-legal/agreement.html
   ```

### 方式二：Gitee Pages

流程相同（新建公开仓库 → 服务 → Gitee Pages → 部署）。注意：Gitee 的 Pages 服务对部分用户需要实名认证，且免费版可能需手动点击更新。

### 方式三：任意对象存储静态托管

腾讯云 COS / 阿里云 OSS 的静态网站托管功能都可以，绑定域名后得到 https 链接。国内访问速度更好，但需要备案域名。

## 填回 AGC

拿到两个 https 链接后，回到 AGC 的「申请 Health Service Kit 服务权限」表单：

- **隐私政策链接** ← `.../privacy.html`
- **协议链接** ← `.../agreement.html`

⚠️ **不要把隐私政策链接填成华为自己的隐私政策页面**（例如 `https://consumer.huawei.com/cn/privacy/`）。
那一栏要的是**你应用自己的**隐私政策；填成华为的属于不实描述，且无法体现你应用实际的数据处理方式。

## 提醒

- 这两份是**开发者自行编写的说明文档**，不是法律意见。若后续要商用、上架应用市场或涉及企业主体，建议请专业人士审阅。
- 如果将来应用的数据行为发生变化（例如新增健康数据类型、把上传通道改成云端、开放给第三方使用），**必须同步更新本隐私政策**，否则与实际行为不符。
