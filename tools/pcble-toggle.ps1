# ============================================================================
#  开启 / 关闭「电脑直连心率带」（PC 蓝牙桥）
#
#  为什么有这个脚本：
#    pcBle 默认是关闭的（避免没编译桥时反复报错）。
#    要开启得手改 config.json 或设环境变量，对普通用户太麻烦。
#    这个脚本把"改配置 + 检查前置条件"一次做完，双击即可。
#
#  用法：
#    .\tools\pcble-toggle.ps1           # 开启
#    .\tools\pcble-toggle.ps1 -Disable  # 关闭
# ============================================================================

param(
  [switch]$Disable
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ProjectRoot = Split-Path -Parent $PSScriptRoot     # tools -> 项目根
$ConfigFile = Join-Path $ProjectRoot 'pc\config.json'

function Line { Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkGray }
function Ok   { param([string]$T) Write-Host "  [√] $T" -ForegroundColor Green }
function Bad  { param([string]$T) Write-Host "  [×] $T" -ForegroundColor Red }
function Warn { param([string]$T) Write-Host "  [!] $T" -ForegroundColor Yellow }
function Info { param([string]$T) Write-Host "      $T" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ('    HealthLink · ' + $(if ($Disable) { '关闭' } else { '开启' }) + '电脑直连心率带') -ForegroundColor Cyan
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ---- 1) 配置必须存在 ----
if (-not (Test-Path $ConfigFile)) {
  Bad '还没有 pc\config.json'
  Info '请先双击「启动.cmd」启动过一次服务，它会生成配置。'
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}

# ---- 2) 开启前先检查桥是否已编译 ----
$exe = Join-Path $ProjectRoot 'pc\ble\bin\Release\net8.0-windows10.0.19041.0\win-x64\HealthLinkBle.exe'
if (-not $Disable) {
  Write-Host '  检查前置条件'
  Line
  if (Test-Path $exe) {
    Ok "蓝牙桥已编译（$([math]::Round((Get-Item $exe).Length/1KB,1)) KB）"
  } else {
    Bad '蓝牙桥还没编译'
    Info ''
    Info '先双击这个文件编译（需要 .NET SDK 8）：'
    Info '    pc\ble\build-ble.ps1'
    Info ''
    Info '如果没装 .NET SDK，一条命令装上：'
    Info '    winget install Microsoft.DotNet.SDK.8'
    Write-Host ''
    $go = Read-Host '  现在就自动编译吗？(y=编译 / 回车退出)'
    if ($go -eq 'y' -or $go -eq 'Y') {
      & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectRoot 'pc\ble\build-ble.ps1')
      if (-not (Test-Path $exe)) {
        Bad '编译后仍找不到 HealthLinkBle.exe，请检查上面的输出'
        Read-Host '  按回车退出'
        exit 1
      }
      Ok '编译完成'
    } else {
      exit 1
    }
  }
  Write-Output ''
}

# ---- 3) 改配置 ----
Write-Host '  更新配置'
Line
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $cfg.PSObject.Properties['pcBle']) {
  $cfg | Add-Member -NotePropertyName 'pcBle' -NotePropertyValue ([pscustomobject]@{}) -Force
}
$want = if ($Disable) { $false } else { $true }
$cfg.pcBle | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $want -Force

# 记住上次用的地址（避免每次重新扫描）
if (-not $Disable -and -not $cfg.pcBle.PSObject.Properties['address']) {
  $cfg.pcBle | Add-Member -NotePropertyName 'address' -NotePropertyValue '' -Force
}
if (-not $cfg.pcBle.PSObject.Properties['deviceName']) {
  $cfg.pcBle | Add-Member -NotePropertyName 'deviceName' -NotePropertyValue '' -Force
}

# 写回（无 BOM，JSON.parse 才认）
$json = $cfg | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Ok ("pcBle.enabled = " + $want)

# 校验写回的文件能被解析
try {
  $check = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($check.pcBle.enabled -ne $want) { throw '写回后读到的值不对' }
  Ok '配置已写回并校验通过'
} catch {
  Bad "配置写回后无法解析：$($_.Exception.Message)"
  Read-Host '  按回车退出'
  exit 1
}

# ---- 4) 提示下一步 ----
Write-Host ''
Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Green
if ($Disable) {
  Write-Host '    已关闭电脑直连' -ForegroundColor Green
  Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Green
  Write-Host ''
  Write-Host '  以后启动服务就不会去连心率带了。' -ForegroundColor White
  Write-Host '  （手机中转那条路不受影响）' -ForegroundColor DarkGray
} else {
  Write-Host '    已开启电脑直连' -ForegroundColor Green
  Write-Host '  ══════════════════════════════════════════════════════' -ForegroundColor Green
  Write-Host ''
  Write-Host '  现在双击「启动.cmd」即可 —— 服务会自己连心率带。' -ForegroundColor White
  Write-Host ''
  Write-Host '  开之前请确认：' -ForegroundColor Yellow
  Write-Host '    1. 心率带戴在手臂上（贴着皮肤）' -ForegroundColor DarkGray
  Write-Host '    2. 手机上的 HealthLink 已停止、手机蓝牙已关' -ForegroundColor DarkGray
  Write-Host '       （BLE 设备同一时刻只能被一个中心连接）' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '  想省掉每次扫描的 10-30 秒，可以填上蓝牙地址：' -ForegroundColor DarkGray
  Write-Host '    双击 测试蓝牙.cmd 扫到地址后，把它填进 pc\config.json：' -ForegroundColor DarkGray
  Write-Host '      "pcBle": { "enabled": true, "address": "AA:BB:CC:DD:EE:FF" }' -ForegroundColor DarkGray
}
Write-Host ''
Read-Host '  按回车退出'
