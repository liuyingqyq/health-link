// ============================================================================
//  HealthLink BLE 诊断探针
//
//  目的：在"PC 蓝牙桥连不上心率带"时，一次性把下面这些事实打出来，
//        避免靠猜：
//    1) 蓝牙无线电（Radio）的真实开关状态 —— 关着的话，适配器对象依然存在、
//       IsLowEnergySupported 依然 true，但扫不到任何包、按地址也取不到设备对象
//    2) 适配器能力（是否支持 BLE / 中心角色）
//    3) Active 与 Passive 两种扫描模式各收多少包 —— 判断是"没设备广播"
//       还是"这个模式的扫描被驱动吞了"
//    4) 按地址取 BluetoothLEDevice（桥里失败的那一步），以及用 DeviceInformation
//       枚举"已配对但当前不在广播"的设备
//
//  用法：
//    dotnet run --project tools\ble-diag -- [蓝牙地址] [扫描秒数]
//    例：dotnet run --project tools\ble-diag -- AA:BB:CC:DD:EE:FF 8
//
//  输出：纯文本，直接给人看（不走 JSON）
// ============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Enumeration;
using Windows.Devices.Radios;

namespace BleDiag
{
    internal static class Program
    {
        private static async Task<int> Main(string[] args)
        {
            Console.OutputEncoding = Encoding.UTF8;

            ulong target = 0;
            int scanSeconds = 8;
            if (args.Length > 0 && args[0].Length > 0)
            {
                string hex = args[0].Replace(":", "").Replace("-", "");
                if (!ulong.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out target))
                {
                    Console.WriteLine("地址解析失败: " + args[0]);
                    return 1;
                }
            }
            if (args.Length > 1) int.TryParse(args[1], out scanSeconds);

            Line("1) 无线电状态（Radio）");
            try
            {
                var radios = await Radio.GetRadiosAsync();
                if (radios.Count == 0) Console.WriteLine("  (没有任何无线电)");
                foreach (var r in radios)
                {
                    Console.WriteLine("  {0,-10} {1,-8} state={2}", r.Kind, r.Name, r.State);
                }
                var bt = radios.FirstOrDefault(r => r.Kind == RadioKind.Bluetooth);
                if (bt == null) Console.WriteLine("  ✗ 没有找到 Bluetooth 类型的无线电");
                else if (bt.State != RadioState.On)
                    Console.WriteLine("  ✗✗ 蓝牙无线电处于 " + bt.State + " —— 这就是扫不到包的根本原因");
                else Console.WriteLine("  ✓ 蓝牙无线电已打开");
            }
            catch (Exception ex)
            {
                Console.WriteLine("  读取无线电失败: " + ex.Message);
            }

