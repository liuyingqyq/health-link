#!/usr/bin/env pwsh
<#
.SYNOPSIS
  HealthLink 电脑端启动器（由 启动.cmd 调用，也可以直接运行）。

.DESCRIPTION
  它做的事：
    1. 检查 Node.js
    2. 检查/生成访问令牌（config.json）
    3. 启动服务（前台运行，关掉窗口即停止）
    4. 等端口就绪后打印【手机要填的地址】和【面板地址】
    5. 可选自动打开浏览器面板

.PARAMETER NodePath
  node.exe 的路径；不传则用 PATH 里的 node。

.PARAMETER OpenBrowser
  1 = 启动后自动打开浏览器面板。

.PARAMETER Port
  监听端口，默认 18787（五位数，避免与常见开发工具的端口冲突）。

.EXAMPLE
  pwsh 启动.ps1
  pwsh 启动.ps1 -OpenBrowser 1 -Port 9000
#>
[CmdletBinding()]
param(
  [string]$NodePath = 'node',
  [int]$OpenBrowser = 0,
  # 0 = 不指定，用 config.json 里的 port（没有再退回 18787）
  [int]$Port = 0
)

$ErrorActionPreference = 'Stop'

# 本脚本位于 <项目根>\tools\ 下，所以项目根是它的上一级。
# ⚠️ 别写成 $PSScriptRoot —— 那样会得到 tools\，导致找不到 pc\src\index.js。
#    （这个 bug 真实发生过：把启动逻辑从根目录挪进 tools\ 之后就踩到了。）
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot 'pc\src\index.js'))) {
  # 兼容"脚本被直接放在项目根目录"的情况
  if (Test-Path (Join-Path $PSScriptRoot 'pc\src\index.js')) {
    $ProjectRoot = $PSScriptRoot
  }
}

function Write-Head($text) {
  Write-Host ''
  Write-Host "  $text" -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Warn2($text){ Write-Host "  [注意] $text" -ForegroundColor Yellow }
function Write-Err2($text) { Write-Host "  [错误] $text" -ForegroundColor Red }

# ---------------------------------------------------------------- 1) 检查 Node
Write-Head '1/4 检查 Node.js'
try {
  $nodeVersion = & $NodePath --version 2>&1
  if ($LASTEXITCODE -ne 0) { throw "node 执行失败" }
  $major = [int](($nodeVersion -replace '^v','') -split '\.')[0]
  if ($major -lt 18) {
    Write-Err2 "Node.js 版本过低：$nodeVersion（需要 18 或更高）"
    Write-Host '         请到 https://nodejs.org/ 升级后重试。'
    exit 1
  }
  Write-Ok "Node.js $nodeVersion"
} catch {
  Write-Err2 "找不到可用的 Node.js（$NodePath）"
  Write-Host '         请到 https://nodejs.org/ 安装 18 或更高版本。'
  exit 1
}

$serverEntry = Join-Path $ProjectRoot 'pc\src\index.js'
if (-not (Test-Path $serverEntry)) {
  Write-Err2 "找不到服务端入口：$serverEntry"
  Write-Host '         请确认 启动.cmd 与 pc 目录在同一层。'
  exit 1
}

# ---------------------------------------------------------------- 2) 读/建令牌
Write-Head '2/4 准备配置'
$configFile = Join-Path $ProjectRoot 'pc\config.json'
$isFirstRun = -not (Test-Path $configFile)
Write-Ok ($(if ($isFirstRun) { '首次运行，将自动生成 config.json 与访问令牌' } else { "读取已有配置 $configFile" }))

# 端口优先级：命令行 -Port  >  config.json 的 port  >  默认 18787
$configPort = 18787
if (Test-Path $configFile) {
  try {
    $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.port) { $configPort = [int]$cfg.port }
  } catch {
    Write-Warn2 'config.json 解析失败，将使用默认端口 18787（服务启动时会重建它）'
  }
}
if ($Port -gt 0) { $configPort = $Port }

