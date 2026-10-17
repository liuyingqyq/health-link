// ============================================================================
//  HealthLink PC BLE 桥
//
//  作用：让**电脑自己**通过蓝牙直连心率设备（如 CooSpo HW9 心率臂带），
//        把心率以 JSON Lines 的形式打到 stdout，交给 Node 服务端消费。
//
//  为什么用 C#：
//    · Node 的 BLE 库（noble 等）需要 npm 下载原生模块，本机 npm 源不可用，
//      且与 Node 24 兼容性差。
//    · Windows 自带 .NET 编译器（csc.exe）+ 内置 WinRT 蓝牙 API，
//      **零外部依赖**，与本项目"零依赖"的约束一致。
//
//  标准心率服务（由蓝牙 SIG 规定，任何合规心率设备都实现）：
//    服务 0000180D-0000-1000-8000-00805F9B34FB
//    特征 00002A37-0000-1000-8000-00805F9B34FB  心率测量
//      byte0 = flags，bit0=0 → uint8 心率；bit0=1 → uint16 小端
//      bit4 = 是否含 RR 间期；bit3 = 是否含能量消耗
//    描述符 00002902-0000-1000-8000-00805F9B34FB  CCCD（开启通知必须写它）
//
//  stdout 协议（每行一个 JSON）：
//    {"t":"ready"}                                   桥已启动
//    {"t":"scan"}                                    开始扫描
//    {"t":"found","name":"...","id":"..."}           发现候选设备
//    {"t":"connecting","id":"..."}                   正在连接
//    {"t":"connected","name":"...","id":"..."}       已连接并订阅成功
//    {"t":"hr","bpm":98,"rr":[800],"contact":true}   收到心率
//    {"t":"disconnected","reason":"..."}             断开
//    {"t":"error","msg":"..."}                       错误
//    {"t":"log","msg":"..."}                         调试信息
//
//  退出码：0 正常结束；1 参数错误；2 蓝牙不可用；3 找不到设备；4 运行期致命错误
// ============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

namespace HealthLinkBle
{
    internal static class Program
    {
        // 标准心率服务与特征
        private static readonly Guid HeartRateServiceUuid = Guid.Parse("0000180d-0000-1000-8000-00805f9b34fb");
        private static readonly Guid HeartRateMeasurementUuid = Guid.Parse("00002a37-0000-1000-8000-00805f9b34fb");
        private static readonly Guid BatteryServiceUuid = Guid.Parse("0000180f-0000-1000-8000-00805f9b34fb");
        private static readonly Guid BatteryLevelUuid = Guid.Parse("00002a19-0000-1000-8000-00805f9b34fb");

        private static readonly object OutputLock = new object();

        private static string _deviceName = "";       // 只要名字里包含这个串就连接
        private static int _scanTimeoutSec = 25;
        private static int _reconnectDelaySec = 5;
        private static bool _verbose = false;
        private static string _addressArg = "";

        private static async Task<int> Main(string[] args)
        {
            if (!ParseArgs(args)) return 1;

            // ⚠️ 中文输出必须显式声明 UTF-8。
            //    默认 Console.Out 走控制台代码页（中文 Windows = GBK/936），
            //    而 Node 端按 UTF-8 解码子进程 stdout —— 中文会变成一串乱码
            //    （"指定地址" 显示成 "(ָ����ַ)" 就是这个原因，还会被写进面板和设备名）。
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }

            // Ctrl+C / 关闭窗口 时优雅退出（停掉扫描、断开设备）
            Console.CancelKeyPress += (s, e) =>
            {
                e.Cancel = false;
                Environment.Exit(0);
            };

            Emit("{\"t\":\"ready\"}");
            Log("HealthLink PC BLE 桥启动");
            Log("目标设备名匹配串: " + (_deviceName.Length > 0 ? _deviceName : "(不限，取第一个有名字的设备)"));
            if (_addressArg.Length > 0) Log("指定蓝牙地址: " + _addressArg);

