# 生成「只读分享链接」——把这条链接发给想看的人即可
#
# 用法：双击 分享.cmd，或在本目录执行 .\分享.ps1
#
# 说明：分享页本身是 pc/web/share.html，由电脑端服务提供，无需额外部署。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = $PSScriptRoot
$ConfigFile = Join-Path $Root 'pc\config.json'

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "       HealthLink 只读分享链接" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""

# ---- 读令牌 ----
if (-not (Test-Path $ConfigFile)) {
    Write-Host "  [X] 还没生成配置。" -ForegroundColor Red
    Write-Host "      请先双击 启动.cmd 启动一次服务，再回来生成分享链接。" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  按回车退出"
    exit 1
}
try {
    $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "  [X] 配置文件解析失败：$($_.Exception.Message)" -ForegroundColor Red
    Read-Host "  按回车退出"
    exit 1
}

$token = $cfg.authToken
$port = if ($cfg.port) { [int]$cfg.port } else { 18787 }

if (-not $token) {
    Write-Host "  [X] 配置里没有 authToken，请先启动一次服务。" -ForegroundColor Red
    Read-Host "  按回车退出"
    exit 1
}

# ---- 找局域网 IP ----
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
    Write-Host "  [X] 找不到局域网 IP。请确认已连接 Wi-Fi 或网线。" -ForegroundColor Red
    Read-Host "  按回车退出"
    exit 1
}

$shareUrl = "http://${lan}:${port}/share.html?token=$token"
$selfUrl  = "http://127.0.0.1:${port}/share.html?token=$token"
$panelUrl = "http://${lan}:${port}/?token=$token"

Write-Host "  ──────── 把下面这条链接发给对方 ────────" -ForegroundColor Yellow
Write-Host ""
Write-Host "  $shareUrl" -ForegroundColor Green
Write-Host ""
Write-Host "  ────────────────────────────────────────" -ForegroundColor Yellow
Write-Host ""
Write-Host "  对方怎么用：在手机或电脑的浏览器里打开这条链接即可，"
Write-Host "  不用装任何软件。页面是只读的，只能看你分享的心率等数据。"
Write-Host ""
Write-Host "  你自己先在电脑上试一下（确认能打开再发出去）：" -ForegroundColor DarkGray
Write-Host "    $selfUrl" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  完整面板（带更多功能，也给别人看）：" -ForegroundColor DarkGray
Write-Host "    $panelUrl" -ForegroundColor DarkGray
Write-Host ""

# ---- 前置条件提醒 ----
Write-Host "  发出去之前请确认这 4 件事：" -ForegroundColor Cyan
Write-Host "    1. 电脑端服务正在运行（那个黑窗口开着）"
Write-Host "    2. Windows 防火墙已放行 $port 端口（弹窗时点了「允许访问」）"
Write-Host "    3. 手机 App 正在采集，数据在往电脑传"
Write-Host "    4. 对方和你的电脑在同一个局域网（同一 Wi-Fi / 同一路由器）"
Write-Host ""
Write-Host "  ⚠ 对方在外地怎么办：" -ForegroundColor Yellow
Write-Host "     这条链接只用局域网，外地打不开。"
Write-Host "     请用蒲公英 / Tailscale 之类的组网工具，让两头像在同一局域网，"
Write-Host "     然后把链接里的 IP 换成组网 IP。"
Write-Host "     或者双击 管理.cmd 用「添加分享目标」把数据主动转发到对方电脑。"
Write-Host ""
Write-Host "  ⚠ 安全提示：" -ForegroundColor Yellow
Write-Host "     这条链接里的 token 就是钥匙，拿到它的人能看你的健康数据。"
Write-Host "     只发给你信任的人；想作废就让服务重启一次（会重新生成令牌），"
Write-Host "     或改 pc\config.json 里的 authToken。"
Write-Host ""

Read-Host "  按回车退出"
