---
name: Bug 报告
about: 报告一个问题（崩溃、连不上、数据不对）
title: '[Bug] '
labels: bug
---

## 先说三件事

1. **别贴 `pc/config.json` 的内容**——里面有你的访问令牌。贴之前把 `authToken` 换掉。
2. 日志请**整段贴**，不要只贴报错那一行（前后文才有诊断价值）。
3. 蓝牙相关的问题，请先跑一次体检探针，把输出贴上来：

```powershell
dotnet run --project tools\ble-diag -- <你的心率带地址> 8
```

## 环境

- 操作系统与版本（如 Windows 11 23H2）：
- Node.js 版本（`node --version`）：
- 用的是哪条链路：手机 App / PC 蓝牙桥 / 两者都开
- 手机型号 + 系统版本（涉及手机端时）：

## 复现步骤

1.
2.
3.

## 期望结果 vs 实际结果

期望：

实际：

## 日志 / 输出

```
（贴这里）
```

## 我已经排查过的

- [ ] 手机 App 已停止（用 PC 蓝牙桥时，BLE 设备同一时刻只能被一个中心连接）
- [ ] 心率带已佩戴并贴合皮肤
- [ ] 18787 端口没有被防火墙拦
- [ ] 已跑过 `tools/ble-diag` / `node tools/netcheck.js`
