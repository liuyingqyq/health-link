/**
 * 蓝牙设备页 —— 扫描、连接、查看设备到底暴露了什么。
 *
 * 这个页面有个很重要的设计意图：**让用户亲眼看到设备暴露的服务列表**。
 * 因为"BLE 能不能读到健康数据"完全取决于设备暴露了什么：
 *   · 看到 180D（心率服务）→ 能实时读心率
 *   · 只看到 180A/180F 等 → 厂商把数据藏在私有协议里，BLE 读不到健康数据
 * 与其让用户对着一句"没有数据"猜，不如把事实摆出来。
 */

import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

import { Logger } from '../common/Logger';
import { AppPrefs, KEYS } from '../common/Prefs';
import { CollectionService } from '../service/CollectionService';
import { BleClientEvents, DiscoveredCharacteristic, DiscoveredDevice, DiscoveredService } from '../ble/BleClient';

/** 扫描持续时长（毫秒）。BLE 扫描很耗电，不能一直扫。 */
const SCAN_DURATION_MS = 15000;

@Entry
@Component
struct BleDevices {
  @State devices: DiscoveredDevice[] = [];
  @State services: DiscoveredService[] = [];
  @State connectedName: string = '';
  @State connectedId: string = '';
  @State isScanning: boolean = false;
  @State isConnected: boolean = false;
  @State statusText: string = '未连接任何设备';
  @State healthOnly: boolean = true;
  @State message: string = '';
  @State showUnknownServices: boolean = false;

  private service: CollectionService = CollectionService.getInstance();
  private ble = CollectionService.getInstance().getBleSource();
  private scanTimer: number = -1;
  /** 本页注册的 BLE 事件（退出时要注销，避免悬挂引用与重复回调） */
  private pageEvents: BleClientEvents = {};

  aboutToAppear(): void {
    // 把 BLE 事件接到本页状态上。
    // ⚠️ setEvents 现在是"合并注册"：不会顶掉 BleHealthSource 已注册的回调
    //    （旧实现是整体覆盖，导致本页连上设备后心率永远到不了数据源）。
    const client = this.ble.getClient();
    this.pageEvents = {
      onDeviceFound: (d: DiscoveredDevice) => {
        this.upsertDevice(d);
      },
      onConnectionChange: (state: string, deviceId: string) => {
        this.statusText = this.describeConnState(state);
        this.isConnected = state === 'connected';
      },
      onServices: (svc: DiscoveredService[]) => {
        this.services = svc;
        this.reportServiceFindings(svc);
      },
      onCharacteristicValue: (svcUuid: string, charUuid: string, value: Uint8Array) => {
        // 本页不显示数值，但不拦截 —— 数据源的回调会独立收到同一份数据
      },
      onError: (msg: string) => {
        this.message = msg;
      }
    };
    client.setEvents(this.pageEvents);

    // 恢复上次连接的设备名（只是提示，不会自动重连 —— 自动重连会让用户莫名其妙连上）
    this.connectedName = AppPrefs.getString(KEYS.bleDeviceName, '');
    if (this.connectedName.length > 0) {
      this.statusText = `上次连接过「${this.connectedName}」，点它重新连接`;
    }
  }

