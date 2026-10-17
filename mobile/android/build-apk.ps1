# 命令行构建 Android APK（不依赖 Android Studio 图形界面）
#
# 为什么需要这个脚本：这个沙箱/受限环境里有 5 个坑，每个都会让构建失败，
# 而且报错信息都不直观。全部固化在这里：
#
#   1. JDK 版本     Android Studio/DevEco 自带的 JBR 是 JDK 25，AGP 8.5 用不了
#                   → 报 "Unsupported class file major version 69"
#                   本脚本用 .tooling/jdk-21.0.2
#   2. user.home    AGP 要写 <user.home>\.android\analytics.settings，
#                   沙箱不允许写 C:\Users\<你> → 报 "AccessDeniedException"
#                   本脚本把 user.home 指到工作区内
#   3. ANDROID_USER_HOME  同上，debug.keystore 也落在 user.home 下
#   4. 文件监听     Gradle 的 native 文件监听在沙箱里报 error = 5
#                   → 用 --no-watch-fs 关掉
#   5. SDK 平台     本机只装了 android-37.0，而 AGP 8.5 不认识 API 37
#                   → compileSdk 用 36（已装 android-36）
#
# 用法：
#   .\android\build-apk.ps1                  # 增量构建
#   .\android\build-apk.ps1 -Clean           # 先 clean
#   .\android\build-apk.ps1 -Release         # 构建 release（未配置签名，产物未签名）
#
# 产物：android\dist\healthlink-collector-debug.apk

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'

$AndroidDir = Split-Path -Parent $PSCommandPath
$Root       = Join-Path $AndroidDir '.tooling'
$Gradle     = Join-Path $Root 'gradle-8.7\bin\gradle.bat'
$Jdk        = Join-Path $Root 'jdk-21.0.2'
$FakeHome   = Join-Path $Root 'home'
$GradleHome = Join-Path $Root 'gradle-home'
$Sdk        = 'D:\Android\Sdk'
$Dist       = Join-Path $AndroidDir 'dist'

# ---------------------------------------------------------------- 前置检查
$problems = @()
if (-not (Test-Path $Gradle)) { $problems += "缺少 Gradle 8.7：$Gradle" }
if (-not (Test-Path $Jdk))    { $problems += "缺少 JDK 21：$Jdk（构建需要 JDK 17/21，JBR 25 不行）" }
if (-not (Test-Path "$Sdk\platforms\android-36")) { $problems += "缺少 SDK 平台 android-36：$Sdk\platforms" }
if ($problems.Count -gt 0) {
    Write-Host "[x] 环境不完整：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "    提示：用 Android Studio 打开 android 目录构建也可以（见 android/README.md）" -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path "$FakeHome\.android" | Out-Null
New-Item -ItemType Directory -Force -Path $GradleHome | Out-Null
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

# ---------------------------------------------------------------- 环境变量（关键）
$env:JAVA_HOME         = $Jdk
$env:PATH              = "$Jdk\bin;$env:PATH"
$env:ANDROID_HOME      = $Sdk
$env:ANDROID_SDK_ROOT  = $Sdk
$env:ANDROID_USER_HOME = $FakeHome
$env:JAVA_OPTS         = "-Duser.home=$FakeHome"
$env:GRADLE_OPTS       = "-Duser.home=$FakeHome -Dorg.gradle.vfs.watch=false"

$task = if ($Release) { 'assembleRelease' } else { 'assembleDebug' }
$label = if ($Release) { 'release' } else { 'debug' }

Write-Host "=== HealthLink Android 构建 ===" -ForegroundColor Cyan
Write-Host "  工程   : $AndroidDir"
Write-Host "  JDK    : $Jdk"
Write-Host "  SDK    : $Sdk"
Write-Host "  任务   : $task"
Write-Host ""

$LogFile = Join-Path $env:TEMP ("healthlink-android-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$sw = [System.Diagnostics.Stopwatch]::StartNew()

Push-Location $AndroidDir
try {
    if ($Clean) {
        Write-Host "[1/2] clean ..." -ForegroundColor Yellow
        & $Gradle --project-dir $AndroidDir --gradle-user-home $GradleHome --no-daemon --no-watch-fs clean 2>&1 |
            Tee-Object -FilePath $LogFile | Out-Null
    }
    Write-Host "[2/2] $task ..." -ForegroundColor Yellow
    & $Gradle --project-dir $AndroidDir --gradle-user-home $GradleHome --no-daemon --no-watch-fs $task 2>&1 |
        Tee-Object -FilePath $LogFile -Append | Out-Null
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
    $sw.Stop()
}

# ---------------------------------------------------------------- 结果
$logText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
$errCount = ([regex]::Matches($logText, '(?m)^e: ')).Count
$warnCount = ([regex]::Matches($logText, '(?m)^w: ')).Count

Write-Host ""
if ($logText -match 'BUILD SUCCESSFUL') {
    Write-Host "[OK] 构建成功（$([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）" -ForegroundColor Green
    Write-Host "     Kotlin 错误 $errCount 个，警告 $warnCount 个"
    $apk = Get-ChildItem (Join-Path $AndroidDir "app\build\outputs\apk\$label") -Filter *.apk -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($apk) {
        $dest = Join-Path $Dist "healthlink-collector-$label.apk"
        Copy-Item $apk.FullName $dest -Force
        Write-Host ""
        Write-Host "  产物: $dest" -ForegroundColor Green
        Write-Host "  大小: $([math]::Round($apk.Length/1KB,1)) KB"
        Write-Host ""
        Write-Host "  安装到手机（需开 USB 调试并连上数据线）:" -ForegroundColor Cyan
        Write-Host "    & '$Sdk\platform-tools\adb.exe' install -r `"$dest`"" -ForegroundColor Cyan
    }
} else {
    Write-Host "[x] 构建失败（$([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）" -ForegroundColor Red
    Write-Host "    Kotlin 错误 $errCount 个"
    Write-Host ""
    Write-Host "  最后 30 行日志：" -ForegroundColor Yellow
    Get-Content $LogFile -Tail 30 | ForEach-Object { "    $_" }
}

Write-Host ""
Write-Host "完整日志: $LogFile"
exit $code
