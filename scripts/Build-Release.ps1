<#
  Build-Release.ps1 —— 从当前工作树产出可复现的 Release 包。
  用法：
    pwsh -NoProfile -File scripts\Build-Release.ps1
    pwsh -NoProfile -File scripts\Build-Release.ps1 -Version 1.2.5 -AllowDirty
  产物：
    release\oppo-remote-screenfit-v<ver>.zip
    release\pack\oppo-remote-screenfit-v<ver>\   （打包内容，便于核对）
  校验：版本一致性、脚本语法、zip 内文件与工作树逐字节一致、包内文件清单。
#>

[CmdletBinding()]
param(
    [string]$Version = $null,
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Core = Join-Path $PSScriptRoot 'ScreenFit.Core.ps1'
$VersionFile = Join-Path $Repo 'VERSION'

function Fail([string]$msg) { Write-Host ("BUILD FAILED: " + $msg) -ForegroundColor Red; exit 1 }

if (-not (Test-Path $VersionFile)) { Fail '缺少 VERSION 文件' }
$verFromFile = (Get-Content $VersionFile -Raw).Trim()
$ver = if ($Version) { $Version } else { $verFromFile }
if ($ver -notmatch '^\d+\.\d+\.\d+$') { Fail ("版本号格式非法: " + $ver) }
if ($ver -ne $verFromFile) { Fail ("命令行版本 " + $ver + " 与 VERSION 文件 " + $verFromFile + " 不一致") }

. $Core
$coreVer = Get-ScreenFitVersion
if ($coreVer -ne $ver) { Fail ("ScreenFit.Core.ps1 版本 " + $coreVer + " 与 VERSION " + $ver + " 不一致") }

# HEAD 必须等于工作树，否则产物无法复现
$dirty = @(git -C $Repo status --porcelain 2>$null | Where-Object { $_ -and ($_ -notmatch '^\?\? release/') })
if ($dirty.Count -gt 0 -and -not $AllowDirty) {
    Write-Host '工作树不干净，发布产物将不可复现：' -ForegroundColor Yellow
    $dirty | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Yellow }
    Fail '请先提交，或显式使用 -AllowDirty'
}

$name = "oppo-remote-screenfit-v$ver"
$PackRoot = Join-Path $Repo 'release\pack'
$Stage = Join-Path $PackRoot $name
$Zip = Join-Path $Repo ("release\" + $name + ".zip")

Write-Host ("1/4 准备打包目录 " + $Stage)
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force $Stage | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Stage 'scripts') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Stage 'docs') | Out-Null

$rootFiles = @('README.md', 'README.en.md', 'LICENSE', 'VERSION', '一键安装.cmd', '一键卸载.cmd')
foreach ($f in $rootFiles) {
    $p = Join-Path $Repo $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $Stage $f) -Force } else { Fail ("缺少文件 " + $f) }
}
foreach ($f in (Get-ChildItem (Join-Path $Repo 'docs') -File)) { Copy-Item $f.FullName (Join-Path $Stage 'docs') -Force }
foreach ($f in (Get-ChildItem (Join-Path $Repo 'scripts') -File -Filter '*.ps1')) { Copy-Item $f.FullName (Join-Path $Stage 'scripts') -Force }

Write-Host '2/4 校验包内脚本语法与关键文件'
foreach ($f in (Get-ChildItem $Stage -Recurse -File -Filter '*.ps1')) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) { Fail ("语法错误 " + $f.Name + " 行 " + $errs[0].Extent.StartLineNumber + ": " + $errs[0].Message) }
}
foreach ($must in @('scripts\Watcher.ps1', 'scripts\ScreenFit.Core.ps1', 'scripts\Install.ps1', 'VERSION')) {
    if (-not (Test-Path (Join-Path $Stage $must))) { Fail ("包内缺少 " + $must) }
}

Write-Host '3/4 生成 zip'
if (Test-Path $Zip) { Remove-Item $Zip -Force }
Compress-Archive -Path $Stage -DestinationPath $Zip -Force

Write-Host '4/4 校验 zip 内容与工作树一致'
$check = Join-Path $env:TEMP ("sfbuild-" + [guid]::NewGuid().ToString('N'))
Expand-Archive -Path $Zip -DestinationPath $check -Force
$inner = Join-Path $check $name
$mismatch = @()
foreach ($f in (Get-ChildItem $Stage -Recurse -File)) {
    $rel = $f.FullName.Substring($Stage.Length + 1)
    $z = Join-Path $inner $rel
    if (-not (Test-Path $z)) { $mismatch += ("缺失 " + $rel); continue }
    if ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $z -Algorithm SHA256).Hash) { $mismatch += ("内容不同 " + $rel) }
}
Remove-Item $check -Recurse -Force -ErrorAction SilentlyContinue
if ($mismatch.Count -gt 0) { $mismatch | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Red }; Fail 'zip 内容校验失败' }

Write-Host ''
Write-Host ("✅ 发布包已生成: " + $Zip) -ForegroundColor Green
Write-Host ("   版本: " + $ver + "   文件数: " + @(Get-ChildItem $Stage -Recurse -File).Count + "   大小: " + [math]::Round((Get-Item $Zip).Length / 1KB, 1) + " KB")
Get-ChildItem $Stage -Recurse -File | ForEach-Object { Write-Host ("   " + $_.FullName.Substring($Stage.Length + 1) + "  (" + $_.Length + " B)") }