  aboutToDisappear(): void {
    this.stopScanTimer();
    this.ble.stopScan();
    // 注销本页回调：数据源（BleHealthSource）的回调不受影响，继续收心率
    this.ble.getClient().clearEvents(this.pageEvents);
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor('#0A59F7')
          .onClick(() => {
            this.ble.stopScan();
            router.back();
          })
        Blank()
        Text('蓝牙设备')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182431')
        Blank()
        // 占位，让标题居中
        Text('    ').fontSize(16)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .backgroundColor(Color.White)

      Scroll() {
        Column({ space: 10 }) {
          this.StatusCard()
          this.ScanCard()
          if (this.message.length > 0) {
            this.MessageCard()
          }
          this.DeviceListCard()
          if (this.services.length > 0) {
            this.ServiceCard()
          }
          this.HelpCard()
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
          // 状态圆点用「小方块 + 圆角」实现，不用 Circle().fill()：
          // 该 fill() 重载 @since 26，本工程 compatibleSdkVersion 是 5.0.0(12)，
          // 会触发兼容性警告且在低版本设备上不可用。
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.isConnected ? '#1FA84F' : '#E8A33D')
          Text(this.isConnected ? '已连接' : '未连接')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isConnected ? '#1FA84F' : '#E8A33D')
        }
      }
      .width('100%')

      if (this.connectedName.length > 0) {
        this.InfoRow('当前设备', this.connectedName)
      }
      this.InfoRow('状态', this.statusText)
      if (this.isConnected) {
        this.InfoRow('电量', this.ble.getBatteryLevel() >= 0 ? `${this.ble.getBatteryLevel()}%` : '未读到')
      }

      if (this.isConnected) {
        Button('断开连接')
          .width('100%')
          .backgroundColor('#E84026')
          .enabled(!this.isScanning)
          .onClick(() => {
            this.doDisconnect();
          })
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
        .width('30%')
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

  // ------------------------------------------------------------ 扫描卡

  @Builder
  ScanCard() {
    Column({ space: 10 }) {
      Text('第一步：找到你的设备')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182431')
        .width('100%')

      Row() {
        Text('只看可能的健康设备（推荐）')
          .fontSize(13)
          .fontColor('#182431')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.healthOnly })
          .enabled(!this.isScanning)
          .onChange((on: boolean) => {
            this.healthOnly = on;
          })
      }
      .width('100%')

      Button(this.isScanning ? `扫描中… ${SCAN_DURATION_MS / 1000} 秒后自动停止` : '开始扫描')
        .width('100%')
        .backgroundColor(this.isScanning ? '#8A8F99' : '#0A59F7')
        .enabled(!this.isScanning)
        .onClick(() => {
          this.startScan();
        })

      Text('提示：先在系统设置里打开蓝牙；手表/手环要处于"可被发现"状态（多数设备配对模式才广播）')
        .fontSize(11)
        .fontColor('#8A8F99')
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  @Builder
  MessageCard() {
    Row({ space: 6 }) {
      Text(this.message)
        .fontSize(12)
        .fontColor('#E84026')
        .layoutWeight(1)
      Text('✕')
        .fontSize(12)
        .fontColor('#8A8F99')
        .onClick(() => {
          this.message = '';
        })
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FFF1F0')
    .borderRadius(8)
  }

  // ------------------------------------------------------------ 设备列表

  @Builder
  DeviceListCard() {
    Column({ space: 8 }) {
      Row() {
        Text(`第二步：连接设备（发现 ${this.visibleDevices().length} 个）`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
        Blank()
        if (this.devices.length > 0) {
          Text('清空')
            .fontSize(12)
            .fontColor('#0A59F7')
            .onClick(() => {
              this.devices = [];
              this.ble.getClient().clearDeviceList();
            })
        }
      }
      .width('100%')

      if (this.visibleDevices().length === 0) {
        Text(this.isScanning
          ? '正在扫描…请稍等，同时确认设备处于可被发现状态'
          : '还没有发现设备。点上面的「开始扫描」。')
          .fontSize(12)
          .fontColor('#8A8F99')
          .width('100%')
      } else {
        ForEach(this.visibleDevices(), (d: DiscoveredDevice) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Row({ space: 6 }) {
                Text(d.name)
                  .fontSize(14)
                  .fontColor('#182431')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (d.looksLikeHealthDevice) {
                  Text('疑似健康设备')
                    .fontSize(10)
                    .fontColor('#1FA84F')
                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    .backgroundColor('#E8F8EE')
                    .borderRadius(4)
                }
              }
              Text(`信号 ${d.rssi} dBm${d.advertisedServices.length > 0 ? ` · 广播服务 ${d.advertisedServices.join(', ')}` : ''}`)
                .fontSize(11)
                .fontColor('#8A8F99')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Button(this.isConnected && this.connectedId === d.deviceId ? '已连接' : '连接')
              .fontSize(13)
              .height(32)
              .backgroundColor(this.isConnected && this.connectedId === d.deviceId ? '#1FA84F' : '#0A59F7')
              .enabled(!(this.isConnected && this.connectedId === d.deviceId))
              .onClick(() => {
                this.doConnect(d);
              })
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .border({ width: { bottom: 1 }, color: '#EEF0F2' })
        }, (d: DiscoveredDevice) => d.deviceId)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 服务列表（关键诊断信息）

  @Builder
  ServiceCard() {
    Column({ space: 8 }) {
      Text('第三步：设备暴露了哪些服务')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182431')
        .width('100%')

      if (this.hasHeartRateService()) {
        Text('✓ 发现标准心率服务（0x180D），心率可以实时读取')
          .fontSize(12)
          .fontColor('#1FA84F')
          .width('100%')
          .padding(8)
          .backgroundColor('#E8F8EE')
          .borderRadius(6)
      } else {
        Text('✗ 没有发现标准心率服务（0x180D）。\n这说明该设备把健康数据放在厂商私有协议里，第三方应用通过 BLE 读不到 —— 睡眠、血氧、HRV、压力通常都属于这种情况，只能改用厂商自己的 App 或华为 Health Service Kit。')
          .fontSize(12)
          .fontColor('#E8A33D')
          .width('100%')
          .padding(8)
          .backgroundColor('#FFF8E8')
          .borderRadius(6)
      }

      Row() {
        Text(`共 ${this.services.length} 个服务，认识 ${this.countKnown()} 个`)
          .fontSize(12)
          .fontColor('#8A8F99')
        Blank()
        Text(this.showUnknownServices ? '只看认识的' : '显示全部')
          .fontSize(12)
          .fontColor('#0A59F7')
          .onClick(() => {
            this.showUnknownServices = !this.showUnknownServices;
          })
      }
      .width('100%')

      ForEach(this.visibleServices(), (s: DiscoveredService) => {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(s.serviceUuid)
              .fontSize(12)
              .fontColor('#182431')
              .fontFamily('monospace')
            Text(s.serviceName)
              .fontSize(12)
              .fontColor(s.isKnown ? '#1FA84F' : '#8A8F99')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')

          ForEach(s.characteristics, (c: DiscoveredCharacteristic) => {
            Row({ space: 6 }) {
              Text(`  ${c.characteristicUuid}`)
                .fontSize(11)
                .fontColor('#8A8F99')
                .fontFamily('monospace')
              Text(c.characteristicName)
                .fontSize(11)
                .fontColor('#8A8F99')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(c.properties.join('/'))
                .fontSize(10)
                .fontColor('#8A8F99')
              if (c.subscribed) {
                Text('已订阅')
                  .fontSize(10)
                  .fontColor('#1FA84F')
              } else if (c.properties.indexOf('通知') >= 0 || c.properties.indexOf('读') >= 0) {
                Text('订阅')
                  .fontSize(10)
                  .fontColor('#0A59F7')
                  .onClick(() => {
                    this.doToggleNotify(s.serviceUuid, c.characteristicUuid, true);
                  })
              }
              if (c.lastRawHex.length > 0) {
                Text(c.lastRawHex)
                  .fontSize(10)
                  .fontColor('#8A8F99')
                  .fontFamily('monospace')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('30%')
              }
            }
            .width('100%')
          }, (c: DiscoveredCharacteristic) => `${s.serviceUuid}-${c.characteristicUuid}`)
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .border({ width: { bottom: 1 }, color: '#F4F5F7' })
      }, (s: DiscoveredService) => s.serviceUuid)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 帮助

  @Builder
  HelpCard() {
    Column({ space: 6 }) {
      Text('连不上 / 没数据？')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182431')
        .width('100%')
      Text('· 扫描不到：手表/手环通常只在"配对模式"下广播，先在系统蓝牙设置里配对试试；心率带一般直接广播。\n· 连上但没有 180D：该设备不暴露标准心率服务，BLE 这条路读不到它，属于设备限制，不是代码问题。\n· 连上后读不到值：先确认手环戴在手上（未佩戴时有些设备上报 0，本应用会过滤）。\n· 只能读到心率：这是正常上限。睡眠/血氧/HRV/压力需要设备端算法，标准 GATT 里没有。')
        .fontSize(11)
        .fontColor('#8A8F99')
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }

  // ------------------------------------------------------------ 逻辑

  private visibleDevices(): DiscoveredDevice[] {
    const list = this.devices.slice();
    // 疑似健康设备排前面，其次按信号强度
    list.sort((a, b) => {
      if (a.looksLikeHealthDevice !== b.looksLikeHealthDevice) {
        return a.looksLikeHealthDevice ? -1 : 1;
      }
      return b.rssi - a.rssi;
    });
    if (!this.healthOnly) return list;
    const filtered = list.filter((d) => d.looksLikeHealthDevice);
    // 过滤后一个都没有时，放全部出来 —— 免得用户以为扫描坏了
    return filtered.length > 0 ? filtered : list;
  }

  private visibleServices(): DiscoveredService[] {
    if (this.showUnknownServices) return this.services;
    const known = this.services.filter((s) => s.isKnown);
    return known.length > 0 ? known : this.services;
  }

  private countKnown(): number {
    return this.services.filter((s) => s.isKnown).length;
  }

  private hasHeartRateService(): boolean {
    return this.services.some((s) => s.serviceUuid.toUpperCase() === '180D');
  }

  private upsertDevice(d: DiscoveredDevice): void {
    const idx = this.devices.findIndex((x) => x.deviceId === d.deviceId);
    if (idx >= 0) {
      // 直接替换会触发整个列表重绘，但扫描本来就每秒刷新，代价可接受
      const next = this.devices.slice();
      next[idx] = d;
      this.devices = next;
    } else {
      this.devices = this.devices.concat([d]);
    }
  }

  private startScan(): void {
    this.message = '';
    this.devices = [];
    this.isScanning = true;

    if (this.healthOnly) this.ble.scan(false);
    else this.ble.scanAll();

    this.stopScanTimer();
    this.scanTimer = setTimeout(() => {
      this.stopScan();
    }, SCAN_DURATION_MS);
  }

  private stopScanTimer(): void {
    if (this.scanTimer !== -1) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
  }

  private stopScan(): void {
    this.stopScanTimer();
    this.ble.stopScan();
    this.isScanning = false;
  }

  private async doConnect(d: DiscoveredDevice): Promise<void> {
    this.stopScan();
    this.message = '';
    this.statusText = `正在连接 ${d.name}…`;
    // ⚠️ 先把上一次的连接状态清干净再尝试。
    //    之前这里在 connect() 之前就赋值 connectedId、失败时又不清，
    //    导致连接失败后按钮仍显示「已连接」且不可点（用户会被误导）。
    this.isConnected = false;
    this.connectedId = '';
    this.services = [];

    const ok = await this.ble.connect(d);
    if (!ok) {
      this.statusText = `连接 ${d.name} 失败`;
      this.isConnected = false;
      this.connectedId = '';
      return;
    }
    // 只有真正连上了才记录
    this.isConnected = true;
    this.connectedId = d.deviceId;
    this.connectedName = d.name;
    await AppPrefs.put(KEYS.bleDeviceId, d.deviceId);
    await AppPrefs.put(KEYS.bleDeviceName, d.name);
    this.statusText = `已连接 ${d.name}`;
  }

  private async doDisconnect(): Promise<void> {
    await this.ble.disconnect();
    this.isConnected = false;
    this.services = [];
    this.statusText = '已断开';
    this.connectedId = '';
  }

  private async doToggleNotify(serviceUuid: string, charUuid: string, enable: boolean): Promise<void> {
    const ok = await this.ble.getClient().setNotify(serviceUuid, charUuid, enable);
    if (ok) {
      this.services = this.ble.getClient().discoveredServices;
    } else {
      this.message = `订阅 ${charUuid} 失败（该特征可能不允许通知）`;
    }
  }

  /** 连上后把"有没有心率服务"这个关键结论写进日志，方便用户复制反馈 */
  private reportServiceFindings(svc: DiscoveredService[]): void {
    const hasHr = svc.some((s) => s.serviceUuid.toUpperCase() === '180D');
    if (hasHr) {
      Logger.info('BleDevices', '设备暴露了标准心率服务 0x180D，心率可以读取');
    } else {
      const unknown = svc.filter((s) => !s.isKnown).map((s) => s.serviceUuid);
      Logger.warn(
        'BleDevices',
        `设备没有暴露 0x180D。私有服务：[${unknown.join(', ') || '无'}]。BLE 无法读取该设备的健康数据。`
      );
    }
  }

  private describeConnState(state: string): string {
    switch (state) {
      case 'connecting':
        return '正在连接…';
      case 'connected':
        return '已连接';
      case 'disconnected':
        return '已断开';
      default:
        return '未连接';
    }
  }
}
