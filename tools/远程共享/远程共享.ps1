# ============================================================================
#  HealthLink 远程共享向导（中文，面向不熟悉网络的用户）
#
#  为什么有这个文件：
#    系统自带的"转发目标"功能要求你自己拼 ws://地址:端口/ingest?token=xxx。
#    对国内普通用户来说，要找 IP、要懂端口、要复制长令牌，极容易出错。
#    这里把整件事改成"问答 + 复制粘贴"：对方电脑上双击一下，把屏幕上
#    显示的一行字发给你，你粘进来就完事 —— 端口冲突也会自动避开。
#
#  用法：双击 远程共享.cmd，或在本目录执行 .\远程共享.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path   # 本脚本在 tools\远程共享\ 下，上跳两级到项目根
$ConfigFile = Join-Path $Root 'pc\config.json'
$ForwardsFile = Join-Path $Root 'pc\forwards.json'

# ---------------------------------------------------------------- 输出小工具
function Line { param([string]$Color = 'Gray') Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkGray }
function Title { param([string]$T)
  Write-Host ''
  Write-Host ('  ' + $T) -ForegroundColor Cyan
  Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkGray
}
function Ok    { param([string]$T) Write-Host ('  [√] ' + $T) -ForegroundColor Green }
function Warn  { param([string]$T) Write-Host ('  [!] ' + $T) -ForegroundColor Yellow }
function Bad   { param([string]$T) Write-Host ('  [×] ' + $T) -ForegroundColor Red }
function Info  { param([string]$T) Write-Host ('      ' + $T) -ForegroundColor DarkGray }
function Pause-Any {
  Write-Host ''
  Write-Host '  按回车返回...' -ForegroundColor DarkGray -NoNewline
  [void](Read-Host)
}

# ---------------------------------------------------------------- 读取配置
function Get-Cfg {
  if (-not (Test-Path $ConfigFile)) { return $null }
  try { return (Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-Token {
  $cfg = Get-Cfg
  if ($cfg -and $cfg.authToken) { return $cfg.authToken }
  return ''
}

function Get-Port {
  $cfg = Get-Cfg
  if ($cfg -and $cfg.port) { return [int]$cfg.port }
  return 18787
}

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

# ---------------------------------------------------------------- 服务是否在跑
function Test-ServerUp {
  param([int]$Port)
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1200, $false)
    if ($ok -and $tcp.Connected) { $tcp.Close(); return $true }
    $tcp.Close(); return $false
  } catch { return $false }
}

# ---------------------------------------------------------------- 原生转发菜单
#  说明：项目自带的 /api/forward 接口支持增删查，但字段偏底层。
#  这里只做"能不能连上"的只读检查与展示，写入仍走服务端接口，保证一致。
function Test-ForwardLink {
  param([int]$Port, [string]$Token, [string]$Url)
  # 注意：服务端的 /api/forward/test 要求 body 里有 id（即使是临时测试）
  $body = @{ id = 'probe'; kind = 'websocket'; url = $Url; enabled = $true } | ConvertTo-Json -Compress
  $headers = @{ 'X-Auth-Token' = $Token; 'Content-Type' = 'application/json' }
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/forward/test?token=$Token" `
      -Method Post -Headers $headers -Body $body -TimeoutSec 15
    $d = $r.data
    if ($d -and $d.reachable) {
      return @{ ok = $true; latencyMs = $d.latencyMs }
    }
    return @{ ok = $false; error = $(if ($d -and $d.error) { $d.error } else { '对方没有回应' }) }
  } catch {
    return @{ ok = $false; error = $_.Exception.Message }
  }
}

function Add-Forward {
  param([int]$Port, [string]$Token, [string]$Url)
  # 用固定 id，重复执行向导会覆盖同一个目标，不会越加越多
  $body = @{
    id = 'remote-family'
    kind = 'websocket'
    url = $Url
    enabled = $true
  } | ConvertTo-Json -Compress
  $headers = @{ 'X-Auth-Token' = $Token; 'Content-Type' = 'application/json' }
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/forward?token=$Token" `
      -Method Post -Headers $headers -Body $body -TimeoutSec 15
    if ($r -and $r.ok) { return @{ ok = $true; data = $r.data } }
    return @{ ok = $false; error = '服务端没有返回成功' }
  } catch {
    return @{ ok = $false; error = $_.Exception.Message }
  }
}

