# 完整验证接收端包：解压到独立目录 → 启动 → 验证服务可用 → 清理
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path $PSScriptRoot -Parent   # 仓库根目录 = 本脚本所在目录的上一级
$Zip  = Join-Path $Root 'dist\HealthLink 健康数据接收端.zip'
$TestDir = Join-Path $env:TEMP 'hl-receiver-test'

Write-Host '  === 1) 清理并解压（模拟接收方拿到 zip）==='
if (Test-Path $TestDir) { Remove-Item $TestDir -Recurse -Force }
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
Expand-Archive -Path $Zip -DestinationPath $TestDir -Force
$pkg = Join-Path $TestDir 'HealthLink 健康数据接收端'
if (-not (Test-Path $pkg)) { Write-Host '  [×] 解压后找不到包目录'; exit 1 }
Write-Host "  [√] 解压到 $pkg"

Write-Host ''
Write-Host '  === 2) 确认没有开发者的配置泄漏 ==='
foreach ($f in @('pc\config.json', 'pc\forwards.json')) {
  $p = Join-Path $pkg $f
  if (Test-Path $p) { Write-Host "  [×] 不应存在的开发者文件：$f" }
  else { Write-Host "  [√] $f 已移除（接收方会生成自己的）" }
}

Write-Host ''
Write-Host '  === 3) 检查关键文件的编码 ==='
$cmdPath = Join-Path $pkg '启动.cmd'
$b = [System.IO.File]::ReadAllBytes($cmdPath)
$bom = ($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
$lf = 0; for ($i=0;$i -lt $b.Length;$i++){ if($b[$i] -eq 10 -and $b[$i-1] -ne 13){$lf++} }
Write-Host "  启动.cmd  BOM=$(if($bom){'有 [×]'}else{'无 [√]'})  裸LF=$lf $(if($lf -eq 0){'[√]'}else{'[×]'})"

$psPath = Join-Path $pkg '启动.ps1'
$b2 = [System.IO.File]::ReadAllBytes($psPath)
$bom2 = ($b2[0] -eq 239 -and $b2[1] -eq 187 -and $b2[2] -eq 191)
Write-Host "  启动.ps1  BOM=$(if($bom2){'有 [√]'}else{'无 [×]'})"

$spPath = Join-Path $pkg '分享.ps1'
$b3 = [System.IO.File]::ReadAllBytes($spPath)
$bom3 = ($b3[0] -eq 239 -and $b3[1] -eq 187 -and $b3[2] -eq 191)
Write-Host "  分享.ps1  BOM=$(if($bom3){'有 [√]'}else{'无 [×]'})"

$shCmd = Join-Path $pkg '分享.cmd'
$b4 = [System.IO.File]::ReadAllBytes($shCmd)
$bom4 = ($b4[0] -eq 239)
Write-Host "  分享.cmd  BOM=$(if($bom4){'有 [×]'}else{'无 [√]'})"

Write-Host ''
Write-Host '  === 4) 走接收方的真实路径：运行包里的 启动.ps1 ==='
#  刻意不直接跑 node：接收方是双击 启动.cmd → 启动.ps1 → node。
#  必须走同一条路，才能验证"令牌生成 + 显示地址"这些用户能看到的东西。
$launchPs1 = Join-Path $pkg '启动.ps1'
$tmpOut = Join-Path $env:TEMP 'hl-recv-launch-out.txt'
$tmpErr = Join-Path $env:TEMP 'hl-recv-launch-err.txt'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launchPs1`""
$psi.WorkingDirectory = $pkg
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardInput = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEndAsync()
# 服务会一直跑，所以后台读输出，5 秒后我们主动停掉它
Start-Sleep -Seconds 6
$running = -not $proc.HasExited

Write-Host '  === 5) 验证配置已自动生成 ==='
$cfgPath = Join-Path $pkg 'pc\config.json'
if (Test-Path $cfgPath) {
  $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Host "  [√] config.json 已自动生成"
  Write-Host "      令牌长度：$($cfg.authToken.Length) 字符（应为 32）"
  Write-Host "      端口：$($cfg.port)"
  $tok = $cfg.authToken
} else {
  Write-Host '  [×] config.json 未生成'
  $tok = ''
}

Write-Host ''
Write-Host '  === 6) 验证服务可用 ==='
try {
  $r = Invoke-RestMethod -Uri "http://127.0.0.1:18787/api/health?token=$tok" -TimeoutSec 6
  Write-Host "  [√] /api/health 正常：service=$($r.data.service) protocol=$($r.data.protocol)"
} catch {
  Write-Host "  [×] /api/health 失败：$($_.Exception.Message)"
}

try {
  # 分享页也要能打开（接收方家人可能用）
  $r2 = Invoke-WebRequest -Uri "http://127.0.0.1:18787/share.html?token=$tok" -TimeoutSec 6 -UseBasicParsing
  Write-Host "  [√] 分享页可访问：HTTP $($r2.StatusCode)，$([math]::Round($r2.Content.Length/1KB,1)) KB"
} catch {
  Write-Host "  [×] 分享页失败：$($_.Exception.Message)"
}

Write-Host ''
Write-Host '  === 7) 收尾（先停止服务，再收输出）==='
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
Start-Sleep -Seconds 2

Write-Host '  === 8) 验证接收方屏幕上真的显示了那行地址 ==='
try {
  $text = $stdout.Result
} catch {
  $text = ''
}
if ($text -match 'ws://[\d\.]+:18787/ingest\?token=[0-9a-f]{32}') {
  Write-Host '  [√] 屏幕上显示了完整的 ws:// 收货地址（接收方照抄即可）'
} else {
  Write-Host '  [×] 没在输出里找到 ws:// 收货地址'
  Write-Host "      （输出长度 $($text.Length) 字符）"
}
if ($text -match '请把下面这一行') {
  Write-Host '  [√] 中文提示完整（UTF-8 BOM 正常，未乱码）'
} else {
  Write-Host '  [×] 中文提示缺失或乱码'
}

Remove-Item $TestDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
Write-Host '  [√] 测试目录已清理'
