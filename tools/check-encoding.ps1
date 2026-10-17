# 全项目编码规范终检：.ps1 必须有 BOM，.cmd 必须无 BOM + GBK + CRLF
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path $PSScriptRoot -Parent   # 仓库根目录 = 本脚本所在目录的上一级

$problems = 0

Write-Host ''
Write-Host '  === .ps1（必须有 UTF-8 BOM）==='
Get-ChildItem $Root -Recurse -File -Filter *.ps1 |
  Where-Object { $_.FullName -notmatch 'node_modules|\.tooling|build|\.gradle|\.hvigor|dist' } |
  ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $ok = ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
    if (-not $ok) { $problems++ }
    $rel = $_.FullName.Replace("$Root\", '')
    Write-Host ("  {0} {1}" -f $(if ($ok) { '[√]' } else { '[×]' }), $rel)
  }

Write-Host ''
Write-Host '  === .cmd（必须无 BOM + GBK 可解 + 纯 CRLF）==='
Get-ChildItem $Root -Recurse -File -Filter *.cmd |
  Where-Object { $_.FullName -notmatch 'node_modules|\.tooling|build|\.gradle|\.hvigor|dist' } |
  ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $noBom = -not ($b[0] -eq 239)
    $lf = 0
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 10 -and $b[$i - 1] -ne 13) { $lf++ } }
    $crlfOk = ($lf -eq 0)
    $gbkOk = $true
    try { [void][System.Text.Encoding]::GetEncoding(936).GetString($b) } catch { $gbkOk = $false }
    $ok = $noBom -and $crlfOk -and $gbkOk
    if (-not $ok) { $problems++ }
    $rel = $_.FullName.Replace("$Root\", '')
    Write-Host ("  {0} {1}  无BOM={2} CRLF={3} GBK可解={4}" -f `
      $(if ($ok) { '[√]' } else { '[×]' }), $rel, $noBom, $crlfOk, $gbkOk)
  }

Write-Host ''
Write-Host '  === .json 运行时配置（不能有 BOM：JSON.parse 不认）==='
$jsonFiles = Get-ChildItem $Root -Recurse -File -Filter *.json -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch 'node_modules|\.tooling|build|\.gradle|\.hvigor|dist|package\.json|tsconfig' }
if ($jsonFiles.Count -eq 0) {
  Write-Host '  （没有运行时 JSON 文件）'
} else {
  foreach ($jf in $jsonFiles) {
    $jb = [System.IO.File]::ReadAllBytes($jf.FullName)
    $jBom = ($jb.Length -ge 3 -and $jb[0] -eq 239 -and $jb[1] -eq 187 -and $jb[2] -eq 191)
    if ($jBom) { $problems++ }
    Write-Host ("  {0} {1}  (json 需无 BOM)" -f $(if ($jBom) { '[×]' } else { '[√]' }), $jf.FullName.Replace("$Root\", ''))
  }
  Write-Host '  注：PowerShell 的 Set-Content -Encoding UTF8 和记事本"另存为 UTF-8"都会加 BOM。' -ForegroundColor DarkGray
  Write-Host '      服务端已加 stripBom 容错，但保持干净更好。' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  === 分发包内容（dist 目录，也要满足同样的编码规则）==='
$pkg = Join-Path $Root 'dist\HealthLink 健康数据接收端'
if (Test-Path $pkg) {
  Get-ChildItem $pkg -File | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($_.Extension -eq '.ps1') {
      $ok = ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
      if (-not $ok) { $problems++ }
      Write-Host ("  {0} {1}  (ps1 需 BOM)" -f $(if ($ok) { '[√]' } else { '[×]' }), $_.Name)
    } elseif ($_.Extension -eq '.cmd') {
      $noBom = -not ($b[0] -eq 239)
      if (-not $noBom) { $problems++ }
      Write-Host ("  {0} {1}  (cmd 需无 BOM)" -f $(if ($noBom) { '[√]' } else { '[×]' }), $_.Name)
    } else {
      Write-Host ("  [─] {0}  (不需要 BOM)" -f $_.Name)
    }
  }
} else {
  # 分发包是**构建产物**（.gitignore 忽略），全新克隆下来的仓库里本来就没有 ——
  # 这不算问题，跳过即可；跑过 tools\build-receiver-package.ps1 之后再检查才有意义。
  Write-Host '  [─] 分发包尚未生成，跳过（先跑 tools\build-receiver-package.ps1）'
}

Write-Host ''
if ($problems -eq 0) {
  Write-Host '  ══════════════════════════════════════════' -ForegroundColor Green
  Write-Host '    编码规范全部通过（0 个问题）' -ForegroundColor Green
  Write-Host '  ══════════════════════════════════════════' -ForegroundColor Green
} else {
  Write-Host ("  ══ {0} 个文件不符合编码规范 ══" -f $problems) -ForegroundColor Red
}
Write-Host ''