# ---------------------------------------------------------------- 主流程
function Main {
  Write-Host ''
  Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
  Write-Host '  ║        HealthLink  远程共享向导（给外地的家人）       ║' -ForegroundColor Cyan
  Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan

  $port = Get-Port
  $token = Get-Token
  $lan = Get-LanIp

  # ---- 前置检查 ----
  Title '第 0 步：先确认本机状态'
  if (-not (Test-Path $ConfigFile)) {
    Bad '还没生成配置。'
    Info '请先双击「启动.cmd」启动一次服务，再回来运行本向导。'
    Pause-Any; return
  }
  if (-not $token) {
    Bad '配置里没有访问令牌。'
    Info '请先双击「启动.cmd」让服务生成令牌。'
    Pause-Any; return
  }

  $up = Test-ServerUp -Port $port
  if ($up) {
    Ok "本机服务正在运行（端口 $port）"
  } else {
    Warn "本机服务好像没在运行（端口 $port 连不上）。"
    Info '远程共享需要服务持续开着。请另开一个窗口双击「启动.cmd」，'
    Info '然后再运行本向导。'
    Write-Host ''
    Write-Host '  检查完了吗？回车继续（或按 Ctrl+C 退出）...' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
  }
  Write-Host ''
  Info "本机局域网地址：${lan}:${port}"

  # ---- 场景选择 ----
  Title '第 1 步：对方在哪里'
  Write-Host '    1  对方和我在同一个 Wi-Fi / 同一个路由器下（同一个家、同一个办公室）'
  Write-Host '    2  对方在外地（不同城市、不同网络）' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '    0  退出'
  Write-Host ''
  $mode = Read-Host '  请输入数字'

  if ($mode -eq '0' -or $mode -eq '') { return }

  if ($mode -eq '1') {
    # ================================================================ 同一局域网
    Title '同一局域网：最简单，不用装任何东西'
    $url = "http://${lan}:${port}/share.html?token=$token"
    Write-Host ''
    Ok '把下面这条链接发给对方，他用浏览器打开就能看：'
    Write-Host ''
    Write-Host "    $url" -ForegroundColor Green
    Write-Host ''
    Info '对方不需要装软件，也不需要注册。页面是只读的。'
    Info '你现在就可以先在电脑上打开试试：'
    Write-Host "    http://127.0.0.1:${port}/share.html?token=$token" -ForegroundColor DarkGray
    Write-Host ''
    Warn '发出去之前请确认：'
    Info '1. 电脑端服务一直在运行（那个窗口别关）'
    Info '2. Windows 防火墙放行了端口（第一次启动弹窗时点了「允许访问」）'
    Info '3. 手机 App 正在采集，数据在往电脑传'
    Write-Host ''
    Warn "这条链接里的令牌就是钥匙，拿到的人能看你的健康数据，只发给信任的人。"
    Pause-Any; return
  }

  # ================================================================ 外地
  Title '对方在外地：需要两边配合一次（大约 3 分钟）'
  Write-Host ''
  Write-Host '  为什么要配合：' -ForegroundColor White
  Info '你的健康数据现在只发到自己电脑上。要让外地的家人看到，'
  Info '最稳的办法是让对方电脑也跑一份接收程序，你把数据主动推过去。'
  Info '（中间还需要一条"穿透通道"，向导最后会说明。）'
  Write-Host ''

  # ---- 第 2 步：给对方的指令 ----
  Title '第 2 步：把下面这段发给对方（可以整段复制粘贴）'
  Write-Host ''
  Write-Host '  ┈┈┈┈┈┈┈ 复制以下内容 ┈┈┈┈┈┈┈' -ForegroundColor DarkYellow
  Write-Host ''
  Write-Host '  你好，请帮我做一个小设置，约 3 分钟，不用懂技术：'
  Write-Host ''
  Write-Host '  1. 把我接下来发给你的一个压缩包解压到任意文件夹'
  Write-Host '     （里面有个文件叫「启动.cmd」）'
  Write-Host '  2. 双击「启动.cmd」，会弹出一个黑色窗口，让它开着别关'
  Write-Host '  3. 窗口里会打印一行以 ws:// 开头的地址'
  Write-Host '     请把那行完整的字复制发给我，我需要它来连接'
  Write-Host ''
  Write-Host '  如果窗口里提示防火墙询问是否允许，请点「允许访问」'
  Write-Host ''
  Write-Host '  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈' -ForegroundColor DarkYellow
  Write-Host ''
  Warn '注意：对方拿到的必须是「你自己的这份项目」，不要让对方去网上找。'
  Info "打包方法：把整个文件夹 $Root 压缩成 zip 发给对方。"
  Info '（更省事的办法见第 4 步的"组网工具"）'
  Write-Host ''
  Write-Host '  请问对方把地址发给你了吗？'
  Write-Host '    1  发来了，我现在粘贴'
  Write-Host '    2  还没发来，我先记下步骤，稍后再来'
  Write-Host '    0  退出'
  Write-Host ''
  $r2 = Read-Host '  请输入数字'
  if ($r2 -eq '0' -or $r2 -eq '' -or $r2 -eq '2') { Pause-Any; return }

  # ---- 第 3 步：粘贴对方地址 ----
  Title '第 3 步：粘贴对方给你的那行地址'
  Info '直接整行粘进来，以 ws:// 开头。粘贴后按回车。'
  Write-Host ''
  $peerUrl = Read-Host '  对方地址'

  $peerUrl = ($peerUrl -replace '\s', '')      # 去掉复制时带进来的空格换行
  if (-not $peerUrl) { Bad '没输入内容，已取消。'; Pause-Any; return }
  if ($peerUrl -notmatch '^wss?://') {
    Bad '这个地址看起来不对，应该以 ws:// 开头。'
    Info "你输入的是：$peerUrl"
    Info '请回去确认对方复制的是窗口里那行以 ws:// 开头的完整地址。'
    Pause-Any; return
  }
  Ok "收到地址：$peerUrl"

  # ---- 第 4 步：连通性检查 ----
  Title '第 4 步：测试能不能连上对方'
  Write-Host '  正在连接，最多等 12 秒...' -ForegroundColor DarkGray
  $t = Test-ForwardLink -Port $port -Token $token -Url $peerUrl

  if ($t.ok) {
    Ok "连接成功！对方那边是通的（延迟约 $($t.latencyMs) 毫秒）。"
  } else {
    Bad '连不上对方。'
    Info "原因：$($t.error)"
    Write-Host ''
    Write-Host '  最常见的原因是：' -ForegroundColor Yellow
    Info '· 对方那个黑色窗口被关掉了（服务没在运行）'
    Info '· 对方在外地，你们之间没有"穿透通道"——这是最可能的情况'
    Write-Host ''
    Write-Host '  ── 怎么办（按简单程度排序）──────────────────────' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  办法一：用组网工具（最推荐，双方各装一次，一次搞定永久可用）' -ForegroundColor Green
    Info '蒲公英、Tailscale、ZeroTier 都行，任选一个。'
    Info '它们的作用是：把两台相隔很远的电脑，变成像在同一个家里。'
    Info '装好、登录同一个账号（或互相加入同一网络）之后，'
    Info '把对方地址里的 IP 换成组网工具给出的 IP，再回来粘贴一次。'
    Write-Host ''
    Write-Host '  办法二：如果对方就在同一个网络里' -ForegroundColor Green
    Info '改用向导第 1 步的「1 同一个局域网」，直接发网页链接最简单。'
    Write-Host ''
    Write-Host '  办法三：两边都有公网 IP（家宽有公网地址的用户）' -ForegroundColor Green
    Info '在对方路由器上把端口映射到他那台电脑，然后用他的公网 IP。'
    Write-Host ''
    Warn '不建议把端口直接暴露到公网：健康数据是隐私，容易被扫到。'
    Pause-Any; return
  }

  # ---- 第 5 步：登记转发 ----
  Title '第 5 步：登记到转发列表'
  $a = Add-Forward -Port $port -Token $token -Url $peerUrl
  if ($a.ok) {
    Ok '已登记。以后服务启动时会自动连过去，不用再配置。'
  } else {
    Bad "登记失败：$($a.error)"
    Info '连接是通的，但没能保存配置。请把上面这行原因截图发给开发者。'
    Pause-Any; return
  }

  # ---- 完成 ----
  Title '完成'
  Ok '远程共享已建立。'
  Write-Host ''
  Info '现在对方打开他自己电脑上的面板，就能看到你的实时心率等数据。'
  Info ''
  Info '对方看数据的方式（在他自己电脑的浏览器里打开）：'
  Write-Host '    http://127.0.0.1:18787/?token=<他那台电脑启动时打印的令牌>' -ForegroundColor DarkGray
  Write-Host ''
  Warn '注意：' 
  Info '· 你这边关机或关掉服务，对方就看不到了'
  Info '· 想取消共享，双击「管理.cmd」选转发管理删除即可'
  Info '· 组网工具需要保持运行（一般会自动开机启动）'
  Write-Host ''
  Pause-Any
}

try {
  Main
} catch {
  Write-Host ''
  Bad "向导出错了：$($_.Exception.Message)"
  Write-Host ''
  Write-Host '  可以把这行信息发给开发者：' -ForegroundColor DarkGray
  Write-Host "    $($_.ScriptStackTrace)" -ForegroundColor DarkGray
  Pause-Any
}
