# ============================================================================
#  HealthLink 接收端 · 一键启动
#
#  这份脚本是给"要看别人健康数据"的那台电脑用的，用户不需要懂技术。
#  它会：找 Node.js → 生成访问令牌 → 显示本机局域网地址 → 启动服务
#
#  注意：本文件必须保存为 UTF-8 带 BOM（Windows PowerShell 5.1 才能正确读中文）。
# ============================================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = $PSScriptRoot
$PcDir = Join-Path $Root 'pc'
$ConfigFile = Join-Path $PcDir 'config.json'

$Port = 18787
$envPort = $env:HEALTHLINK_PORT
if ($envPort) { $Port = [int]$envPort }

function Big-Line { Write-Host ('  ' + ('=' * 60)) -ForegroundColor Cyan }

# ---------------------------------------------------------------- 找 Node.js
function Find-Node {
  $c = Get-Command node -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @(
    "$env:ProgramFiles\nodejs\node.exe",
    "${env:ProgramFiles(x86)}\nodejs\node.exe",
    "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
    "$env:APPDATA\npm\node.exe"
  )) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  return $null
}

# ---------------------------------------------------------------- 本机局域网 IP
function Get-LanIp {
  $ips = @()
  try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|198\.18\.)' } |
      Select-Object -ExpandProperty IPAddress
  } catch {
    $ips = (ipconfig | Select-String 'IPv4.*?:\s*([0-9.]+)' -AllMatches).Matches |
      ForEach-Object { $_.Groups[1].Value } |
      Where-Object { $_ -notmatch '^(127\.|169\.254\.|198\.18\.)' }
  }
  $lan = $ips | Where-Object { $_ -match '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' } | Select-Object -First 1
  if (-not $lan) { $lan = $ips | Select-Object -First 1 }
  return $lan
}

function New-Token {
  $bytes = New-Object byte[] 16
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $rng.Dispose()
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------------------------------------------------------- 读/建配置
#  返回 @{ token = ...; port = ... }
#  端口以 config.json 为准：环境变量优先级比文件高，所以启动时不再设环境变量，
#  统一写进配置，避免"文件写一个端口、环境变量又是另一个"的混乱。
function Ensure-Config {
  if (Test-Path $ConfigFile) {
    try {
      $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($cfg.authToken) {
        if ($cfg.port) { $script:Port = [int]$cfg.port }
        return @{ token = $cfg.authToken; port = $script:Port }
      }
    } catch {
      Write-Host '  [!] 配置文件读不出来，将重新生成。' -ForegroundColor Yellow
    }
  }
  $token = New-Token
  $json = "{`r`n  `"authToken`": `"$token`",`r`n  `"port`": $script:Port`r`n}`r`n"
  New-Item -ItemType Directory -Path $PcDir -Force | Out-Null
  [System.IO.File]::WriteAllText($ConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host '  [√] 已生成新的访问令牌（只保存在本机）' -ForegroundColor Green
  return @{ token = $token; port = $script:Port }
}

# ================================================================ 主流程
Clear-Host
Big-Line
Write-Host '       HealthLink 健康数据接收端' -ForegroundColor Cyan
Write-Host '       （让外地的家人把健康数据发过来看）' -ForegroundColor DarkGray
Big-Line
Write-Host ''

# --- 1) Node.js ---
$node = Find-Node
if (-not $node) {
  Write-Host '  [×] 没有找到 Node.js' -ForegroundColor Red
  Write-Host ''
  Write-Host '      这台电脑需要先装一个叫 Node.js 的免费软件（相当于运行环境）：' -ForegroundColor Yellow
  Write-Host '        1. 打开 https://nodejs.org/zh-cn' -ForegroundColor White
  Write-Host '        2. 下载左侧的「LTS」版本，双击安装，一路点「下一步」' -ForegroundColor White
  Write-Host '        3. 装完后重新双击本文件' -ForegroundColor White
  Write-Host ''
  Write-Host '      注意：装的时候如果弹出防火墙询问，请点「允许访问」。' -ForegroundColor DarkGray
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}
Write-Host "  [√] 已找到 Node.js" -ForegroundColor Green

# --- 2) 配置与令牌 ---
$cfg = Ensure-Config
$token = $cfg.token
$Port = $cfg.port

# --- 3) 本机地址 ---
$lan = Get-LanIp
if (-not $lan) {
  Write-Host '  [×] 找不到本机网络地址，请确认已连接 Wi-Fi 或网线。' -ForegroundColor Red
  Read-Host '  按回车退出'
  exit 1
}

$ingestUrl = "ws://${lan}:${Port}/ingest?token=$token"
$panelUrl  = "http://${lan}:${Port}/?token=$token"
$localUrl  = "http://127.0.0.1:${Port}/?token=$token"

Write-Host ''
Big-Line
Write-Host '   请把下面这一行，发给要分享健康数据给你的人' -ForegroundColor Yellow
Big-Line
Write-Host ''
Write-Host "     $ingestUrl" -ForegroundColor Green
Write-Host ''
Big-Line
Write-Host ''
Write-Host '   为什么要把这行发给他：' -ForegroundColor White
Write-Host '     它是你这台电脑的"收货地址"。他那边把这个地址填进去，' -ForegroundColor DarkGray
Write-Host '     健康数据就会自动传过来，你就能在这里看到。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '   他填好之后，你打开下面这个网页就能看到实时数据：' -ForegroundColor White
Write-Host "     $panelUrl" -ForegroundColor Cyan
Write-Host ''
Write-Host '   ⚠ 这个黑色窗口请不要关，关了对方就看不到了。' -ForegroundColor Yellow
Write-Host '     想停止，直接关掉这个窗口即可。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '   如果 Windows 弹出防火墙提示，请点「允许访问」。' -ForegroundColor DarkGray
Write-Host ''

# --- 4) 启动服务 ---
# 端口已写进 config.json，这里不再设 HEALTHLINK_PORT（环境变量优先级更高，会盖掉文件配置）
$arguments = @((Join-Path $PcDir 'src\index.js'))
Write-Host '   正在启动...' -ForegroundColor DarkGray
Write-Host ''

try {
  & $node @arguments
  $code = $LASTEXITCODE
} catch {
  Write-Host ''
  Write-Host "  [×] 启动失败：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}

Write-Host ''
Write-Host '   服务已停止。' -ForegroundColor DarkGray
Write-Host "   你可以在浏览器里打开这个地址继续查看已有数据：$localUrl" -ForegroundColor DarkGray
Write-Host ''
Read-Host '  按回车退出'
exit $code