            Line("2) 适配器能力");
            BluetoothAdapter adapter = null;
            try
            {
                adapter = await BluetoothAdapter.GetDefaultAsync();
                if (adapter == null)
                {
                    Console.WriteLine("  ✗ 没有蓝牙适配器");
                }
                else
                {
                    Console.WriteLine("  地址            " + FormatAddress(adapter.BluetoothAddress));
                    Console.WriteLine("  低功耗(BLE)支持 " + adapter.IsLowEnergySupported);
                    Console.WriteLine("  中心角色支持    " + adapter.IsCentralRoleSupported);
                    Console.WriteLine("  外设角色支持    " + adapter.IsPeripheralRoleSupported);
                    Console.WriteLine("  广告卸载支持    " + adapter.IsAdvertisementOffloadSupported);
                    Console.WriteLine("  经典蓝牙支持    " + adapter.IsClassicSupported);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("  读取适配器失败: " + ex.Message);
            }

            Line("3) 两种扫描模式各收多少包（" + scanSeconds + " 秒）");
            var activeSet = await ScanAsync(adapter, BluetoothLEScanningMode.Active, scanSeconds);
            var passiveSet = await ScanAsync(adapter, BluetoothLEScanningMode.Passive, scanSeconds);

            Line("4) 按地址取设备对象（桥里失败的那一步）");
            if (target != 0)
            {
                string addr = FormatAddress(target);
                Console.WriteLine("  目标地址 " + addr);
                try
                {
                    var dev = await BluetoothLEDevice.FromBluetoothAddressAsync(target);
                    if (dev == null) Console.WriteLine("  ✗ FromBluetoothAddressAsync 返回 null");
                    else
                    {
                        Console.WriteLine("  ✓ FromBluetoothAddressAsync 成功: name='" + dev.Name + "' status=" + dev.ConnectionStatus);
                        Console.WriteLine("    DeviceId=" + dev.DeviceId);
                        var svc = await dev.GetGattServicesAsync(BluetoothCacheMode.Uncached);
                        Console.WriteLine("    GATT services: status=" + svc.Status + " count=" + svc.Services.Count);
                        foreach (var s in svc.Services) Console.WriteLine("      " + s.Uuid);
                        dev.Dispose();
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  ✗ FromBluetoothAddressAsync 抛异常: " + ex.GetType().Name + " 0x" +
                        ex.HResult.ToString("X8") + " " + ex.Message);
                }

                // 换一条路：从 DeviceInformation 里找（已配对设备即使不在广播也在设备库里）
                try
                {
                    string sel = BluetoothLEDevice.GetDeviceSelectorFromBluetoothAddress(target);
                    var found = await DeviceInformation.FindAllAsync(sel);
                    Console.WriteLine("  DeviceInformation 按地址查到 " + found.Count + " 个");
                    foreach (var di in found)
                    {
                        Console.WriteLine("    id=" + di.Id);
                        Console.WriteLine("    name=" + di.Name + "  IsEnabled=" + di.IsEnabled);
                        try
                        {
                            var dev2 = await BluetoothLEDevice.FromIdAsync(di.Id);
                            Console.WriteLine("      FromIdAsync => " + (dev2 == null ? "null" : "ok, status=" + dev2.ConnectionStatus));
                            if (dev2 != null)
                            {
                                // 关键：拿到对象以后真的去连一次 GATT，看系统给什么状态。
                                // Unreachable = 设备不在广播/不在范围内（没戴、没电、或正被别的中心连着）
                                // AccessDenied = 系统拒绝，通常是被别的中心持有
                                var svc = await dev2.GetGattServicesAsync(BluetoothCacheMode.Uncached);
                                Console.WriteLine("      GATT(Uncached) => " + svc.Status + "，服务数 " + svc.Services.Count);
                                foreach (var s in svc.Services) Console.WriteLine("        " + s.Uuid);
                                dev2.Dispose();
                            }
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine("      FromIdAsync 抛异常: 0x" + ex.HResult.ToString("X8") + " " + ex.Message);
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  DeviceInformation 查询失败: " + ex.Message);
                }
            }

            Line("5) 全部已配对/已知 BLE 设备（不依赖广播）");
            try
            {
                var all = await DeviceInformation.FindAllAsync(BluetoothLEDevice.GetDeviceSelector());
                Console.WriteLine("  共 " + all.Count + " 个");
                foreach (var di in all)
                {
                    string addrHint = "";
                    try
                    {
                        var d = await BluetoothLEDevice.FromIdAsync(di.Id);
                        if (d != null) { addrHint = " [" + FormatAddress(d.BluetoothAddress) + "]"; d.Dispose(); }
                    }
                    catch { }
                    Console.WriteLine("    " + di.Name + addrHint);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("  枚举失败: " + ex.Message);
            }

            Line("结论提示");
            bool anyPackets = activeSet.Count > 0 || passiveSet.Count > 0;
            if (!anyPackets)
                Console.WriteLine("  两种模式都收不到广播包 → 问题在无线电/驱动层，不在心率带，也不在代码。");
            else if (passiveSet.Count == 0)
                Console.WriteLine("  Active 有包、Passive 没包 → 应改用 Active 扫描模式。");
            else Console.WriteLine("  Active/Passive 都有包 → 扫描正常，问题在设备侧（没佩戴/被手机占用/地址不对）。");

            return 0;
        }

        private static async Task<Dictionary<ulong, string>> ScanAsync(
            BluetoothAdapter adapter, BluetoothLEScanningMode mode, int seconds)
        {
            var seen = new Dictionary<ulong, string>();
            var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = mode };
            int packets = 0;

            watcher.Received += (s, a) =>
            {
                packets++;
                string name = a.Advertisement.LocalName ?? "";
                var uuids = a.Advertisement.ServiceUuids.Select(u => ShortUuid(u)).ToList();
                string desc = string.Format("rssi={0} svc=[{1}]", a.RawSignalStrengthInDBm, string.Join(",", uuids));
                lock (seen)
                {
                    if (!seen.ContainsKey(a.BluetoothAddress))
                        seen[a.BluetoothAddress] = (name.Length > 0 ? name : "(无名)") + "  " + desc;
                    else if (name.Length > 0 && seen[a.BluetoothAddress].StartsWith("(无名)"))
                        seen[a.BluetoothAddress] = name + "  " + desc;
                }
            };
            watcher.Stopped += (s, a) =>
            {
                if (a.Error != BluetoothError.Success)
                    Console.WriteLine("  扫描被中断: " + a.Error);
            };

            try { watcher.Start(); }
            catch (Exception ex) { Console.WriteLine("  " + mode + " 启动失败: " + ex.Message); return seen; }

            var status = watcher.Status;
            await Task.Delay(seconds * 1000);
            try { watcher.Stop(); } catch { }

            Console.WriteLine("  [{0}] 状态={1} 包数={2} 设备数={3}", mode, status, packets, seen.Count);
            foreach (var kv in seen.OrderBy(k => k.Key))
                Console.WriteLine("      " + FormatAddress(kv.Key) + "  " + kv.Value);
            return seen;
        }

        private static string ShortUuid(Guid g)
        {
            string s = g.ToString();
            if (s.EndsWith("-0000-1000-8000-00805f9b34fb", StringComparison.OrdinalIgnoreCase))
                return s.Substring(4, 4).ToUpperInvariant();
            return s;
        }

        private static string FormatAddress(ulong addr)
        {
            if (addr == 0) return "00:00:00:00:00:00";
            string hex = addr.ToString("X12");
            return string.Join(":", Enumerable.Range(0, 6).Select(i => hex.Substring(i * 2, 2)));
        }

        private static void Line(string title)
        {
            Console.WriteLine();
            Console.WriteLine("── " + title + " " + new string('─', Math.Max(0, 50 - title.Length)));
        }
    }
}
