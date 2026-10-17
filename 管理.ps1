#Requires -Version 5.1
<#
  HealthLink 中文管理工具

  为什么有这个东西：原来要用 curl 手拼 JSON 去配转发，中文用户很容易出错。
  这里全部改成菜单 + 问答，你只管敲数字。

  用法：右键此文件 → 使用 PowerShell 运行
        或在 PowerShell 里： .\管理.ps1
#>

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = $PSScriptRoot
$ConfigFile = Join-Path $Root 'pc\config.json'
$ServerBase = 'http://127.0.0.1:18787'

function Get-Token {
    if (Test-Path $ConfigFile) {
        try {
            $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.authToken) { return $j.authToken }
        } catch { }
    }
    return $null
}

function Get-Port {
    if (Test-Path $ConfigFile) {
        try {
            $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.port) { return [int]$j.port }
        } catch { }
    }
    return 18787
}

function Call-Api {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null
    )
    $token = Get-Token
    if (-not $token) {
        Write-Host "  [X] 找不到令牌。" -ForegroundColor Red
        Write-Host "      请先双击 启动.cmd 生成配置，再回来用本工具。" -ForegroundColor Yellow
        return $null
    }
    $port = Get-Port
    $url = "http://127.0.0.1:$port$Path"
    $headers = @{ 'X-Auth-Token' = $token }
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            return Invoke-RestMethod -Uri $url -Method $Method -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 15
        }
        return Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -TimeoutSec 15
    } catch {
        Write-Host "  [X] 请求失败：$($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Message -match '拒绝|refused|Unable to connect') {
            Write-Host "      电脑端服务没在运行。请先双击 启动.cmd。" -ForegroundColor Yellow
        }
        return $null
    }
}

function Pause-Any {
    Write-Host ""
    Write-Host "  按回车返回菜单..." -ForegroundColor DarkGray
    [void][Console]::ReadLine()
}

function Show-LocalInfo {
    Write-Host ""
    Write-Host "  ===== 本机连接信息 =====" -ForegroundColor Cyan
    $token = Get-Token
    $port = Get-Port
    if (-not $token) {
        Write-Host "  还没有配置。请先双击 启动.cmd。" -ForegroundColor Yellow
        Pause-Any
        return
    }

    # 找局域网 IP：优先 192.168 / 10. / 172.16-31
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
    if (-not $lan) { $lan = ($ips | Select-Object -First 1) }
    if (-not $lan) { $lan = '127.0.0.1' }

    Write-Host ""
    Write-Host "  手机 App 里「电脑地址」填这一行（整行照抄）：" -ForegroundColor Yellow
    Write-Host "    ws://${lan}:${port}/ingest?token=$token" -ForegroundColor Green
    Write-Host ""
    Write-Host "  同一个 WiFi 的家人，用浏览器打开这一行看实时面板：" -ForegroundColor Yellow
    Write-Host "    http://${lan}:${port}/?token=$token" -ForegroundColor Green
    Write-Host ""
    Write-Host "  自己电脑上看面板：" -ForegroundColor DarkGray
    Write-Host "    http://127.0.0.1:${port}/?token=$token" -ForegroundColor DarkGray
    Pause-Any
}

function Show-ForwardList {
    Write-Host ""
    Write-Host "  ===== 当前分享目标 =====" -ForegroundColor Cyan
    $r = Call-Api -Method GET -Path '/api/forward'
    if ($null -eq $r) { Pause-Any; return }
    $list = @($r.data)
    if ($list.Count -eq 0) {
        Write-Host "  （还没有配置任何分享目标）" -ForegroundColor DarkGray
        Write-Host "  选菜单 3 可以添加。" -ForegroundColor DarkGray
        Pause-Any
        return
    }
    $i = 1
    foreach ($t in $list) {
        $stateCn = switch ($t.state) {
            'connected'  { '已连接' }
            'connecting' { '连接中' }
            'backoff'    { '重试中' }
            'disabled'   { '已停用' }
            'error'      { '出错' }
            default      { $t.state }
        }
        Write-Host ""
        Write-Host "  [$i] $($t.id)" -ForegroundColor White
        Write-Host "      地址    : $($t.url)"
        Write-Host "      状态    : $stateCn" -ForegroundColor $(if ($t.state -eq 'connected') { 'Green' } else { 'Yellow' })
        Write-Host "      已发送  : $($t.sentTotal) 条    失败: $($t.failedTotal)    待发: $($t.queued)"
        $m = @($t.metrics)
        if ($m.Count -eq 0) { Write-Host "      分享指标: 全部" } else { Write-Host "      分享指标: $($m -join '、')" }
        if ($t.lastError) { Write-Host "      最近错误: $($t.lastError)" -ForegroundColor Red }
        $i++
    }
    Pause-Any
}

