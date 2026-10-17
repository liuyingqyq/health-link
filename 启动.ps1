<#
.SYNOPSIS
  HealthLink 电脑端启动器（PowerShell 入口）。

.DESCRIPTION
  在 PowerShell 里直接运行：
      .\启动
      .\启动 -OpenBrowser 1
      .\启动 -Port 9000 -OpenBrowser 1

  在文件资源管理器里双击 启动.cmd 也可以（效果一样）。
  真正的启动逻辑在 tools\launcher-core.ps1，本文件只负责参数转发。

.NOTES
  如果提示"禁止运行脚本"，说明你的执行策略是 Restricted。
  在 PowerShell 里执行一次这条命令即可（只影响当前用户）：
      Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>
[CmdletBinding()]
param(
  [switch]$OpenBrowser,
  [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot 'tools\launcher-core.ps1'
if (-not (Test-Path $core)) {
  Write-Host "找不到启动逻辑脚本：$core" -ForegroundColor Red
  Write-Host "请确认 health-link 目录结构完整（tools\launcher-core.ps1 应存在）。" -ForegroundColor Yellow
  exit 1
}

$openFlag = if ($OpenBrowser) { 1 } else { 0 }

if ($Port -gt 0) {
  & $core -OpenBrowser $openFlag -Port $Port
} else {
  & $core -OpenBrowser $openFlag
}
exit $LASTEXITCODE