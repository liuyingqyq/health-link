# ============================================================================
#  HealthLink 接收端打包脚本
#
#  作用：把"接收端"需要的文件收集成一个干净的文件夹，并压缩成可分发的 zip。
#
#  为什么接收端只需要这些：
#    接收方要做的事只有一件 —— 跑起电脑端服务，把地址告诉你。
#    所以只需要 pc\（服务本体，228KB，零外部依赖）+ 一个一键启动脚本 + 说明。
#    mobile\android\、mobile\harmonyos\、docs\、tools\ 这些开发用的东西都不该出现在分发包里，
#    否则接收方打开一看全是看不懂的文件，反而不敢用。
#
#  用法：.\tools\build-receiver-package.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root     = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Template = Join-Path $Root 'tools\receiver-template'
$DistRoot = Join-Path $Root 'dist'
$PkgName  = 'HealthLink 健康数据接收端'
$PkgDir   = Join-Path $DistRoot $PkgName

function Step { param([string]$T) Write-Host ''; Write-Host "  ▶ $T" -ForegroundColor Cyan }
function Ok   { param([string]$T) Write-Host "    [√] $T" -ForegroundColor Green }
function Bad  { param([string]$T) Write-Host "    [×] $T" -ForegroundColor Red }

Write-Host ''
Write-Host '  ══════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '    HealthLink 接收端 · 打包' -ForegroundColor Cyan
Write-Host '  ══════════════════════════════════════════════════' -ForegroundColor Cyan

# ---- 0) 前置检查 ----
Step '检查源文件'
foreach ($need in @(
  (Join-Path $Root 'pc\src\index.js'),
  (Join-Path $Template '启动.ps1'),
  (Join-Path $Template '说明-给接收方.md'),
  (Join-Path $Template '说明-给分享方.md')
)) {
  if (-not (Test-Path $need)) { Bad "缺少必需文件：$need"; exit 1 }
}
Ok '源文件齐全'

# ---- 0b) 校验 .ps1 的 BOM ----
#  血泪教训：.ps1 少了 UTF-8 BOM，PowerShell 5.1 会按 GBK 读，中文变成坏字节、
#  引号配对错乱，用户看到的是一堆语法错误。这种文件绝不能打进分发包，
#  所以在构建阶段就拦住，而不是等接收方双击以后才发现。
Step '校验脚本编码（.ps1 必须有 UTF-8 BOM）'
$bomBad = 0
foreach ($ps1 in @(
  (Join-Path $Template '启动.ps1'),
  (Join-Path $Template '分享.ps1')
)) {
  $bytes = [System.IO.File]::ReadAllBytes($ps1)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
  if ($hasBom) {
    Ok "$(Split-Path $ps1 -Leaf) 有 BOM"
  } else {
    Bad "$(Split-Path $ps1 -Leaf) 缺 UTF-8 BOM —— 接收方打开会报一堆语法错误"
    $bomBad++
  }
}
if ($bomBad -gt 0) {
  Write-Host ''
  Write-Host '  修复方法（转成 UTF-8 带 BOM）：' -ForegroundColor Yellow
  Write-Host '    $p = "<文件路径>"' -ForegroundColor DarkGray
  Write-Host '    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)' -ForegroundColor DarkGray
  Write-Host '    [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))' -ForegroundColor DarkGray
  Write-Host ''
  exit 1
}

