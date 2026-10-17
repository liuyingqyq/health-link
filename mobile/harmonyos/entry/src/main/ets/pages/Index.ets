/**
 * HealthLink 采集端主界面。
 *
 * 设计取舍：
 *   - 用 @State + 服务回调刷新，不用 DataBinding 双向绑定（服务是单例，不是 @Observed 类）
 *   - 所有文案中文，状态用颜色 + 文字双重表达（不能只靠颜色区分）
 *   - 睡眠分期用色带展示，sleepStatus 取值按官方语义（1=深睡 2=浅睡 3=REM 4=清醒）
 */

import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';

import { Logger, LogLine } from '../common/Logger';
import { AppPrefs, KEYS } from '../common/Prefs';
import { CollectionService, ServiceSnapshot } from '../service/CollectionService';
import {
  HealthMetric,
  SamplePayload,
  SleepPayload,
  SleepSegmentPayload,
  SourceKind,
  sourceLabel,
  sleepStatusLabel
} from '../model/HealthTypes';
import { PreloadInfo, detectPreloadType } from '../entryability/MyAbilityStage';

/** 睡眠分期配色：与电脑端面板保持一致，深睡=蓝、浅睡=亮蓝、REM=紫、清醒=橙 */
const SLEEP_COLORS: Record<number, string> = {
  0: '#DEE2E6',
  1: '#3B5BDB',
  2: '#4DABF7',
  3: '#B197FC',
  4: '#FFA94D',
  5: '#63E6BE',
  6: '#ADB5BD',
  7: '#868E96'
};

@Entry
@Component
struct Index {
  @State snapshot: ServiceSnapshot | null = null;
  @State serverUrl: string = '';
  @State busy: boolean = false;
  @State logs: LogLine[] = [];
  @State preload: PreloadInfo = { type: -1, label: '未检测', preloaded: false };
  @State authMessage: string = '尚未请求健康数据授权';
  @State showSettings: boolean = true;

  private service: CollectionService = CollectionService.getInstance();
  private listener = (snap: ServiceSnapshot): void => {
    this.snapshot = snap;
  };
  private logTimer: number = -1;

  aboutToAppear(): void {
    this.serverUrl = this.service.getServerUrl();
    this.preload = detectPreloadType();
    this.snapshot = this.service.getSnapshot();
    this.service.subscribe(this.listener);
    this.refreshLogs();
    // 日志不跟着每次状态变化刷新，避免频繁重建列表
    this.logTimer = setInterval(() => this.refreshLogs(), 2000);
  }

  aboutToDisappear(): void {
    this.service.unsubscribe(this.listener);
    if (this.logTimer !== -1) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
  }