function New-Forward {
    Write-Host ""
    Write-Host "  ===== 添加分享目标 =====" -ForegroundColor Cyan
    Write-Host "  你需要对方的「接收地址」，形如："
    Write-Host "    ws://100.x.y.z:18787/ingest?token=xxxxxxxx" -ForegroundColor DarkGray
    Write-Host "  （对方在他电脑上跑 health-link 的 启动.cmd，会打印这一行）"
    Write-Host ""
    $id = Read-Host "  给这个目标起个名字（英文数字，如 remote-family）"
    if ([string]::IsNullOrWhiteSpace($id)) { Write-Host "  已取消" -ForegroundColor Yellow; Pause-Any; return }
    $url = Read-Host "  粘贴对方的接收地址（ws:// 开头）"
    if ([string]::IsNullOrWhiteSpace($url)) { Write-Host "  已取消" -ForegroundColor Yellow; Pause-Any; return }
    if ($url -notmatch '^wss?://') { Write-Host "  [X] 地址必须以 ws:// 或 wss:// 开头" -ForegroundColor Red; Pause-Any; return }

    Write-Host ""
    Write-Host "  要分享哪些指标？（直接回车 = 全部）" -ForegroundColor Yellow
    Write-Host "    1 心率  2 静息心率  3 HRV  4 血氧  5 压力  6 睡眠"
    $pick = Read-Host "  输入编号，多个用逗号隔开，如 1,4,6"
    $map = @{ '1' = 'heart_rate'; '2' = 'resting_heart_rate'; '3' = 'hrv'; '4' = 'spo2'; '5' = 'stress'; '6' = 'sleep' }
    $metrics = @()
    if (-not [string]::IsNullOrWhiteSpace($pick)) {
        foreach ($p in $pick.Split(',')) {
            $k = $p.Trim()
            if ($map.ContainsKey($k)) { $metrics += $map[$k] }
        }
        if ($metrics.Count -eq 0) { Write-Host "  没识别出有效编号，按「全部」处理" -ForegroundColor Yellow }
    }

    $body = @{
        id       = $id
        enabled  = $true
        kind     = 'websocket'
        url      = $url
        deviceIds = @()
        metrics  = $metrics
        batchMs  = 2000
        retry    = @{ maxAttempts = 5; backoffMs = 1000 }
    }

    Write-Host ""
    Write-Host "  正在测试对方地址是否可达..." -ForegroundColor Yellow
    $r = Call-Api -Method POST -Path '/api/forward' -Body $body
    if ($null -eq $r) { Pause-Any; return }

    Start-Sleep -Seconds 2
    $t = Call-Api -Method POST -Path '/api/forward/test' -Body @{ id = $id }
    if ($t -and $t.data) {
        if ($t.data.reachable) {
            Write-Host "  [OK] 对方地址可达（延迟 $($t.data.latencyMs) ms）" -ForegroundColor Green
            Write-Host "       对方现在就能在他的面板上看到你的数据。" -ForegroundColor Green
        } else {
            Write-Host "  [!] 暂时连不上：$($t.data.error)" -ForegroundColor Yellow
            Write-Host "      常见原因：" -ForegroundColor Yellow
            Write-Host "        · 对方电脑上的服务没开"
            Write-Host "        · 对方的防火墙没放行对应端口"
            Write-Host "        · Tailscale 没连上，或地址写错"
            Write-Host "      配置已保存，网络一通就会自动开始发。" -ForegroundColor DarkGray
        }
    }
    Pause-Any
}

