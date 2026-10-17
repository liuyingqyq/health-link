# ============================================================================
#  HealthLink 分享链接生成器
#
#  为什么需要它：
#    电脑上通常有好几张网卡（Wi-Fi、有线、虚拟机、蒲公英/Tailscale 虚拟网卡…），
#    每张网卡都有不同 IP。发给别人时到底该发哪个 IP，用户根本判断不了。
#    这个工具把每张网卡都列出来，并直接告诉你「这个给谁用」。
#
#  用法：双击 分享链接.cmd
# ============================================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path   # 本脚本在 tools\ 下，上跳一级到项目根
$ConfigFile = Join-Path $Root 'pc\config.json'

function Big-Line { Write-Host ('  ' + ('=' * 64)) -ForegroundColor DarkCyan }
function Section { param([string]$T)
  Write-Host ''
  Write-Host "  ── $T " -ForegroundColor Cyan -NoNewline
  Write-Host ('─' * [Math]::Max(0, 56 - $T.Length)) -ForegroundColor DarkGray
}

Big-Line
Write-Host '       HealthLink 分享链接生成器' -ForegroundColor Cyan
Write-Host '       自动列出所有网卡，并告诉你该发哪一条' -ForegroundColor DarkGray
Big-Line

# ---------------------------------------------------------------- 读配置
if (-not (Test-Path $ConfigFile)) {
  Write-Host ''
  Write-Host '  [×] 还没生成配置。' -ForegroundColor Red
  Write-Host '      请先双击「启动.cmd」启动一次服务，再回来运行本工具。' -ForegroundColor Yellow
  Write-Host ''
  Read-Host '  按回车退出'
  exit 1
}

try {
  $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Write-Host ''
  Write-Host "  [×] 配置文件读不出来：$($_.Exception.Message)" -ForegroundColor Red
  Read-Host '  按回车退出'
  exit 1
}

$token = $cfg.authToken
$port = 18787
if ($cfg.port) { $port = [int]$cfg.port }

if (-not $token) {
  Write-Host ''
  Write-Host '  [×] 配置里没有访问令牌，请先双击「启动.cmd」。' -ForegroundColor Red
  Read-Host '  按回车退出'
  exit 1
}

# ---------------------------------------------------------------- 服务状态
$serviceUp = $false
try {
  $probe = Invoke-WebRequest "http://127.0.0.1:$port/api/health" -UseBasicParsing -TimeoutSec 3
  if ($probe.StatusCode -eq 200) { $serviceUp = $true }
} catch { }

Section '服务状态'
if ($serviceUp) {
  Write-Host '  [√] 电脑端服务正在运行' -ForegroundColor Green
} else {
  Write-Host '  [!] 电脑端服务好像没在运行' -ForegroundColor Yellow
  Write-Host '      分享链接需要服务持续开着才有效，请先双击「启动.cmd」。' -ForegroundColor DarkGray
}
Write-Host "      端口：$port"

# ---------------------------------------------------------------- 枚举网卡
#  用 .NET API 而不是 ipconfig：能拿到网卡名称与类型，
#  这样才能把「Wi-Fi」和「虚拟机网卡」区分开，告诉用户该用哪个。
$ifaces = @()
foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
  if ($ni.OperationalStatus -ne 'Up') { continue }
  if ($ni.NetworkInterfaceType -eq 'Loopback') { continue }

  foreach ($addr in $ni.GetIPProperties().UnicastAddresses) {
    if ($addr.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
    $ip = $addr.Address.ToString()

    # 169.254.x.x：没拿到 DHCP 时的自分配地址，连不通
    # 198.18.x.x：网络基准测试保留段，连不通
    $isSelfAssigned = $ip -match '^169\.254\.'
    $isBenchmark = $ip -match '^198\.18\.'

    $kind = 'other'
    $who = '（一般用不到）'
    $color = 'DarkGray'

    if ($isSelfAssigned) {
      $kind = 'selfassigned'; $who = '无效地址（没拿到路由器分配的 IP），不要发'
      $color = 'DarkRed'
    } elseif ($isBenchmark) {
      $kind = 'benchmark'; $who = '无效地址（系统测试保留段），不要发'
      $color = 'DarkRed'
    } elseif ($ip -match '^192\.168\.' -or $ip -match '^10\.' -or $ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or $ip -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') {
      # 私有网段。其中 100.64-127 是 CGNAT（Tailscale 用这个段），单独识别
      if ($ni.Name -match 'VMware|VirtualBox|Hyper-V|vEthernet|VMnet|虚拟') {
        $kind = 'vm'; $who = '虚拟机网卡，不要发'
        $color = 'DarkRed'
      } elseif ($ip -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') {
        $kind = 'cgnat'; $who = '组网工具地址（外地的人装了同一组网工具才能用）'
        $color = 'Magenta'
      } elseif ($ni.Name -match 'Tailscale|ZeroTier|蒲公英|Oray|Pgy|Radmin|Hamachi|n2n') {
        $kind = 'mesh'; $who = '组网工具地址（外地的人装了同一组网工具才能用）'
        $color = 'Magenta'
      } elseif ($ni.NetworkInterfaceType -eq 'Wireless80211') {
        $kind = 'wlan'; $who = '同一个 Wi-Fi 下的人用这条'
        $color = 'Green'
      } elseif ($ni.NetworkInterfaceType -eq 'Ethernet') {
        $kind = 'eth'; $who = '同一个路由器/网线网络下的人用这条'
        $color = 'Green'
      } else {
        $kind = 'lan'; $who = '同一个局域网下的人用这条'
        $color = 'Green'
      }
    }

    $ifaces += [pscustomobject]@{
      Ip = $ip; Name = $ni.Name; Type = $ni.NetworkInterfaceType
      Kind = $kind; Who = $who; Color = $color
    }
  }
}