  private refreshLogs(): void {
    this.logs = Logger.recent(40);
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message, duration: 2500 });
  }

  /** 一个人类可读的连接状态 */
  private stateLabel(): string {
    const snap = this.snapshot;
    if (snap === null) return '未初始化';
    switch (snap.transportState) {
      case 'open':
        return '已连接';
      case 'connecting':
        return '连接中';
      case 'closed':
        return '已断开，正在重连';
      default:
        return '未连接';
    }
  }

  private stateColor(): ResourceColor {
    const snap = this.snapshot;
    if (snap === null) return '#8A8F99';
    if (snap.transportState === 'open') return '#1FA84F';
    if (snap.transportState === 'connecting') return '#E8A33D';
    return '#E84026';
  }

  /** 当前数据源种类（未初始化时按偏好存储里的值兜底） */
  private currentSourceKind(): SourceKind {
    if (this.snapshot !== null) return this.snapshot.sourceKind;
    return this.service.getSourceKind();
  }

  private currentSourceLabel(): string {
    if (this.snapshot !== null) return this.snapshot.sourceName;
    return sourceLabel(this.service.getSourceKind());
  }

  /** 切换数据源。会顺带停掉正在进行的采集，避免两个源往同一 seq 上写。 */
  private async switchSource(kind: SourceKind): Promise<void> {
    if (this.currentSourceKind() === kind) return;
    this.busy = true;
    try {
      const wasRunning = this.service.isRunning();
      await this.service.setSourceKind(kind);
      this.toast(`已切换到「${sourceLabel(kind)}」${wasRunning ? '，采集已停止，请重新点开始' : ''}`);
      this.snapshot = this.service.getSnapshot();
    } catch (err) {
      const e = err as BusinessError;
      this.toast(`切换失败：${e.message}`);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('HealthLink 采集端')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182431')
        Blank()
        Text(this.preload.preloaded ? '预加载启动' : '常规启动')
          .fontSize(11)
          .fontColor('#8A8F99')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 10 }) {
          this.SourceCard()
          this.StatusCard()
          this.ControlCard()
          this.SettingsCard()
          this.MetricsCard()
          if (this.snapshot !== null && this.snapshot.lastSleep !== null) {
            this.SleepCard(this.snapshot.lastSleep)
          }
          this.LogCard()
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }

  // ------------------------------------------------------------ 数据源卡

  /**
   * 数据源选择。这是 BLE 直连版新增的核心入口。
   *
   * 为什么要给用户这个选择：
   *   · BLE 直连：不需要任何华为审批，能读标准心率服务的设备可实时读心率
   *   · Health Kit：能读睡眠/血氧/HRV/压力等完整数据，但需要 AGC 资质审核
   * 两条路各有权衡，让用户自己决定，而不是我替他选死。
   */
  @Builder
  SourceCard() {
    Column({ space: 10 }) {
      Row() {
        Text('数据源')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
        Blank()
        Text(this.currentSourceLabel())
          .fontSize(12)
          .fontColor('#0A59F7')
      }
      .width('100%')

      Row({ space: 8 }) {
        this.SourceOption('ble', 'BLE 直连', '手表/手环/心率带\n无需华为审批')
        this.SourceOption('healthStore', '华为 Health Kit', '睡眠/血氧/HRV 等\n需 AGC 审核')
      }
      .width('100%')

      if (this.currentSourceKind() === 'ble') {
        Divider().color('#EEF0F2')
        Row() {
          Column({ space: 2 }) {
            Text(this.snapshot !== null && this.snapshot.bleConnected
              ? `已连接：${this.snapshot.bleDeviceName}`
              : '尚未连接蓝牙设备')
              .fontSize(13)
              .fontColor(this.snapshot !== null && this.snapshot.bleConnected ? '#1FA84F' : '#E84026')
            if (this.snapshot !== null && this.snapshot.bleConnected && this.snapshot.bleBattery >= 0) {
              Text(`设备电量 ${this.snapshot.bleBattery}%`)
                .fontSize(11)
                .fontColor('#8A8F99')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button(this.snapshot !== null && this.snapshot.bleConnected ? '管理设备' : '连接设备')
            .fontSize(13)
            .height(34)
            .backgroundColor('#0A59F7')
            .onClick(() => {
              router.pushUrl({ url: 'pages/BleDevices' }).catch((e: BusinessError) => {
                this.toast(`打开蓝牙页失败：${e.message}`);
              });
            })
        }
        .width('100%')

        Text('BLE 能读到什么取决于设备暴露什么。支持标准心率服务（0x180D）的设备可实时读心率；睡眠/血氧/HRV/压力通常属于厂商私有协议，蓝牙读不到。')
          .fontSize(11)
          .fontColor('#8A8F99')
          .width('100%')
      } else {
        Divider().color('#EEF0F2')
        Text('Health Kit 需要先在 AGC 申请数据权限（人工审核，约 15 个工作日），且个人开发者通常拿不到高阶健康数据。没批下来时建议先用 BLE 直连。')
          .fontSize(11)
          .fontColor('#E8A33D')
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  @Builder
  SourceOption(kind: string, title: string, desc: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(this.currentSourceKind() === kind ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentSourceKind() === kind ? '#0A59F7' : '#182431')
      Text(desc)
        .fontSize(10)
        .fontColor('#8A8F99')
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .padding(8)
    .borderRadius(8)
    .backgroundColor(this.currentSourceKind() === kind ? '#E8F0FE' : '#F7F8FA')
    .border({
      width: this.currentSourceKind() === kind ? 1.5 : 1,
      color: this.currentSourceKind() === kind ? '#0A59F7' : '#EEF0F2'
    })
    .onClick(() => {
      this.switchSource(kind as SourceKind);
    })
  }

  // ------------------------------------------------------------ 状态卡

  @Builder
  StatusCard() {
    Column({ space: 8 }) {
      Row() {
        Text('连接状态')
          .fontSize(13)
          .fontColor('#8A8F99')
        Blank()
        Row({ space: 6 }) {
          // 用小方块 + 圆角画状态圆点，而不是 Circle().fill()：
          // Circle 的 fill() 重载标注 @since 26，而本工程 compatibleSdkVersion 是
          // 5.0.0(12)，编译器会报 "The 'fill' API is supported since SDK version
          // 26.0.0" 的兼容性警告，且在低版本设备上不可用。
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.stateColor())
          Text(this.stateLabel())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.stateColor())
        }
      }
      .width('100%')

      Divider().color('#EEF0F2')

      this.InfoRow('设备 ID', this.shortDeviceId())
      this.InfoRow('电脑地址', this.serverUrl.length > 0 ? this.serverUrl : '（未设置）')
      this.InfoRow('采集周期', `${Math.round(this.collectSeconds())} 秒`)
      this.InfoRow('已分配序号', `${this.snapshot === null ? 0 : this.snapshot.lastSeq}（不等于已送达）`)
      this.InfoRow('已送达 / 排队 / 丢弃',
        `${this.snapshot === null ? 0 : this.snapshot.sentCount} / ${this.snapshot === null ? 0 : this.snapshot.pendingCount} / ${this.snapshot === null ? 0 : this.snapshot.droppedCount}`)
      this.InfoRow('长时任务',
        this.snapshot !== null && this.snapshot.backgroundTaskRunning
          ? `运行中（${this.snapshot.backgroundModes.join(' + ')}）`
          : '未运行（退后台会被挂起）')
      this.InfoRow('数据源', this.currentSourceLabel())
      this.InfoRow('数据源状态', this.snapshot === null ? '—' : this.snapshot.sourceStateText)
      if (this.currentSourceKind() === 'ble') {
        this.InfoRow('蓝牙设备',
          this.snapshot !== null && this.snapshot.bleConnected
            ? this.snapshot.bleDeviceName
            : '未连接')
      } else {
        this.InfoRow('HealthStore',
          this.snapshot !== null && this.snapshot.healthStoreReady ? '已初始化' : '未初始化')
      }
      this.InfoRow('预加载类型', this.preload.label)

      if (this.snapshot !== null && this.snapshot.lastError.length > 0) {
        Text(this.snapshot.lastError)
          .fontSize(12)
          .fontColor('#E84026')
          .width('100%')
          .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#8A8F99')
        .width('38%')
      Text(value)
        .fontSize(13)
        .fontColor('#182431')
        .layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .maxLines(2)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  // ------------------------------------------------------------ 控制卡

  @Builder
  ControlCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Button(this.service.isRunning() ? '停止采集' : '开始采集')
          .layoutWeight(1)
          .backgroundColor(this.service.isRunning() ? '#E84026' : '#0A59F7')
          .enabled(!this.busy)
          .onClick(() => {
            this.toggleCollect();
          })
        Button('立即同步')
          .layoutWeight(1)
          .backgroundColor('#E8F0FE')
          .fontColor('#0A59F7')
          .enabled(!this.busy)
          .onClick(() => {
            this.syncNow();
          })
      }
      .width('100%')

      // 授权按钮只对 Health Kit 数据源有意义。
      // BLE 路径不需要任何华为授权，显示它们只会让用户困惑。
      if (this.currentSourceKind() === 'healthStore') {
        Row({ space: 10 }) {
          Button('请求健康数据授权')
            .layoutWeight(1)
            .backgroundColor('#E8F0FE')
            .fontColor('#0A59F7')
            .enabled(!this.busy)
            .onClick(() => {
              this.requestHealthAuth();
            })
          Button('查询已有授权')
            .layoutWeight(1)
            .backgroundColor('#F1F3F5')
            .fontColor('#182431')
            .enabled(!this.busy)
            .onClick(() => {
              this.queryHealthAuth();
            })
        }
        .width('100%')

        Text(this.authMessage)
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
      } else {
        Text('BLE 直连不需要华为授权。若还没连设备，先去上面「连接设备」选你的手表/手环/心率带。')
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 设置卡

  @Builder
  SettingsCard() {
    Column({ space: 10 }) {
      Row() {
        Text('电脑地址')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
        Blank()
        Text(this.showSettings ? '收起' : '展开')
          .fontSize(12)
          .fontColor('#0A59F7')
          .onClick(() => {
            this.showSettings = !this.showSettings;
          })
      }
      .width('100%')

      if (this.showSettings) {
        Text('把电脑端启动时打印的 ws:// 地址整行粘进来，包含 ?token= 部分')
          .fontSize(11)
          .fontColor('#8A8F99')
          .width('100%')

        TextInput({ text: this.serverUrl, placeholder: 'ws://192.168.1.5:18787/ingest?token=xxxxxxxx' })
          .fontSize(13)
          .onChange((value: string) => {
            this.serverUrl = value;
          })
          .onSubmit(() => {
            this.saveUrl();
          })

        Row({ space: 10 }) {
          Button('保存地址')
            .layoutWeight(1)
            .backgroundColor('#0A59F7')
            .enabled(!this.busy)
            .onClick(() => {
              this.saveUrl();
            })
          Button('清空日志')
            .layoutWeight(1)
            .backgroundColor('#F1F3F5')
            .fontColor('#182431')
            .onClick(() => {
              Logger.clear();
              this.refreshLogs();
            })
        }
        .width('100%')

        Row() {
          Text('开机自动开始采集')
            .fontSize(13)
            .fontColor('#182431')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: AppPrefs.getBool(KEYS.autoStart, false) })
            .onChange((isOn: boolean) => {
              AppPrefs.put(KEYS.autoStart, isOn).catch(() => {
                Logger.warn('Index', '保存自动启动设置失败');
              });
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 指标卡

  @Builder
  MetricsCard() {
    Column({ space: 8 }) {
      Row() {
        Text('最近一轮采集')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
        Blank()
        Text(this.snapshot !== null && this.snapshot.lastSampleAt > 0
          ? formatTime(this.snapshot.lastSampleAt)
          : '暂无数据')
          .fontSize(12)
          .fontColor('#8A8F99')
      }
      .width('100%')

      if (this.snapshot === null || this.snapshot.lastSamples.length === 0) {
        Text('还没有采集到数据。点击“开始采集”后，如果一直为空，请检查：\n1) 是否已请求并通过健康数据授权\n2) 华为运动健康 App 是否已启动过\n3) 设备是否已登录华为账号')
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
      } else {
        ForEach(this.snapshot.lastSamples, (item: SamplePayload) => {
          Row() {
            Text(metricLabel(item.metric))
              .fontSize(13)
              .fontColor('#182431')
              .width('40%')
            Text(metricValueText(item))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#0A59F7')
              .layoutWeight(1)
          }
          .width('100%')
        }, (item: SamplePayload, index: number) => `${item.metric}-${index}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 睡眠卡

  @Builder
  SleepCard(sleep: SleepPayload) {
    Column({ space: 10 }) {
      Text('最近一次睡眠')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182431')
        .width('100%')

      Row({ space: 8 }) {
        this.SleepStat('睡眠得分', sleep.sleepScore === null || sleep.sleepScore === undefined ? '--' : `${sleep.sleepScore}`)
        this.SleepStat('时长', `${Math.round(sleep.duration / 60)} 分`)
        this.SleepStat('睡眠效率', sleep.sleepEfficiency === null || sleep.sleepEfficiency === undefined ? '--' : `${sleep.sleepEfficiency}%`)
      }
      .width('100%')

      Text(`入睡 ${formatTime(sleep.fallAsleepTime)}  出睡 ${formatTime(sleep.wakeupTime)}`)
        .fontSize(12)
        .fontColor('#8A8F99')
        .width('100%')

      if (sleep.sleepSegment !== undefined && sleep.sleepSegment.length > 0) {
        Text('睡眠分期')
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
        this.SleepStrip(sleep)
        this.SleepLegend()
      } else {
        Text('本次睡眠没有分期明细（详情字段 sleepSegment 为空）')
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
      }

      Row({ space: 8 }) {
        this.SleepStat('深睡', `${Math.round((sleep.deepDuration ?? 0) / 60)} 分`)
        this.SleepStat('浅睡', `${Math.round((sleep.shallowDuration ?? 0) / 60)} 分`)
        this.SleepStat('REM', `${Math.round((sleep.dreamDuration ?? 0) / 60)} 分`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  @Builder
  SleepStat(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#182431')
      Text(label)
        .fontSize(11)
        .fontColor('#8A8F99')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /** 睡眠分期色带：按每段时长占比横向排布 */
  @Builder
  SleepStrip(sleep: SleepPayload) {
    Row() {
      ForEach(sleep.sleepSegment, (seg: SleepSegmentPayload, index: number) => {
        Row()
          .layoutWeight(Math.max(1, Math.round(seg.endTime - seg.startTime)))
          .height(22)
          .backgroundColor(SLEEP_COLORS[seg.sleepStatus] ?? '#DEE2E6')
      }, (seg: SleepSegmentPayload, index: number) => `${index}-${seg.sleepStatus}-${seg.startTime}`)
    }
    .width('100%')
    .height(22)
    .borderRadius(6)
    .clip(true)
  }

  @Builder
  SleepLegend() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach([1, 2, 3, 4], (status: number) => {
        Row({ space: 4 }) {
          // 同状态圆点：不用 Circle().fill()，原因见上面状态卡里的注释
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(SLEEP_COLORS[status])
          Text(sleepStatusLabel(status))
            .fontSize(10)
            .fontColor('#8A8F99')
        }
        .margin({ right: 10, top: 4 })
      }, (status: number) => `legend-${status}`)
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 日志卡

  @Builder
  LogCard() {
    Column({ space: 8 }) {
      Text('运行日志')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182431')
        .width('100%')

      if (this.logs.length === 0) {
        Text('暂无日志')
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
      } else {
        List({ space: 4 }) {
          ForEach(this.logs, (line: LogLine) => {
            ListItem() {
              Row({ space: 6 }) {
                Text(formatClock(line.ts))
                  .fontSize(10)
                  .fontColor('#8A8F99')
                  .width(58)
                Text(line.level)
                  .fontSize(10)
                  .fontColor(levelColor(line.level))
                  .width(14)
                Text(`[${line.tag}] ${line.message}`)
                  .fontSize(11)
                  .fontColor('#182431')
                  .layoutWeight(1)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
          }, (line: LogLine, index: number) => `${line.ts}-${index}`)
        }
        .width('100%')
        .height(180)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 交互逻辑

  private shortDeviceId(): string {
    const snap = this.snapshot;
    if (snap === null || snap.deviceId.length === 0) return '（生成中）';
    const id = snap.deviceId;
    return id.length > 12 ? `${id.substring(0, 8)}…${id.substring(id.length - 4)}` : id;
  }

  private collectSeconds(): number {
    const snap = this.snapshot;
    return snap === null ? 60 : snap.collectIntervalMs / 1000;
  }

  private async toggleCollect(): Promise<void> {
    this.busy = true;
    try {
      if (this.service.isRunning()) {
        await this.service.stop();
        this.toast('已停止采集');
      } else {
        if (this.serverUrl.length === 0) {
          this.toast('请先填写电脑地址');
          return;
        }
        await this.service.setServerUrl(this.serverUrl);
        await this.service.start();
        this.toast('已开始采集并上传');
      }
    } catch (err) {
      const e = err as BusinessError;
      this.toast(`操作失败：${e.message}`);
    } finally {
      this.busy = false;
    }
  }

  private async syncNow(): Promise<void> {
    this.busy = true;
    try {
      await this.service.syncNow();
      this.toast('已手动同步一轮');
    } catch (err) {
      const e = err as BusinessError;
      this.toast(`同步失败：${e.message}`);
    } finally {
      this.busy = false;
    }
  }

  private async saveUrl(): Promise<void> {
    const trimmed = this.serverUrl.trim();
    if (!trimmed.startsWith('ws://') && !trimmed.startsWith('wss://')) {
      this.toast('地址必须以 ws:// 或 wss:// 开头');
      return;
    }
    await this.service.setServerUrl(trimmed);
    this.serverUrl = trimmed;
    this.toast('电脑地址已保存');
  }

  /**
   * 请求健康数据授权。
   * 注意：这是 OAuth 授权（用户级），不是权限声明。如果 AGC 侧没申请过对应数据权限，
   * 这里会返回未通过，属于预期结果。
   */
  private async requestHealthAuth(): Promise<void> {
    this.busy = true;
    try {
      const context = this.service.getContext();
      if (context === null) {
        this.toast('上下文未就绪，请稍后重试');
        return;
      }
      const result = await this.service.getHealthClient().requestAuthorizations(context);
      this.authMessage = `${result.message}${result.denied.length > 0 ? `（未通过：${result.denied.join('、')}）` : ''}`;
      this.service.setAuthorizedMetrics(result.granted);
      this.toast(result.message);
    } catch (err) {
      const e = err as BusinessError;
      this.authMessage = `请求授权异常：${e.message}`;
      this.toast(this.authMessage);
    } finally {
      this.busy = false;
    }
  }

  private async queryHealthAuth(): Promise<void> {
    this.busy = true;
    try {
      const result = await this.service.getHealthClient().getAuthorizations();
      this.authMessage = `${result.message}${result.granted.length > 0 ? `（已通过：${result.granted.join('、')}）` : ''}`;
      this.service.setAuthorizedMetrics(result.granted);
    } catch (err) {
      const e = err as BusinessError;
      this.authMessage = `查询授权异常：${e.message}`;
    } finally {
      this.busy = false;
    }
  }
}

// ---------------------------------------------------------------- 纯函数辅助

function metricLabel(metric: HealthMetric): string {
  switch (metric) {
    case 'heart_rate':
      return '动态心率';
    case 'resting_heart_rate':
      return '静息心率';
    case 'hrv':
      return '心率变异性';
    case 'spo2':
      return '血氧饱和度';
    case 'stress':
      return '压力得分';
    case 'sleep':
      return '睡眠';
    case 'sleep_nap':
      return '零星小睡';
    case 'body_temperature':
      return '体温';
    default:
      return metric;
  }
}

function metricValueText(payload: SamplePayload): string {
  if (payload.metric === 'sleep') {
    const sleep = payload.sleep;
    if (sleep === null || sleep === undefined) return '无明细';
    const score = sleep.sleepScore === null || sleep.sleepScore === undefined ? '--' : `${sleep.sleepScore}`;
    return `得分 ${score}，时长 ${Math.round(sleep.duration / 60)} 分`;
  }
  const unit = payload.unit === null ? '' : payload.unit;
  return `${payload.value} ${unit}`;
}

function formatTime(ms: number): string {
  if (!ms || ms <= 0) return '--';
  const d = new Date(ms);
  const hh = pad2(d.getHours());
  const mm = pad2(d.getMinutes());
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${hh}:${mm}`;
}

function formatClock(ms: number): string {
  const d = new Date(ms);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

function levelColor(level: string): string {
  switch (level) {
    case 'E':
      return '#E84026';
    case 'W':
      return '#E8A33D';
    case 'I':
      return '#0A59F7';
    default:
      return '#8A8F99';
  }
}