function Remove-Forward {
    Write-Host ""
    Write-Host "  ===== 删除分享目标 =====" -ForegroundColor Cyan
    $r = Call-Api -Method GET -Path '/api/forward'
    if ($null -eq $r) { Pause-Any; return }
    $list = @($r.data)
    if ($list.Count -eq 0) { Write-Host "  （没有可删除的目标）" -ForegroundColor DarkGray; Pause-Any; return }
    $i = 1
    foreach ($t in $list) { Write-Host "  [$i] $($t.id)   $($t.url)"; $i++ }
    $sel = Read-Host "  输入要删除的编号"
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $list.Count) {
        Write-Host "  编号无效" -ForegroundColor Red; Pause-Any; return
    }
    $target = $list[$n - 1]
    $confirm = Read-Host "  确认删除「$($target.id)」？(y/N)"
    if ($confirm -notmatch '^[yY]') { Write-Host "  已取消" -ForegroundColor Yellow; Pause-Any; return }
    $d = Call-Api -Method DELETE -Path "/api/forward?id=$([uri]::EscapeDataString($target.id))"
    if ($d) { Write-Host "  [OK] 已删除" -ForegroundColor Green }
    Pause-Any
}

function Show-Stats {
    Write-Host ""
    Write-Host "  ===== 运行统计 =====" -ForegroundColor Cyan
    $s = Call-Api -Method GET -Path '/api/stats'
    if ($s -and $s.data) {
        $d = $s.data
        # 逐字段防御式读取：电脑端有些字段是嵌套对象（如 subscribers），不能直接当数字打印
        foreach ($k in @('samplesReceived', 'batchesReceived', 'rejected')) {
            if ($null -ne $d.$k) { Write-Host "  $k : $($d.$k)" }
        }
        if ($null -ne $d.subscribers) {
            $sub = $d.subscribers
            if ($sub -is [int] -or $sub -is [long] -or $sub -is [double]) {
                Write-Host "  订阅者数量 : $sub"
            } elseif ($null -ne $sub.total) {
                Write-Host "  订阅者数量 : $($sub.total)"
            }
        }
    }
    Write-Host ""
    Write-Host "  ===== 已连接设备 =====" -ForegroundColor Cyan
    $dv = Call-Api -Method GET -Path '/api/devices'
    if ($dv -and $dv.data) {
        $arr = @($dv.data)
        if ($arr.Count -eq 0) {
            Write-Host "  （还没有设备连上来）" -ForegroundColor DarkGray
            Write-Host "  检查三件事：手机 App 里地址填对了吗？防火墙放行了吗？手机和电脑同一 WiFi 吗？" -ForegroundColor DarkGray
        }
        foreach ($x in $arr) {
            $idShort = if ($x.deviceId.Length -gt 12) { $x.deviceId.Substring(0, 12) + '…' } else { $x.deviceId }
            $online = if ($x.online) { '在线' } else { '离线' }
            Write-Host "  · $idShort  机型: $($x.model)  $online  已收 $($x.samplesReceived) 条"
        }
    }
    Pause-Any
}

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor Cyan
    Write-Host "       HealthLink 管理工具" -ForegroundColor Cyan
    Write-Host "  ================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   1  查看本机连接信息（手机填的地址 / 家人看的网址）"
    Write-Host "   2  查看当前分享目标与状态"
    Write-Host "   3  添加分享目标（给外地的家人看）"
    Write-Host "   4  删除分享目标"
    Write-Host "   5  查看运行统计与设备列表"
    Write-Host "   0  退出"
    Write-Host ""
}

# ---------------------------------------------------------------- 主循环
while ($true) {
    Show-Menu
    $choice = Read-Host "  请输入编号"
    switch ($choice.Trim()) {
        '1' { Show-LocalInfo }
        '2' { Show-ForwardList }
        '3' { New-Forward }
        '4' { Remove-Forward }
        '5' { Show-Stats }
        '0' { Write-Host "`n  再见。`n" -ForegroundColor Cyan; exit 0 }
        default { }
    }
}