# ---------------------------------------------------------------- 3) 启动服务
Write-Head '3/4 启动服务'
Write-Host "         监听端口：$configPort" -ForegroundColor DarkGray
Write-Host '         （保持本窗口开着；关闭窗口即停止服务）' -ForegroundColor DarkGray
Write-Host ''

$env:HEALTHLINK_PORT = "$configPort"

# 用重定向而不是 -NoNewWindow：
# 后者会让服务端日志直接混进我们的横幅里，"服务就绪"会印在日志中间，很乱。
# 重定向后我们可以自己控制顺序（先打印连接信息，再持续回显日志）。
$stdoutFile = Join-Path $env:TEMP "healthlink-out-$PID.log"
$stderrFile = Join-Path $env:TEMP "healthlink-err-$PID.log"

# ---- 启动前先探测：服务是不是已经在跑了 ----
#  踩过的坑：用户上一个窗口没关就再次双击启动，第二个实例报 EADDRINUSE 退出，
#  用户看到"服务未能启动 / 端口被占用"以为坏了 —— 其实服务活得好好的，数据照传。
#  所以这里先说清楚，并把面板地址给出来，避免用户白折腾。
$alreadyRunning = $false
try {
  $probe = Invoke-WebRequest "http://127.0.0.1:$configPort/api/health" -UseBasicParsing -TimeoutSec 2
  if ($probe.StatusCode -eq 200) { $alreadyRunning = $true }
} catch { }

if ($alreadyRunning) {
  # 这里不能复用后面的 $token（它在服务启动成功之后才读），直接自己读一次配置
  $probeToken = ''
  if (Test-Path $configFile) {
    try {
      $probeCfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($probeCfg.authToken) { $probeToken = $probeCfg.authToken }
    } catch { }
  }
  $panelUrl = "http://127.0.0.1:$configPort/"
  if ($probeToken) { $panelUrl = "$panelUrl`?token=$probeToken" }

  Write-Host ''
  Write-Host '  ========================================================' -ForegroundColor Yellow
  Write-Host '    服务已经在运行了，不用再启动一次' -ForegroundColor Yellow
  Write-Host '  ========================================================' -ForegroundColor Yellow
  Write-Host ''
  Write-Host "  监听端口：$configPort（已经有一个窗口在跑着它）" -ForegroundColor White
  Write-Host ''
  Write-Host '  你要做的：' -ForegroundColor White
  Write-Host '    · 想用面板 → 直接打开下面这个网址' -ForegroundColor DarkGray
  Write-Host "        $panelUrl" -ForegroundColor Cyan
  Write-Host '    · 想停止服务 → 找到那个已经打开的黑窗口，关掉它' -ForegroundColor DarkGray
  Write-Host '    · 只是想确认没坏 → 服务是正常的，手机数据照常在上传' -ForegroundColor DarkGray
  Write-Host ''
  if ($OpenBrowser -eq 1) { Start-Process $panelUrl }
  Write-Host '  按回车退出（不会影响正在运行的服务）...' -ForegroundColor DarkGray -NoNewline
  [void](Read-Host)
  exit 0
}

$proc = Start-Process -FilePath $NodePath `
  -ArgumentList @($serverEntry) `
  -WorkingDirectory (Join-Path $ProjectRoot 'pc') `
  -RedirectStandardOutput $stdoutFile `
  -RedirectStandardError $stderrFile `
  -WindowStyle Hidden `
  -PassThru

# 等端口就绪（最多 20 秒）
$ready = $false
$health = $null
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  if ($proc.HasExited) { break }
  try {
    $resp = Invoke-WebRequest "http://127.0.0.1:$configPort/api/health" -UseBasicParsing -TimeoutSec 2
    if ($resp.StatusCode -eq 200) {
      $health = $resp.Content | ConvertFrom-Json
      $ready = $true
      break
    }
  } catch { }
}

