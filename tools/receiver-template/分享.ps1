# ============================================================================
#  HealthLink 接收端 · 生成分享链接
#
#  给接收方用：如果你想把数据再分享给第三个人（比如同一个家的其他人），
#  双击 分享.cmd 即可拿到一条只读链接。
# ============================================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = $PSScriptRoot
$ConfigFile = Join-Path $Root 'pc\config.json'

function Big-Line { Write-Host ('  ' + ('=' * 60)) -ForegroundColor Cyan }

Big-Line
Write-Host '       HealthLink 只读分享链接' -ForegroundColor Cyan
Big-Line
Write-Host ''

if (-not (Test-Path $ConfigFile)) {
  Write-Host '  [×] 还没生成配置。' -ForegroundColor Red
  Write-Host '      请先双击「启动.cmd」启动一次服务，再回来生成分享链接。' -ForegroundColor Yellow
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}

$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$token = $cfg.authToken
$port = 18787
if ($cfg.port) { $port = [int]$cfg.port }

if (-not $token) {
  Write-Host '  [×] 配置里没有访问令牌，请先双击「启动.cmd」。' -ForegroundColor Red
  Read-Host '  按回车退出'
  exit 1
}

# 找局域网 IP
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

if (-not $lan) {
  Write-Host '  [×] 找不到本机网络地址，请确认已连接 Wi-Fi 或网线。' -ForegroundColor Red
  Read-Host '  按回车退出'
  exit 1
}

$shareUrl = "http://${lan}:${port}/share.html?token=$token"
$selfUrl  = "http://127.0.0.1:${port}/share.html?token=$token"
$panelUrl = "http://${lan}:${port}/?token=$token"

Write-Host '  ──────── 把下面这条链接发给对方 ────────' -ForegroundColor Yellow
Write-Host ''
Write-Host "  $shareUrl" -ForegroundColor Green
Write-Host ''
Write-Host '  ────────────────────────────────────────' -ForegroundColor Yellow
Write-Host ''
Write-Host '  对方怎么用：在手机或电脑的浏览器里打开这条链接即可，'
Write-Host '  不用装任何软件。页面是只读的，只能看你分享的数据。'
Write-Host ''
Write-Host '  你自己先在电脑上试一下（确认能打开再发出去）：' -ForegroundColor DarkGray
Write-Host "    $selfUrl" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  完整面板（功能更多）：' -ForegroundColor DarkGray
Write-Host "    $panelUrl" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  发出去之前请确认：' -ForegroundColor Cyan
Write-Host '    1. 服务正在运行（那个黑色窗口开着）'
Write-Host "    2. 防火墙已放行 $port 端口"
Write-Host '    3. 对方和你在同一个局域网（同一 Wi-Fi）'
Write-Host ''
Write-Host '  ⚠ 对方在外地怎么办：' -ForegroundColor Yellow
Write-Host '     这条链接只用局域网，外地打不开。'
Write-Host '     请让分享数据给你的人用「组网工具」（蒲公英 / Tailscale）打通。'
Write-Host ''
Write-Host '  ⚠ 安全提示：' -ForegroundColor Yellow
Write-Host '     链接里的 token 就是钥匙，拿到它的人能看这些健康数据。'
Write-Host '     只发给你信任的人。'
Write-Host ''

Read-Host '  按回车退出'
