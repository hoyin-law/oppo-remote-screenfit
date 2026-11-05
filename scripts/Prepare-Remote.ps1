<#
  Prepare-Remote.ps1 —— 预建屏：在发起 OPPO 远控之前运行，让电脑提前就绪。

  原理：
    1) 在电脑上写一个 PREARM.txt（内容为目标设备名）；
    2) 管理员计划任务里的 Watcher 会在 1 秒内：
       保存当前屏幕/窗口布局 -> 创建该设备原生分辨率的虚拟屏 -> 切到「仅虚拟屏」；
    3) 你用平板 OPPO 互联「远程控制」连接，OPPO 从会话开始就抓到这块虚拟屏；
    4) 结束远控（或等待超时）后，Watcher 自动恢复「内屏 + 外接屏扩展」并清理。

  用法：
    pwsh -NoProfile -File scripts\Prepare-Remote.ps1 -Device Pad5Pro
    pwsh -NoProfile -File scripts\Prepare-Remote.ps1 -Cancel
    pwsh -NoProfile -File scripts\Prepare-Remote.ps1 -Status
#>

[CmdletBinding()]
param(
    [string]$Device = 'Pad5Pro',
    [switch]$Cancel,
    [switch]$Status,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$Dest = Join-Path $env:LOCALAPPDATA 'OPPO-ScreenFit'
$Flag = Join-Path $Dest 'PREARM.txt'

# 设备表唯一来源：ScreenFit.Core.ps1（与本脚本同目录）
$CorePath = Join-Path (Split-Path -Parent $PSCommandPath) 'ScreenFit.Core.ps1'
if (-not (Test-Path $CorePath)) { $CorePath = Join-Path $Dest 'ScreenFit.Core.ps1' }
if (Test-Path $CorePath) { . $CorePath; Initialize-ScreenFit -StateDir $env:TEMP }
$Catalog = if (Get-Command Get-DeviceCatalog -ErrorAction SilentlyContinue) { Get-DeviceCatalog } else { @() }

function Get-InstalledState {
    $stateFile = Join-Path $Dest 'logs\state.txt'
    if (Test-Path $stateFile) { return (Get-Content $stateFile -Raw).Trim() } else { return 'off' }
}

if ($Status) {
    Write-Host ('预建标记: ' + (Test-Path $Flag)) -ForegroundColor Cyan
    if (Test-Path $Flag) { Write-Host ('  目标设备: ' + (Get-Content $Flag -Raw).Trim()) }
    Write-Host ('Watcher 状态: ' + (Get-InstalledState))
    Write-Host ('版本: ' + (Get-Content (Join-Path $Dest 'version.txt') -Raw -ErrorAction SilentlyContinue))
    exit 0
}

if ($Cancel) {
    Remove-Item $Flag -Force -ErrorAction SilentlyContinue
    Write-Host '已取消预建；Watcher 会在 1~2 秒内恢复物理扩展布局。' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    Write-Host ('当前状态: ' + (Get-InstalledState))
    exit 0
}

if (-not (Test-Path $Dest)) {
    Write-Host ('安装目录不存在: ' + $Dest + '，请先安装插件。') -ForegroundColor Red
    exit 1
}

if ($List -or $Catalog.Count -eq 0) {
    Write-Host '可用设备（-Device 用 Key）：' -ForegroundColor Cyan
    foreach ($e in $Catalog) { Write-Host ("  " + $e.Key.PadRight(18) + $e.Label + "  " + $e.W + "x" + $e.H + $(if ($e.Verified) { '' } else { '  (规格未核实)' })) }
    if ($Catalog.Count -eq 0) { Write-Host '未找到设备表（ScreenFit.Core.ps1）' -ForegroundColor Red; exit 1 }
    exit 0
}

$prof = Get-DeviceProfile $Device
if (-not $prof) {
    Write-Host ("无法识别设备: " + $Device) -ForegroundColor Red
    Write-Host '可用 Key：' -ForegroundColor Yellow
    foreach ($e in $Catalog) { Write-Host ("  " + $e.Key.PadRight(18) + $e.Label) }
    exit 1
}
Set-Content -Path $Flag -Value $prof.Key -Encoding UTF8
Write-Host ('已请求预建屏: ' + $prof.Label + ' ' + $prof.W + 'x' + $prof.H) -ForegroundColor Green
Write-Host '等待 2 秒让 Watcher 建屏…' -ForegroundColor Yellow
Start-Sleep -Seconds 3
$state = Get-InstalledState
if ($state -eq 'prearmed') {
    Write-Host '预建屏已就绪：现在笔记本/外接屏会变黑，只剩这块平板分辨率的虚拟屏。' -ForegroundColor Green
    Write-Host '请现在用平板 OPPO 互联「远程控制」连接本机。' -ForegroundColor Green
    Write-Host '结束远控后会自动恢复；若要临时取消，运行本脚本 -Cancel。' -ForegroundColor DarkGray
} elseif ($state -eq 'on' -or $state -eq 'native') {
    Write-Host ('当前已处于会话状态（state=' + $state + '），无需预建。') -ForegroundColor Yellow
} else {
    Write-Host ('预建尚未生效（state=' + $state + '）。请确认计划任务在运行，或查看 ' + (Join-Path $Dest 'logs\watcher.log')) -ForegroundColor Yellow
}