if (-not $ready) {
  Write-Host ''
  Write-Err2 '服务未能在 20 秒内启动。'
  if (Test-Path $stderrFile) {
    $errText = Get-Content $stderrFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($errText) { Write-Host "         $($errText.Trim())" -ForegroundColor Yellow }
  }
  if ($proc.HasExited) {
    Write-Host "         进程已退出（退出码 $($proc.ExitCode)）。" -ForegroundColor Yellow
    Write-Host '         常见原因：端口被占用。把 pc\config.json 里的 port 改成别的值再试。' -ForegroundColor Yellow
  }
  if (-not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force } catch { } }
  Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  exit 1
}

Write-Ok "服务已就绪（协议版本 v$($health.data.protocol)）"

# ---------------------------------------------------------------- 4) 打印连接信息
Write-Head '4/4 连接信息'

# 令牌：服务端启动时若自动生成会写进 config.json，这里读出来给用户看
$token = $null
if (Test-Path $configFile) {
  try {
    $cfg2 = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = $cfg2.authToken
  } catch { }
}

# 本机地址，按"手机能不能连上"的可能性排序。
# 踩过的坑：直接枚举所有地址会列出 198.18.x.x（网络测试保留段）和
# 169.254.x.x（链路本地，没拿到 DHCP 时的地址），用户照抄会连不上。
$lanIps = @()   # 真实局域网 IPv4，优先展示
$v6Ips  = @()   # 公网 IPv6 —— 跨网络直连靠它，必须显示出来
$otherIps = @() # 其他地址，仅作备选
foreach ($infos in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
  if ($infos.OperationalStatus -ne 'Up') { continue }
  if ($infos.NetworkInterfaceType -eq 'Loopback') { continue }
  foreach ($addr in $infos.GetIPProperties().UnicastAddresses) {
    $fam = $addr.Address.AddressFamily

    # ---- IPv6：只保留公网可达的（fe80 链路本地 / fc00-fdff 唯一本地 都跳过）----
    if ($fam -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
      $v6 = $addr.Address.ToString().Split('%')[0]
      if ($v6 -match '^(fe80|::1)') { continue }
      if ($v6 -match '^f[cd]') { continue }
      # 公网 IPv6 一般是 2000::/3，首位 2 或 3
      if ($v6 -match '^[23]') { $v6Ips += $v6 }
      continue
    }

    if ($fam -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
    $ip = $addr.Address.ToString()
    if ($ip -match '^169\.254\.') { continue }                        # 链路本地，跳过
    if ($ip -match '^(192\.168\.|10\.)') { $lanIps += $ip; continue }  # 典型家庭/办公局域网
    if ($ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { $lanIps += $ip; continue }
    if ($ip -match '^(127\.|198\.18\.|198\.19\.)') { continue }        # 回环 / 测试保留段
    $otherIps += $ip
  }
}
$lanIps = $lanIps | Select-Object -Unique
$v6Ips = $v6Ips | Select-Object -Unique
$otherIps = $otherIps | Select-Object -Unique
if (-not $lanIps -and -not $otherIps) { $otherIps = @('127.0.0.1') }

Write-Host ''
Write-Host '  ┌─────────────────────────────────────────────────────────────┐' -ForegroundColor White
Write-Host '  │  手机 App 里「电脑地址」填这一行（整行照抄）：              │' -ForegroundColor White
Write-Host '  └─────────────────────────────────────────────────────────────┘' -ForegroundColor White
foreach ($ip in $lanIps) {
  Write-Host "      ws://${ip}:$configPort/ingest?token=$token" -ForegroundColor Green
}
if ($otherIps.Count -gt 0) {
  Write-Host ''
  Write-Host '      若上面都不通，可再试这几条（可能是虚拟网卡）：' -ForegroundColor DarkGray
  foreach ($ip in $otherIps) {
    Write-Host "      ws://${ip}:$configPort/ingest?token=$token" -ForegroundColor DarkGray
  }
}
if (-not $lanIps) {
  Write-Warn2 '没找到典型的局域网地址（192.168.x.x / 10.x.x.x）。请确认电脑已连上 WiFi 或网线。'
}

# ---- IPv6：手机在外地（用流量）时用这个 ----
if ($v6Ips.Count -gt 0) {
  Write-Host ''
  Write-Host '  ┌─────────────────────────────────────────────────────────────┐' -ForegroundColor Magenta
  Write-Host '  │  手机在外地（用流量）也能传数据 → 用这条 IPv6 地址：       │' -ForegroundColor Magenta
  Write-Host '  └─────────────────────────────────────────────────────────────┘' -ForegroundColor Magenta
  foreach ($ip in $v6Ips) {
    Write-Host "      ws://[${ip}]:$configPort/ingest?token=$token" -ForegroundColor Magenta
  }
  Write-Host '      （方括号是 URL 规范要求，别删）' -ForegroundColor DarkGray
  Write-Host '      IPv6 没有 NAT，跨网络可直达，不需要蒲公英/Tailscale。' -ForegroundColor DarkGray
  Write-Host '      缺点：地址可能随路由器重新拨号而变，长期用建议配动态域名。' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  ┌─────────────────────────────────────────────────────────────┐' -ForegroundColor White
Write-Host '  │  本机浏览器打开面板（看实时数据）：                         │' -ForegroundColor White
Write-Host '  └─────────────────────────────────────────────────────────────┘' -ForegroundColor White
$panelUrl = "http://127.0.0.1:$configPort/?token=$token"
Write-Host "      $panelUrl" -ForegroundColor Green
Write-Host ''
Write-Host "  访问令牌：$token" -ForegroundColor DarkGray
Write-Host '  提示：手机和电脑要在同一个 WiFi 下。' -ForegroundColor Yellow
Write-Host '        第一次连不上，多半是 Windows 防火墙拦了，见 docs\部署与验证.md 第 4 节。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host '   按 Ctrl+C 或直接关闭本窗口即可停止服务' -ForegroundColor DarkGray
Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

if ($OpenBrowser -eq 1) {
  try {
    Start-Process $panelUrl
    Write-Ok '已打开浏览器面板'
  } catch {
    Write-Warn2 '自动打开浏览器失败，请手动复制上面的面板地址'
  }
}

Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host '   下面是服务端实时日志：' -ForegroundColor DarkGray
Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- 回显日志直到进程结束
# 只读新增的字节（记录上次读到的位置），避免整份日志被反复重印。
$logPos = @{}
function Read-NewText([string]$File, [string]$Key) {
  if (-not (Test-Path $File)) { return '' }
  if (-not $logPos.ContainsKey($Key)) { $logPos[$Key] = 0L }
  $fs = $null
  try {
    # FileShare.ReadWrite：服务端正在写这个文件，必须允许共享
    $fs = [System.IO.File]::Open($File, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($logPos[$Key] -gt $fs.Length) { $logPos[$Key] = 0L }
    $fs.Seek($logPos[$Key], [System.IO.SeekOrigin]::Begin) | Out-Null
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $logPos[$Key] = $fs.Position
    $reader.Dispose()
    return $text
  } catch {
    return ''   # 偶发共享冲突，跳过这一轮
  } finally {
    if ($fs) { $fs.Dispose() }
  }
}

try {
  while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 400
    foreach ($pair in @(@($stdoutFile, 'out'), @($stderrFile, 'err'))) {
      $chunk = Read-NewText $pair[0] $pair[1]
      if (-not $chunk) { continue }
      foreach ($line in ($chunk -split "`r?`n")) {
        if ($line.Trim()) { Write-Host "  $line" }
      }
    }
  }
} finally {
  try { Wait-Process -Id $proc.Id -Timeout 5 -ErrorAction SilentlyContinue } catch { }
  if (-not $proc.HasExited) {
    try { Stop-Process -Id $proc.Id -Force } catch { }
  }
  Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Ok 'HealthLink 已停止'
exit 0