# ---- 1) 准备输出目录 ----
Step '准备输出目录'
if (Test-Path $DistRoot) {
  Get-ChildItem $DistRoot -File -Filter '*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
if (Test-Path $PkgDir) { Remove-Item $PkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $PkgDir -Force | Out-Null
Ok "已清空并重建：dist\$PkgName"

# ---- 2) 复制 pc\（服务本体）----
Step '复制服务本体 pc\'
$pcSrc = Join-Path $Root 'pc'
$pcDst = Join-Path $PkgDir 'pc'

# ⚠️ 必须排除编译产物，别用 Copy-Item -Recurse 一把梭。
#    踩过的坑：pc\ble\ 编译后 bin\ 里有 24 MB 的 Windows SDK 运行时 DLL，
#    整目录复制会让分发包从 75 KB 膨胀到 6.4 MB（86 倍），
#    而且接收方拿到一堆 .dll/.pdb 只会困惑。这些都可从源码重建，不该进包。
$pcJunk = @(
  'bin', 'obj', 'node_modules', '.vscode', '.idea',
  'archive', '__pycache__'
)
Copy-Item $pcSrc $pcDst -Recurse -Force
foreach ($j in $pcJunk) {
  Get-ChildItem $pcDst -Recurse -Directory -Filter $j -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
# 顺手清掉可能混进来的编译产物文件
Get-ChildItem $pcDst -Recurse -File -Include *.pdb, *.obj, *.dll -ErrorAction SilentlyContinue |
  Where-Object { $_.DirectoryName -notmatch 'web' } |
  ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

# 接收方只需要"把服务跑起来并把地址告诉你"，以下是开发/扩展用的，不进包：
#   ble\       —— PC 蓝牙桥的 C# 源码。接收方要用它得装 .NET SDK 并自己编译，
#                 而它的用途是"数据拥有者"那边直连心率带，与接收方无关。
#   test\      —— 自动化测试，接收方不会跑。
foreach ($extra in @('ble', 'test')) {
  $p = Join-Path $pcDst $extra
  if (Test-Path $p) {
    Remove-Item $p -Recurse -Force
    Ok "已排除 pc\$extra\（开发用，接收方不需要）"
  }
}

# 分发包里不该带开发者的令牌/转发配置：清掉，接收方第一次启动会生成自己的
$cfgFile = Join-Path $pcDst 'config.json'
if (Test-Path $cfgFile) { Remove-Item $cfgFile -Force }
$fwdFile = Join-Path $pcDst 'forwards.json'
if (Test-Path $fwdFile) { Remove-Item $fwdFile -Force; Ok '已移除开发者配置（令牌/转发），接收方首次启动自动生成' }

# 统计
$pcFiles = Get-ChildItem $pcDst -Recurse -File
$pcSize = ($pcFiles | Measure-Object -Property Length -Sum).Sum
Ok "pc\ 共 $($pcFiles.Count) 个文件，$([math]::Round($pcSize/1KB,1)) KB（零外部依赖，不需要 npm install）"

# 体积兜底：超过 1 MB 说明又混进了不该带的东西，直接报错而不是悄悄产出大包
if ($pcSize -gt 1MB) {
  Bad "pc\ 体积异常（$([math]::Round($pcSize/1MB,2)) MB，预期 < 1 MB）——很可能又混进了编译产物"
  Write-Host '    请检查 pc\ 下是否有 bin\ / obj\ 目录被复制进来：' -ForegroundColor Yellow
  Get-ChildItem $pcDst -Recurse -File |
    Sort-Object Length -Descending | Select-Object -First 5 |
    ForEach-Object { Write-Host ("      {0,10} KB  {1}" -f [math]::Round($_.Length/1KB,1), $_.FullName.Replace("$PkgDir\","")) -ForegroundColor DarkGray }
  exit 1
}

# ---- 3) 复制模板文件（启动脚本 + 说明）----
Step '复制启动脚本与说明'
foreach ($f in @('启动.ps1', '分享.ps1', '说明-给接收方.md', '说明-给分享方.md')) {
  $src = Join-Path $Template $f
  Copy-Item $src (Join-Path $PkgDir $f) -Force
  Ok $f
}

# ---- 3b) 剔除接收方用不到的文件 ----
#  接收方只是"跑起来看数据"，不需要自动化测试和开发者文档。
#  包里少一个看不懂的文件，就少一分"这包是不是有问题"的犹豫。
Step '剔除接收方用不到的文件'
foreach ($junk in @('pc\test', 'pc\web\README.md')) {
  $p = Join-Path $PkgDir $junk
  if (Test-Path $p) {
    Remove-Item $p -Recurse -Force
    Ok "已移除 $junk"
  }
}

# ---- 4) 生成 启动.cmd（纯 ASCII 内容 + GBK 编码）----
#  为什么这么讲究：
#    .cmd 是 cmd.exe 用系统代码页（中文 Windows = GBK）读取的。
#    带 UTF-8 BOM 会让窗口一闪就关；UTF-8 的中文会被读成乱码拆行。
#    所以：内容保持纯 ASCII，编码用 GBK，行尾 CRLF，不加 BOM。
Step '生成 启动.cmd'
$cmdText = @"
@echo off
rem  Pure ASCII on purpose: cmd.exe reads .cmd with the console codepage.
rem  A UTF-8 BOM would make this window flash and close.
setlocal
title HealthLink Receiver

cd /d "%~dp0"

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0启动.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0启动.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   [FAILED] exit code %errorlevel%
    pause
)
"@
$cmdText = ($cmdText -replace "`r`n", "`n") -replace "`n", "`r`n"
[System.IO.File]::WriteAllBytes((Join-Path $PkgDir '启动.cmd'), [System.Text.Encoding]::GetEncoding(936).GetBytes($cmdText))
Ok '启动.cmd（GBK + CRLF + 无 BOM）'

# ---- 5) 生成 分享.cmd（接收方如果想再分享给别人）----
#  只负责调起 分享.ps1：IP 探测、令牌读取都在 ps1 里做，批处理不碰这些。
Step '生成 分享.cmd'
$shareText = @"
@echo off
rem  Pure ASCII on purpose (see 启动.cmd header).
rem  The Chinese UI and the LAN-IP detection live in 分享.ps1.
setlocal
title HealthLink Share Link

cd /d "%~dp0"

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0分享.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0分享.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   [FAILED] exit code %errorlevel%
    pause
)
"@
$shareText = ($shareText -replace "`r`n", "`n") -replace "`n", "`r`n"
[System.IO.File]::WriteAllBytes((Join-Path $PkgDir '分享.cmd'), [System.Text.Encoding]::GetEncoding(936).GetBytes($shareText))
Ok '分享.cmd'

# ---- 6) 生成 版本信息.txt ----
Step '生成版本信息'
$versionText = @"
HealthLink 健康数据接收端
打包时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
服务端口：18787（可在 pc\config.json 里用 port 字段修改）

用法：双击 启动.cmd

本包内所有程序都是纯脚本，不含任何可执行程序。
数据只在你和对方两台电脑之间传输，不上传任何服务器。
"@
[System.IO.File]::WriteAllText((Join-Path $PkgDir '版本信息.txt'), $versionText, (New-Object System.Text.UTF8Encoding($true)))
Ok '版本信息.txt'

# ---- 7) 打包 zip ----
Step '压缩成 zip'
$zipPath = Join-Path $DistRoot "$PkgName.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $PkgDir -DestinationPath $zipPath -CompressionLevel Optimal
$zipSize = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)

# ---- 8) 校验 zip 里的中文路径能否正确读出 ----
Step '校验压缩包'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$entries = $zip.Entries | ForEach-Object { $_.FullName }
$zip.Dispose()

$hasChineseOk = ($entries | Where-Object { $_ -match '接收端' }).Count -gt 0
$entryCount = $entries.Count

Ok "压缩包：dist\$PkgName.zip  （$zipSize KB，$entryCount 个条目）"
if ($hasChineseOk) {
  Ok '中文路径在压缩包内可正确读取'
} else {
  Bad '压缩包内中文路径可能损坏（部分解压软件会乱码）'
}

# ---- 9) 汇总 ----
Write-Host ''
Write-Host '  ══════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '    打包完成' -ForegroundColor Green
Write-Host '  ══════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host "    文件夹：dist\$PkgName\" -ForegroundColor White
Write-Host "    压缩包：dist\$PkgName.zip  （$zipSize KB）" -ForegroundColor White
Write-Host ''
Write-Host '    这个压缩包可以直接发给接收方（家人/朋友）：' -ForegroundColor DarkGray
Write-Host '      · 他不需要懂技术，解压后双击 启动.cmd' -ForegroundColor DarkGray
Write-Host '      · 包里带了中文说明，遇到问题能自己看' -ForegroundColor DarkGray
Write-Host ''