# 排序：绿标（同网段）优先，其次组网地址，最后无效地址
$order = @{ wlan = 0; eth = 1; lan = 2; mesh = 3; cgnat = 4; other = 5; vm = 6; selfassigned = 7; benchmark = 8 }
$ifaces = $ifaces | Sort-Object { $order[$_.Kind] }

# ---------------------------------------------------------------- 输出
Section '可用的分享链接'

if ($ifaces.Count -eq 0) {
  Write-Host '  [×] 没找到任何可用的网络地址。' -ForegroundColor Red
  Write-Host '      请确认已连接 Wi-Fi 或网线。' -ForegroundColor DarkGray
} else {
  $idx = 0
  foreach ($f in $ifaces) {
    $idx++
    $shareUrl = "http://$($f.Ip):$port/share.html?token=$token"
    Write-Host ''
    Write-Host "  【$idx】$($f.Who)" -ForegroundColor $f.Color
    Write-Host "       网卡：$($f.Name)    IP：$($f.Ip)" -ForegroundColor DarkGray
    Write-Host "       $shareUrl" -ForegroundColor $f.Color
  }
}

# ---------------------------------------------------------------- 用法说明
Section '怎么用（挑一条发给对方）'

Write-Host '  对方和你在同一个 Wi-Fi：' -ForegroundColor Green
Write-Host '    用标记为「同一个 Wi-Fi 下的人用这条」的那条。对方浏览器打开即可，'
Write-Host '    什么都不用装。他自己也能在手机上打开。'
Write-Host ''
Write-Host '  对方在外地（不同城市/不同宽带）：' -ForegroundColor Magenta
Write-Host '    1. 你和对方都装一个组网工具（蒲公英 / Tailscale / ZeroTier），'
Write-Host '       登录同一账号，让两台电脑"像在同一个局域网"'
Write-Host '    2. 装好后重新运行本工具，把标记为「组网工具地址」的那条发给对方'
Write-Host ''
Write-Host '  红标的地址不要发（虚拟机网卡 / 无效地址，别人连不上）。' -ForegroundColor DarkRed

# ---------------------------------------------------------------- 自检
Section '发出前的自检'

# ⚠️ 用 @() 包住：PowerShell 5.1 里 Where-Object 只匹配到一条时返回的是
#    单个对象而不是数组，那个对象没有 .Count，`$x.Count -gt 0` 会静默为假，
#    整个自检段就被跳过了（踩过）。
$testable = @($ifaces | Where-Object { $_.Kind -in @('wlan', 'eth', 'lan', 'mesh', 'cgnat', 'other') })
if ($testable.Count -gt 0) {
  Write-Host '  正在逐条测试（本机自测只能证明服务在监听，不能证明对方可达）：' -ForegroundColor DarkGray
  foreach ($f in $testable) {
    $ok = $false
    try {
      # 带 token：分享页对无令牌请求会直接拒绝，不带就会误报"访问不了"
      $r = Invoke-WebRequest "http://$($f.Ip):$port/share.html?token=$token" -UseBasicParsing -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $ok = $true }
    } catch { }
    $mark = if ($ok) { '[√]' } else { '[×]' }
    $c = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("    {0} {1,-16} {2}" -f $mark, $f.Ip, $(if ($ok) { '本机能访问' } else { '本机都访问不了，请检查服务' })) -ForegroundColor $c
  }
}

