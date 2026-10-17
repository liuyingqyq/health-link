# 命令行构建 HarmonyOS HAP（不依赖 DevEco 图形界面）
#
# 为什么需要这个脚本：
#   hvigor 命令行构建有几个**必须**的环境变量，缺一个就会失败，而且报错信息
#   很不直观。这些值是本次实际构建摸索出来的，固化在这里免得再踩：
#
#     DEVECO_SDK_HOME  不设 → "Invalid value of 'DEVECO_SDK_HOME' in the system
#                              environment path"
#     java 不在 PATH   不设 → "spawn java ENOENT"（在 PackageHap 阶段才报，
#                             前面的 ArkTS 编译都成功，很容易误判成代码问题）
#
#   注意：不需要自己搭离线 npm registry —— hvigor 会用 DevEco 自带的依赖缓存
#   （C:\Users\<你>\.hvigor\project_caches\...）。只要上面两个变量设对就行。
#
# 用法：
#   .\tools\build-phone.ps1                     # 增量构建
#   .\tools\build-phone.ps1 -Clean              # 先 clean 再全量构建
#   .\tools\build-phone.ps1 -DevEcoRoot 'D:\Downloads\DevEco Studio'
#
# 产物：
#   mobile\harmonyos\entry\build\default\outputs\default\entry-default-unsigned.hap
#
# ⚠️ 命令行构建出来的是**未签名** HAP，不能直接安装。
#    要装到手机上，请在 DevEco Studio 里配置自动签名（见 docs/手机端安装指南.md）。

[CmdletBinding()]
param(
    [string]$DevEcoRoot = 'D:\Downloads\DevEco Studio',
    [switch]$Clean,
    [switch]$OpenLog
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 定位工程

$ProjectRoot = Split-Path -Parent $PSScriptRoot   # tools -> 项目根
# 两个手机端工程都归到 mobile\ 下了：mobile\harmonyos\ 与 mobile\android\
$PhoneDir = Join-Path $ProjectRoot 'mobile\harmonyos'
if (-not (Test-Path (Join-Path $PhoneDir 'build-profile.json5'))) {
    Write-Host "[x] 找不到鸿蒙工程：$PhoneDir" -ForegroundColor Red
    Write-Host "    期望位置：mobile\harmonyos\（含 build-profile.json5）" -ForegroundColor DarkGray
    exit 1
}

# ---------------------------------------------------------------- 定位工具链

$Node = Join-Path $DevEcoRoot 'tools\node\node.exe'
$Hvigor = Join-Path $DevEcoRoot 'tools\hvigor\bin\hvigorw.js'
$Jbr = Join-Path $DevEcoRoot 'jbr'
$Sdk = Join-Path $DevEcoRoot 'sdk'

foreach ($item in @(
    @{ Path = $Node;   Name = 'Node.js' },
    @{ Path = $Hvigor; Name = 'hvigor' },
    @{ Path = $Jbr;    Name = 'JDK (jbr)' },
    @{ Path = $Sdk;    Name = 'HarmonyOS SDK' }
)) {
    if (-not (Test-Path $item.Path)) {
        Write-Host "[x] 找不到 $($item.Name)：$($item.Path)" -ForegroundColor Red
        Write-Host "    请用 -DevEcoRoot 指定 DevEco Studio 的安装目录" -ForegroundColor Yellow
        exit 1
    }
}

# ---------------------------------------------------------------- 环境变量（关键！）

$env:DEVECO_SDK_HOME = $Sdk
$env:JAVA_HOME = $Jbr
# java 必须在 PATH 里，否则 PackageHap 阶段报 "spawn java ENOENT"
$env:PATH = "$(Join-Path $Jbr 'bin');$env:PATH"

Write-Host "=== HarmonyOS 命令行构建 ===" -ForegroundColor Cyan
Write-Host "  工程   : $PhoneDir"
Write-Host "  DevEco : $DevEcoRoot"
Write-Host "  SDK    : $Sdk"
Write-Host "  JDK    : $Jbr"
Write-Host ""

$LogFile = Join-Path $env:TEMP ("healthlink-build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# hvigor 会把警告写到 stderr（例如 "Will skip sign"）。在 $ErrorActionPreference='Stop'
# 下，PowerShell 会把原生命令的 stderr 输出当成**致命错误**并中断脚本 —— 于是
# 明明构建成功了，脚本却报失败。所以调用 hvigor 期间必须放宽为 Continue。
$savedEap = $ErrorActionPreference
$savedNativePref = $null
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $savedNativePref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
}
$ErrorActionPreference = 'Continue'

Push-Location $PhoneDir
try {
    if ($Clean) {
        Write-Host "[1/2] clean ..." -ForegroundColor Yellow
        & $Node $Hvigor clean --no-daemon 2>&1 | Out-Null
        Write-Host "      clean 完成"
    }

    Write-Host "[2/2] assembleHap ..." -ForegroundColor Yellow
    & $Node $Hvigor assembleHap --mode module -p product=default --no-daemon 2>&1 |
        Tee-Object -FilePath $LogFile | Out-Null
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
    $sw.Stop()
    $ErrorActionPreference = $savedEap
    if ($null -ne $savedNativePref) {
        $PSNativeCommandUseErrorActionPreference = $savedNativePref
    }
}

# ---------------------------------------------------------------- 结果

$logText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
$errCount = ([regex]::Matches($logText, 'ArkTS Compiler Error')).Count
$warnCount = ([regex]::Matches($logText, 'ArkTS:WARN')).Count

Write-Host ""
if ($logText -match 'BUILD SUCCESSFUL') {
    Write-Host "[OK] 构建成功（$([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）" -ForegroundColor Green
    Write-Host "     ArkTS 错误 $errCount 个，警告 $warnCount 个"

    $hap = Get-ChildItem (Join-Path $PhoneDir 'entry\build') -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hap) {
        Write-Host ""
        Write-Host "  产物: $($hap.FullName)" -ForegroundColor Green
        Write-Host "  大小: $([math]::Round($hap.Length/1KB,1)) KB"
    }

    if ($logText -match 'Will skip sign') {
        Write-Host ""
        Write-Host "  [!] 这是**未签名** HAP，不能直接装到手机。" -ForegroundColor Yellow
        Write-Host "      安装请在 DevEco Studio 里：File → Project Structure → Signing Configs" -ForegroundColor Yellow
        Write-Host "      → 勾选 Automatically generate signature → 登录华为账号 → Apply，然后点 Run。" -ForegroundColor Yellow
    }
} else {
    Write-Host "[x] 构建失败（$([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）" -ForegroundColor Red
    Write-Host "    ArkTS 错误 $errCount 个，警告 $warnCount 个"
    Write-Host ""
    Write-Host "  最后 25 行日志：" -ForegroundColor Yellow
    Get-Content $LogFile -Tail 25 | ForEach-Object { "    $_" }
}

Write-Host ""
Write-Host "完整日志: $LogFile"

if ($OpenLog) {
    Invoke-Item $LogFile
}

exit $code
