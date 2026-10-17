# ============================================================================
#  HealthLink PC 蓝牙桥 · 编译脚本
#
#  用法：双击本文件，或在项目根目录执行 .\pc\ble\build-ble.ps1
#
#  为什么要写这个脚本：
#    编译需要 .NET **SDK**（不是运行时）。很多人机器上只有运行时，
#    直接 dotnet build 会报 "No .NET SDKs were found"，
#    但错误信息里看不出该怎么解决。这里把前置检查和编译一起做掉。
# ============================================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Here = $PSScriptRoot
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

function Line { Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkGray }
function Ok   { param([string]$T) Write-Host "  [√] $T" -ForegroundColor Green }
function Bad  { param([string]$T) Write-Host "  [×] $T" -ForegroundColor Red }
function Warn { param([string]$T) Write-Host "  [!] $T" -ForegroundColor Yellow }
function Info { param([string]$T) Write-Host "      $T" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '    HealthLink PC 蓝牙桥 · 编译' -ForegroundColor Cyan
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- 检查 dotnet
Write-Host '  1) 检查 .NET SDK'
Line
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
  Bad '没找到 dotnet 命令'
  Info ''
  Info '请先安装 .NET SDK 8（注意：必须装 SDK，只装运行时不行的）：'
  Info ''
  Info '  winget install Microsoft.DotNet.SDK.8'
  Info ''
  Info '或者去 https://dotnet.microsoft.com/download 下载「SDK」'
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}

$sdks = & dotnet --list-sdks 2>&1
if (-not $sdks) {
  Bad '只装了 .NET 运行时，没有 SDK（能"跑"程序，但不能"编译"程序）'
  Info ''
  Info '解决方法（一条命令）：'
  Info ''
  Info '  winget install Microsoft.DotNet.SDK.8'
  Info ''
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}
Ok 'dotnet 已安装'
foreach ($s in $sdks) { Info $s }

# 是否满足最低版本（需要 8.0 以上才支持 net8.0-windows TFM）
$hasEnough = $false
foreach ($s in $sdks) {
  if ($s -match '^(\d+)\.') { if ([int]$Matches[1] -ge 8) { $hasEnough = $true } }
}
if (-not $hasEnough) {
  Bad 'SDK 版本低于 8.0，本项目的目标框架需要 8.0 或更高'
  Info '请安装：winget install Microsoft.DotNet.SDK.8'
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}
Ok 'SDK 版本满足要求（≥ 8.0）'

# ---------------------------------------------------------------- 编译
Write-Host ''
Write-Host '  2) 编译'
Line
Push-Location $Here
try {
  & dotnet build -c Release --nologo 2>&1 | ForEach-Object { Info $_ }
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}

Write-Host ''
if ($code -ne 0) {
  Bad "编译失败（退出码 $code）"
  Write-Host ''
  Info '常见原因：'
  Info '  · 缺少 Windows SDK 组件（WinRT 投影）'
  Info '  · .NET SDK 版本不匹配'
  Info '  · 代码里有语法错误'
  Write-Host ''
  Read-Host '  按回车退出'
  exit $code
}

# ---------------------------------------------------------------- 验证产物
Write-Host '  3) 验证产物'
Line
$exe = Join-Path $Here 'bin\Release\net8.0-windows10.0.19041.0\win-x64\HealthLinkBle.exe'
if (Test-Path $exe) {
  $kb = [math]::Round((Get-Item $exe).Length / 1KB, 1)
  Ok "已生成 HealthLinkBle.exe（$kb KB）"
  Info $exe
} else {
  Bad '编译报告成功，但找不到 HealthLinkBle.exe'
  Read-Host '  按回车退出'
  exit 1
}

# 依赖的运行时 DLL 也在（缺了 exe 跑不起来）
$dir = Split-Path $exe -Parent
$needDlls = @('Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll')
foreach ($d in $needDlls) {
  if (Test-Path (Join-Path $dir $d)) { Ok "运行时依赖齐备：$d" }
  else { Warn "缺少 $d —— 请重新编译（不要手动删 bin 目录）" }
}

# ---------------------------------------------------------------- 提示下一步
Write-Host ''
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '    编译完成' -ForegroundColor Green
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '  下一步：测试能不能发现你的心率带' -ForegroundColor White
Write-Host ''
Write-Host '  先确认这两件事：' -ForegroundColor Yellow
Write-Host '    1. 心率带戴在手臂上（要贴着皮肤，不戴多数型号不广播）'
Write-Host '    2. 手机上的 HealthLink 已停止（BLE 设备同一时刻只能被一个中心连接）'
Write-Host ''
Write-Host '  然后双击项目根目录的： 测试蓝牙.cmd' -ForegroundColor Green
Write-Host '  （或在项目根目录执行下面的命令）' -ForegroundColor DarkGray
Write-Host "    .\pc\ble\bin\Release\net8.0-windows10.0.19041.0\win-x64\HealthLinkBle.exe --verbose --scan-timeout 60" -ForegroundColor DarkGray
Write-Host ''
Read-Host '  按回车退出'