Write-Host ''
Write-Host '  ── 手机 App 里要填的地址（和上面不同的一个用途）──' -ForegroundColor DarkCyan
Write-Host '  如果手机连的是同一个 Wi-Fi，手机 App 的「电脑地址」填：'
$phoneIp = ($ifaces | Where-Object { $_.Kind -in @('wlan', 'eth', 'lan') } | Select-Object -First 1).Ip
if ($phoneIp) {
  Write-Host "      ws://${phoneIp}:${port}/ingest?token=$token" -ForegroundColor Green
} else {
  Write-Host '      （没找到局域网地址，先连上 Wi-Fi）' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- IPv6 直连
#  ⚠️ IPv6 地址在 URL 里必须用方括号包起来：http://[2409:...]:port/path
#     不包的话浏览器无法解析（冒号会被当成端口分隔符）。
Section '给外地的家人（IPv6 直连，不需要装任何东西）'

$v6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
  Where-Object {
    $_.IPAddress -notmatch '^(fe80|::1|fd|fc)' -and
    ($_.IPAddress -match '^2409:' -or $_.IPAddress -match '^2[0-9a-f]{3}:' -or $_.IPAddress -match '^3[0-9a-f]{3}:')
  } | Select-Object -First 1

if ($v6) {
  $v6ip = $v6.IPAddress
  Write-Host "  检测到公网 IPv6：$v6ip" -ForegroundColor Magenta
  Write-Host "  （网卡：$($v6.InterfaceAlias)）" -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '  把下面这条发给外地的人（他自己也要有 IPv6 才行）：' -ForegroundColor Magenta
  Write-Host "      http://[$v6ip]:$port/share.html?token=$token" -ForegroundColor Magenta
  Write-Host ''
  Write-Host '  为什么这条能跨网络：' -ForegroundColor White
  Write-Host '    IPv4 走的是运营商大内网（NAT），外网到不了你家。' -ForegroundColor DarkGray
  Write-Host '    但 IPv6 没有 NAT，这个地址全球可直达，不需要端口映射、' -ForegroundColor DarkGray
  Write-Host '    也不需要蒲公英之类的组网工具。' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '  ⚠️ 两个前提：' -ForegroundColor Yellow
  Write-Host '    1. 对方那边也要有 IPv6（用手机流量/新宽带基本都有）' -ForegroundColor DarkGray
  Write-Host '       让对方用浏览器打开 https://test-ipv6.com 确认' -ForegroundColor DarkGray
  Write-Host '    2. 你的 Windows 防火墙要放行 18787（Domain/Private/Public 都放行）' -ForegroundColor DarkGray
} else {
  Write-Host '  没检测到公网 IPv6。' -ForegroundColor Yellow
  Write-Host '  如果你的路由器 WAN 口有 IPv6 地址，但这里看不到，' -ForegroundColor DarkGray
  Write-Host '  可能是电脑没拿到 IPv6 —— 在网卡属性里启用 IPv6 后重试。' -ForegroundColor DarkGray
  Write-Host '  没有 IPv6 就只能走组网工具（蒲公英 / Tailscale）。' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 打开面板
Section '在你自己的电脑上验证'
Write-Host "  本机面板：http://127.0.0.1:$port/?token=$token" -ForegroundColor Cyan
Write-Host "  只读分享页：http://127.0.0.1:$port/share.html?token=$token" -ForegroundColor Cyan
Write-Host ''
$open = Read-Host '  现在打开本机只读分享页看一眼？(y=打开 / 直接回车退出)'
if ($open -eq 'y' -or $open -eq 'Y') {
  Start-Process "http://127.0.0.1:$port/share.html?token=$token"
}

Write-Host ''
Big-Line
Write-Host '  安全提示：链接里的 token 就是钥匙，拿到的人能看你的健康数据。' -ForegroundColor Yellow
Write-Host '           只发给你信任的人。想作废：改 pc\config.json 里的 authToken 后重启服务。' -ForegroundColor Yellow
Big-Line
Write-Host ''
Read-Host '  按回车退出'