            // 蓝牙可用性检查
            try
            {
                var radio = await BluetoothAdapter.GetDefaultAsync();
                if (radio == null)
                {
                    Emit("{\"t\":\"error\",\"msg\":\"没有找到蓝牙适配器（电脑可能没有蓝牙硬件，或驱动未装）\"}");
                    return 2;
                }
                if (!radio.IsLowEnergySupported)
                {
                    Emit("{\"t\":\"error\",\"msg\":\"蓝牙适配器不支持低功耗蓝牙（BLE）\"}");
                    return 2;
                }
                Log(string.Format("蓝牙适配器就绪（地址 {0}）", FormatAddress(radio.BluetoothAddress)));
            }
            catch (Exception ex)
            {
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr("访问蓝牙失败: " + ex.Message) + "}");
                return 2;
            }

            // 主循环：连接 → 收数据 → 断开则重连
            int consecutiveFailures = 0;
            while (true)
            {
                try
                {
                    ulong addr = 0;
                    string foundName = "";
                    bool found = false;

                    if (_addressArg.Length > 0)
                    {
                        addr = ulong.Parse(_addressArg.Replace(":", "").Replace("-", ""), NumberStyles.HexNumber);
                        found = true;
                        foundName = "(指定地址)";
                        Emit("{\"t\":\"found\",\"name\":\"(指定地址)\",\"id\":\"" + FormatAddress(addr) + "\"}");

                        // 先用一次短扫描探路。两个作用：
                        //   1) 把"设备到底在不在广播"这条事实打出来 —— 没扫到时
                        //      日志能明确说"0 个广播包"，而不是只报一句笼统的失败；
                        //   2) 唤醒可能处于休眠/卡死状态的 LE 扫描栈（Intel 网卡常见），
                        //      顺带把设备塞进系统蓝牙缓存，后面按地址取对象更容易成功。
                        await ProbeAdvertisementsAsync(addr, Math.Min(_scanTimeoutSec, 10));
                    }
                    else
                    {
                        found = await ScanForDeviceAsync(
                            (a, n) => { addr = a; foundName = n; },
                            _scanTimeoutSec * 1000);
                    }

                    if (!found)
                    {
                        Emit("{\"t\":\"error\",\"msg\":\"没找到心率设备。请确认：1) 心率带已佩戴并贴着皮肤 2) 心率带没被手机或其他 App 占用（一个设备同时只能被一个中心连接）\"}");
                        return 3;
                    }

                    Emit("{\"t\":\"connecting\",\"id\":\"" + FormatAddress(addr) + "\"}");
                    Log("正在连接 " + FormatAddress(addr) + " (" + foundName + ")"
                        + (consecutiveFailures > 0 ? "（第 " + (consecutiveFailures + 1) + " 次尝试）" : ""));

                    int rc = await RunConnectedAsync(addr, foundName);
                    if (rc == 0) return 0;   // 正常退出（Ctrl+C）

                    consecutiveFailures++;
                }
                catch (Exception ex)
                {
                    Emit("{\"t\":\"error\",\"msg\":" + JsonStr(ex.Message) + "}");
                    consecutiveFailures++;
                }

                Emit("{\"t\":\"disconnected\",\"reason\":\"等待重连\"}");

                // 退避：连续失败时逐步拉长间隔（5→10→20→40→60 秒封顶）。
                // 原来固定 5 秒重试，一旦蓝牙栈卡住就会把同一行 warn 刷满整个控制台。
                int delaySec = _reconnectDelaySec;
                for (int i = 0; i < Math.Min(consecutiveFailures, 3); i++) delaySec *= 2;
                if (delaySec > 60) delaySec = 60;

                Log(string.Format("{0} 秒后重试连接…", delaySec));
                Thread.Sleep(delaySec * 1000);
            }
        }

        /// <summary>
        /// 只扫描、不连接：数一数这段时间收到多少广播包、目标设备有没有出现。
        ///
        /// 为什么单独做这件事：
        ///   桥连不上时，"设备没在广播" 和 "蓝牙扫描栈卡死" 是两种完全不同的病，
        ///   但原来的日志里都只显示一句"无法获取设备对象"，根本分不清。
        ///   这里把收到的包数和设备清单打出来，一眼就能定位。
        /// </summary>
        private static async Task<bool> ProbeAdvertisementsAsync(ulong targetAddr, int timeoutSec)
        {
            var seen = new HashSet<ulong>();
            int packets = 0;
            bool targetSeen = false;
            var tcs = new TaskCompletionSource<bool>();

            var watcher = new BluetoothLEAdvertisementWatcher
            {
                ScanningMode = BluetoothLEScanningMode.Active
            };

            watcher.Received += (s, a) =>
            {
                try
                {
                    Interlocked.Increment(ref packets);
                    if (a.BluetoothAddress == targetAddr)
                    {
                        targetSeen = true;
                        tcs.TrySetResult(true);
                    }
                    if (seen.Add(a.BluetoothAddress) && _verbose)
                    {
                        var uuids = new List<string>();
                        foreach (var u in a.Advertisement.ServiceUuids) uuids.Add(u.ToString().Substring(4, 4).ToUpperInvariant());
                        Log(string.Format("  扫描到: {0} [{1}] rssi={2} 服务=[{3}]",
                            string.IsNullOrEmpty(a.Advertisement.LocalName) ? "(无名)" : a.Advertisement.LocalName,
                            FormatAddress(a.BluetoothAddress),
                            a.RawSignalStrengthInDBm,
                            string.Join(",", uuids)));
                    }
                }
                catch { }
            };

            try { watcher.Start(); }
            catch (Exception ex)
            {
                Log("扫描启动失败: " + ex.Message);
                return false;
            }

            var done = await Task.WhenAny(tcs.Task, Task.Delay(timeoutSec * 1000));
            try { watcher.Stop(); } catch { }

            if (targetSeen)
            {
                Log(string.Format("扫描确认目标设备在广播（本次共 {0} 个广播包）", Volatile.Read(ref packets)));
            }
            else if (packets == 0)
            {
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr(
                    "扫描 " + timeoutSec + " 秒，一个 BLE 广播包都没收到 —— 问题在电脑的蓝牙扫描栈，不在心率带。"
                    + "处理办法：把 Windows 的蓝牙开关关掉再打开（或重启蓝牙驱动），然后重启本服务。") + "}");
            }
            else
            {
                Log(string.Format("扫描 {0} 秒收到 {1} 个广播包，但没见到目标设备 {2} —— "
                    + "多半是心率带没戴/没电，或正被手机上的 App 连着（BLE 同一时刻只能被一个中心连接）",
                    timeoutSec, Volatile.Read(ref packets), FormatAddress(targetAddr)));
            }
            return targetSeen;
        }

        // ---------------------------------------------------------------- 参数
        private static bool ParseArgs(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--name":
                        if (i + 1 < args.Length) _deviceName = args[++i];
                        break;
                    case "--address":
                        if (i + 1 < args.Length) _addressArg = args[++i];
                        break;
                    case "--scan-timeout":
                        if (i + 1 < args.Length) int.TryParse(args[++i], out _scanTimeoutSec);
                        break;
                    case "--reconnect-delay":
                        if (i + 1 < args.Length) int.TryParse(args[++i], out _reconnectDelaySec);
                        break;
                    case "--verbose":
                        _verbose = true;
                        break;
                    case "--list":
                        _deviceName = ""; // 列出所有设备后退出，见下
                        _scanTimeoutSec = 8;
                        break;
                    default:
                        Console.Error.WriteLine("未知参数: " + args[i]);
                        Console.Error.WriteLine("用法: rathole-ble --name HW9 [--address MAC] [--scan-timeout 25] [--verbose]");
                        return false;
                }
            }
            return true;
        }

        // ---------------------------------------------------------------- 扫描
        private static async Task<bool> ScanForDeviceAsync(Action<ulong, string> onFound, int timeoutMs)
        {
            var tcs = new TaskCompletionSource<bool>();
            var seen = new HashSet<ulong>();
            int totalPackets = 0;
            int namedDevices = 0;

            var watcher = new BluetoothLEAdvertisementWatcher
            {
                // Passive 更宽松：实测 Active 模式在本机偶发收不到包，
                // 而 Passive 能稳定收到广播（代价：拿不到扫描响应里的名字，
                // 所以下面按 180D 服务 UUID 判断，不依赖名字）。
                ScanningMode = BluetoothLEScanningMode.Passive
            };

            var timer = new Timer(_ =>
            {
                try { watcher.Stop(); } catch { }
                tcs.TrySetResult(false);
            }, null, timeoutMs, Timeout.Infinite);

            watcher.Received += (sender, args) =>
            {
                try
                {
                    Interlocked.Increment(ref totalPackets);
                    ulong addr = args.BluetoothAddress;

                    string name = args.Advertisement.LocalName ?? "";

                    // ⚠️ 心率带常常**不广播设备名**（名字放在扫描响应里，或干脆没有），
                    //    所以不能只靠名字判断。这里两条判据取或：
                    //      1) 广播里带标准心率服务 180D（最可靠）
                    //      2) 名字匹配（用户显式指定了 --name 时）
                    bool hrAdvertised = false;
                    foreach (var u in args.Advertisement.ServiceUuids)
                    {
                        if (u == HeartRateServiceUuid) { hrAdvertised = true; break; }
                    }
                    bool nameMatch = _deviceName.Length > 0 &&
                                     name.IndexOf(_deviceName, StringComparison.OrdinalIgnoreCase) >= 0;

                    if (!hrAdvertised && !nameMatch)
                    {
                        // 不相关也记一笔（只在 verbose 下），否则"0 包"和"有包但不匹配"分不清
                        if (_verbose)
                        {
                            Log(string.Format("  忽略: {0} [{1}] 服务数={2} rssi={3}",
                                name.Length > 0 ? name : "(无名)",
                                FormatAddress(addr),
                                args.Advertisement.ServiceUuids.Count,
                                args.RawSignalStrengthInDBm));
                        }
                        return;
                    }

                    if (!seen.Add(addr)) return;               // 同一台只处理一次
                    Interlocked.Increment(ref namedDevices);

                    if (_verbose)
                    {
                        Log(string.Format("  发现心率设备: {0} [{1}] 广播180D={2} rssi={3}",
                            name.Length > 0 ? name : "(无名)",
                            FormatAddress(addr),
                            hrAdvertised ? "是" : "否",
                            args.RawSignalStrengthInDBm));
                    }

                    Emit("{\"t\":\"found\",\"name\":" + JsonStr(name) + ",\"id\":\"" + FormatAddress(addr) + "\"}");
                    onFound(addr, name);
                    try { watcher.Stop(); } catch { }
                    tcs.TrySetResult(true);
                }
                catch { /* 单个广播包解析失败不影响扫描 */ }
            };

            // 扫描被系统中断时要能感知（常见原因：蓝牙被关闭、权限被拒）
            watcher.Stopped += (sender, args) =>
            {
                if (args.Error != BluetoothError.Success)
                {
                    Emit("{\"t\":\"error\",\"msg\":" + JsonStr("BLE 扫描被中断: " + args.Error +
                        "（若为 RadioNotAvailable 请检查蓝牙开关；AccessDenied 请在系统设置里允许应用访问蓝牙）") + "}");
                    tcs.TrySetResult(false);
                }
            };

            Emit("{\"t\":\"scan\"}");
            watcher.Start();
            Log("开始扫描 BLE 设备…（状态=" + watcher.Status + "，模式=" + watcher.ScanningMode + "）");

            // 周期性汇报收包数：这样"0 包"和"有包但不匹配"能区分开
            var progressTimer = new Timer(_ =>
            {
                Log(string.Format("扫描中… 已收到 {0} 个广播包，匹配 {1} 个",
                    Volatile.Read(ref totalPackets), Volatile.Read(ref namedDevices)));
            }, null, 5000, 5000);

            bool ok = await tcs.Task;
            timer.Dispose();
            progressTimer.Dispose();
            try { watcher.Stop(); } catch { }

            if (!ok)
            {
                Log(string.Format("扫描结束：共收到 {0} 个广播包，其中带名字的设备 {1} 个", totalPackets, namedDevices));
                if (totalPackets == 0)
                {
                    Emit("{\"t\":\"error\",\"msg\":" + JsonStr(
                        "完全没有收到任何 BLE 广播包。可能原因：1) 电脑蓝牙被关闭或驱动异常 " +
                        "2) 应用没有蓝牙访问权限 3) 蓝牙硬件不支持 BLE") + "}");
                }
            }
            return ok;
        }

        // ---------------------------------------------------------------- 连接与订阅
        private static async Task<int> RunConnectedAsync(ulong address, string name)
        {
            BluetoothLEDevice device = null;

            // 第一条路：按地址取设备对象。
            //  ⚠️ 这条路有个坑：设备此刻没在广播、或系统蓝牙缓存里没有它时，
            //     它会直接返回 null（不是抛异常）。原来的代码就卡在这里，
            //     报一句"无法获取设备对象（可能已被其他程序占用）"，然后 5 秒一轮死循环。
            try
            {
                device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            }
            catch (Exception ex)
            {
                Log("按地址取设备对象抛异常: 0x" + ex.HResult.ToString("X8") + " " + ex.Message);
            }

            // 第二条路：从系统"已配对/已知设备库"里按地址找到它，再用 DeviceId 打开。
            //  已配对过的设备即使当前不在广播，这条路通常也能拿到对象，
            //  之后真去连 GATT 时会给出明确状态（Unreachable / AccessDenied），
            //  比 null 有诊断价值得多。
            if (device == null)
            {
                Log("按地址取设备对象返回 null，改从系统已配对设备库里找…");
                device = await TryOpenPairedDeviceAsync(address);
            }

            if (device == null)
            {
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr(
                    "拿不到设备对象：系统蓝牙没有认出 " + FormatAddress(address) + "。"
                    + "常见原因：1) 心率带没佩戴/没电，压根没开机 2) 正被手机上的 App 连着"
                    + "（BLE 同一时刻只能被一个中心持有）3) 蓝牙扫描栈处于休眠状态 —— "
                    + "把 Windows 蓝牙开关关掉再打开即可。") + "}");
                return 4;
            }

            Log(string.Format("拿到设备对象（{0}，当前状态 {1}）", device.Name, device.ConnectionStatus));

            var done = new ManualResetEventSlim(false);

            // 断开事件：通知上层，回主循环重连
            device.ConnectionStatusChanged += (s, e) =>
            {
                try
                {
                    if (device.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
                    {
                        Emit("{\"t\":\"disconnected\",\"reason\":\"设备侧断开\"}");
                        done.Set();
                    }
                }
                catch { }
            };

            // 拿心率服务
            //  ⚠️ 踩过的坑：默认查询走系统 GATT 缓存，在某些状态下会返回
            //     AccessDenied（尤其设备之前被别的中心连接过、或读写过多次之后）。
            //     实测用 Uncached 能读到全部服务，所以这里先默认、失败再 Uncached 重试。
            GattDeviceServicesResult svcResult = await device.GetGattServicesForUuidAsync(HeartRateServiceUuid);
            if (svcResult.Status != GattCommunicationStatus.Success || svcResult.Services.Count == 0)
            {
                Log("默认模式查心率服务失败（" + svcResult.Status + "），改用 Uncached 重试…");
                await Task.Delay(500);
                svcResult = await device.GetGattServicesForUuidAsync(
                    HeartRateServiceUuid, BluetoothCacheMode.Uncached);
            }

            if (svcResult.Status != GattCommunicationStatus.Success || svcResult.Services.Count == 0)
            {
                string hint = svcResult.Status == GattCommunicationStatus.AccessDenied
                    ? "访问被系统拒绝。常见原因：1) 心率带正被手机/其他 App 占用（BLE 同一时刻只能被一个中心持有）"
                      + " 2) Windows 蓝牙栈状态陈旧 —— 把电脑蓝牙开关关掉再打开可清除"
                    : "这个设备没有标准心率服务(0x180D)。说明它的心率数据走厂商私有协议，"
                      + "标准蓝牙读不到（华为手表就是这种情况，需要厂商 SDK）";
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr(
                    "拿不到心率服务：状态=" + svcResult.Status + "。" + hint) + "}");
                try { device.Dispose(); } catch { }
                return 4;
            }

            var service = svcResult.Services[0];

            // 拿心率测量特征（同样先默认、失败再 Uncached）
            GattCharacteristicsResult chrResult = await service.GetCharacteristicsForUuidAsync(HeartRateMeasurementUuid);
            if (chrResult.Status != GattCommunicationStatus.Success || chrResult.Characteristics.Count == 0)
            {
                Log("默认模式查 2A37 失败（" + chrResult.Status + "），改用 Uncached 重试…");
                await Task.Delay(500);
                chrResult = await service.GetCharacteristicsForUuidAsync(
                    HeartRateMeasurementUuid, BluetoothCacheMode.Uncached);
            }

            if (chrResult.Status != GattCommunicationStatus.Success || chrResult.Characteristics.Count == 0)
            {
                // 再把该服务的全部特征列出来，方便判断是"特征真的不存在"还是"访问被拒"
                string detail = "";
                try
                {
                    var all = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
                    var names = new System.Collections.Generic.List<string>();
                    foreach (var c in all.Characteristics) names.Add(c.Uuid.ToString().Substring(4, 4));
                    detail = "（该服务实际特征：" + (names.Count > 0 ? string.Join(",", names) : "无") +
                             "，状态=" + all.Status + "）";
                }
                catch { }

                string hint = chrResult.Status == GattCommunicationStatus.AccessDenied
                    ? "访问被拒。心率带很可能正被手机或其他 App 占用；"
                      + "也可能是 Windows 蓝牙缓存陈旧 —— 把电脑蓝牙开关关掉再打开即可清除。"
                    : "找到了心率服务但读不到心率测量特征(0x2A37)。";
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr(hint + detail) + "}");
                try { device.Dispose(); } catch { }
                return 4;
            }

            var hrChar = chrResult.Characteristics[0];

            // 订阅通知
            GattCharacteristicProperties props = hrChar.CharacteristicProperties;
            bool supportsNotify = (props & GattCharacteristicProperties.Notify) != 0;
            if (!supportsNotify)
            {
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr("心率特征不支持通知（Notify），无法实时读取") + "}");
                try { device.Dispose(); } catch { }
                return 4;
            }

            var status = await hrChar.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (status != GattCommunicationStatus.Success)
            {
                Emit("{\"t\":\"error\",\"msg\":" + JsonStr("订阅心率通知失败，状态=" + status) + "}");
                try { device.Dispose(); } catch { }
                return 4;
            }

            hrChar.ValueChanged += (s, e) =>
            {
                try
                {
                    var reader = DataReader.FromBuffer(e.CharacteristicValue);
                    byte[] buf = new byte[e.CharacteristicValue.Length];
                    reader.ReadBytes(buf);
                    ParseAndEmitHeartRate(buf);
                }
                catch (Exception ex)
                {
                    Log("解析心率数据失败: " + ex.Message);
                }
            };

            Emit("{\"t\":\"connected\",\"name\":" + JsonStr(name) + ",\"id\":\"" + FormatAddress(address) + "\"}");
            Log("已连接并订阅心率通知，开始接收数据");

            // 顺手读一下电量（失败不影响主流程）
            await TryReadBatteryAsync(device);

            // 阻塞在这里，直到断开或进程被结束
            try
            {
                while (!done.Wait(1000))
                {
                    // 每秒复核一次连接状态，防止漏掉 ConnectionStatusChanged 事件
                    try
                    {
                        if (device.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
                        {
                            Emit("{\"t\":\"disconnected\",\"reason\":\"连接状态变为已断开\"}");
                            break;
                        }
                    }
                    catch { }
                }
            }
            finally
            {
                try
                {
                    await hrChar.WriteClientCharacteristicConfigurationDescriptorAsync(
                        GattClientCharacteristicConfigurationDescriptorValue.None);
                }
                catch { }
                try { service.Dispose(); } catch { }
                try { device.Dispose(); } catch { }
            }

            return 4;   // 让主循环重连
        }

        /// <summary>
        /// 从系统设备库里按蓝牙地址找到已配对的 BLE 设备，再用 DeviceId 打开它。
        ///
        /// 为什么需要这条路：
        ///   BluetoothLEDevice.FromBluetoothAddressAsync 依赖"这个地址当前在系统 LE 缓存里"
        ///   （也就是设备此刻正在广播，或刚广播过）。设备暂时不在广播时它返回 null，
        ///   但设备其实还在系统配对库里 —— 这时用 DeviceInformation 查到 DeviceId，
        ///   再 FromIdAsync 就能拿到对象，把问题从"取不到设备"推进到"设备能不能连"。
        /// </summary>
        private static async Task<BluetoothLEDevice> TryOpenPairedDeviceAsync(ulong address)
        {
            try
            {
                string selector = BluetoothLEDevice.GetDeviceSelectorFromBluetoothAddress(address);
                var infos = await DeviceInformation.FindAllAsync(selector);
                if (infos == null || infos.Count == 0)
                {
                    Log("系统设备库里没有这个地址（设备可能从未与这台电脑配对过）");
                    return null;
                }
                foreach (var info in infos)
                {
                    Log(string.Format("设备库命中: {0}  IsEnabled={1}", info.Name, info.IsEnabled));
                    try
                    {
                        var dev = await BluetoothLEDevice.FromIdAsync(info.Id);
                        if (dev != null) return dev;
                    }
                    catch (Exception ex)
                    {
                        Log("按 DeviceId 打开失败: 0x" + ex.HResult.ToString("X8") + " " + ex.Message);
                    }
                }
            }
            catch (Exception ex)
            {
                Log("查询系统设备库失败: " + ex.Message);
            }
            return null;
        }

        private static async Task TryReadBatteryAsync(BluetoothLEDevice device)
        {
            try
            {
                var svc = await device.GetGattServicesForUuidAsync(BatteryServiceUuid);
                if (svc.Status != GattCommunicationStatus.Success || svc.Services.Count == 0) return;
                var chr = await svc.Services[0].GetCharacteristicsForUuidAsync(BatteryLevelUuid);
                if (chr.Status != GattCommunicationStatus.Success || chr.Characteristics.Count == 0) return;
                var read = await chr.Characteristics[0].ReadValueAsync();
                if (read.Status != GattCommunicationStatus.Success) return;
                var r = DataReader.FromBuffer(read.Value);
                byte pct = r.ReadByte();
                Emit("{\"t\":\"battery\",\"percent\":" + pct + "}");
            }
            catch { }
        }

        // ---------------------------------------------------------------- 解析心率
        /// <summary>
        /// 按蓝牙 SIG 的心率测量格式解析。
        /// flags(byte0) bit0 = 0 → 心率是 uint8（byte1）
        ///                    = 1 → 心率是 uint16 小端（byte1~2）
        /// </summary>
        private static void ParseAndEmitHeartRate(byte[] d)
        {
            if (d == null || d.Length < 2) return;
            byte flags = d[0];
            bool isUint16 = (flags & 0x01) != 0;
            bool hasEnergy = (flags & 0x08) != 0;
            bool hasRR = (flags & 0x10) != 0;

            int bpm;
            int idx;
            if (isUint16)
            {
                bpm = d[1] | (d[2] << 8);
                idx = 3;
            }
            else
            {
                bpm = d[1];
                idx = 2;
            }
            if (bpm <= 0 || bpm > 300) return;   // 明显异常值丢弃

            if (hasEnergy) idx += 2;             // 跳过能量消耗字段

            var rrList = new List<double>();
            if (hasRR)
            {
                while (idx + 1 < d.Length)
                {
                    int raw = d[idx] | (d[idx + 1] << 8);
                    rrList.Add(raw);                 // RR 间期单位 1/1024 秒
                    idx += 2;
                }
            }

            // bit2 = 传感器接触状态（1=检测到皮肤接触）
            bool contact = (flags & 0x04) != 0;

            var sb = new StringBuilder();
            sb.Append("{\"t\":\"hr\",\"bpm\":").Append(bpm);
            if (rrList.Count > 0)
            {
                sb.Append(",\"rr\":[");
                for (int i = 0; i < rrList.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append(rrList[i].ToString("0.#", CultureInfo.InvariantCulture));
                }
                sb.Append(']');
            }
            if (hasEnergy) sb.Append(",\"contact\":").Append(contact ? "true" : "false");
            sb.Append('}');
            Emit(sb.ToString());
        }

        // ---------------------------------------------------------------- 输出
        private static void Emit(string json)
        {
            lock (OutputLock)
            {
                Console.Out.WriteLine(json);
                Console.Out.Flush();
            }
        }

        private static void Log(string msg)
        {
            Emit("{\"t\":\"log\",\"msg\":" + JsonStr(msg) + "}");
        }

        private static string JsonStr(string s)
        {
            if (s == null) return "\"\"";
            var sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }

        private static string FormatAddress(ulong addr)
        {
            string hex = addr.ToString("X12");
            return string.Join(":", Enumerable.Range(0, 6).Select(i => hex.Substring(i * 2, 2)));
        }
    }
}
