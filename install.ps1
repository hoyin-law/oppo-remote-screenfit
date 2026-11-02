<#
  install.ps1 —— 在线一键安装（可选方式，适合不想手动下载 zip 的用户）。
  会从 GitHub Releases 下载最新 zip，解压后调用其中的 scripts\Install.ps1（提权）。

  用法（普通 PowerShell 窗口即可，脚本会自动请求 UAC）：
    irm https://raw.githubusercontent.com/hoyin-law/oppo-remote-screenfit/main/install.ps1 | iex

  如果 GitHub 访问不畅，请改用 Release 页面下载 zip 后双击「一键安装.cmd」。
#>

$ErrorActionPreference = 'Stop'
$Repo = 'hoyin-law/oppo-remote-screenfit'
$Asset = 'oppo-remote-screenfit-v1.1.0.zip'
$Url = "https://github.com/$Repo/releases/latest/download/$Asset"
$Zip = Join-Path $env:TEMP 'oppo-remote-screenfit.zip'
$Dir = Join-Path $env:TEMP 'oppo-remote-screenfit-install'

Write-Host "下载 $Url ..."
try {
    Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing -TimeoutSec 120
} catch {
    Write-Host '下载失败。请检查网络（或代理），或直接到 Release 页面下载 zip 后双击「一键安装.cmd」。' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor DarkGray
    exit 1
}

if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
Expand-Archive -Path $Zip -DestinationPath $Dir -Force

$installer = Get-ChildItem $Dir -Recurse -Filter 'Install.ps1' | Where-Object { $_.FullName -like '*scripts*' } | Select-Object -First 1
if (-not $installer) { Write-Host '压缩包内未找到 Install.ps1，安装中止。' -ForegroundColor Red; exit 1 }

Write-Host '正在请求管理员权限…'
Start-Process 'powershell.exe' -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($installer.FullName)`""
) | Out-Null

Write-Host '已发起安装，请在 UAC 窗口点“是”。' -ForegroundColor Green
