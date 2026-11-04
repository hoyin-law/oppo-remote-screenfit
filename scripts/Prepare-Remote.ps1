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
    [ValidateSet(
        'Pad5Pro', 'Pad4Pro', 'Pad5', 'Pad3Pro', 'Pad3', 'PadMini', 'PadAir5', 'Pad6',
        'FindN6', 'FindN5', 'FindN3', 'FindN2',
        'OnePlusPad3Pro', 'OnePlusPad2Pro', 'OnePlusPadPro', 'OnePlusPad2', 'OnePlusPad', 'OnePlusPadGo',
        'Cancel', 'Status'
    )]
    [string]$Device = 'Pad5Pro'
)

$ErrorActionPreference = 'Stop'
$Dest = Join-Path $env:LOCALAPPDATA 'OPPO-ScreenFit'
$Flag = Join-Path $Dest 'PREARM.txt'

$Names = @{
    'Pad5Pro'        = 'OPPO Pad 5 Pro'
    'Pad4Pro'        = 'OPPO Pad 4 Pro'
    'Pad5'           = 'OPPO Pad 5'
    'Pad3Pro'        = 'OPPO Pad 3 Pro'
    'Pad3'           = 'OPPO Pad 3'
    'PadMini'        = 'OPPO Pad Mini'
    'PadAir5'        = 'OPPO Pad Air5'
    'Pad6'           = 'OPPO Pad 6'
    'FindN6'         = 'OPPO Find N6'
    'FindN5'         = 'OPPO Find N5'
    'FindN3'         = 'OPPO Find N3'
    'FindN2'         = 'OPPO Find N2'
    'OnePlusPad3Pro' = 'OnePlus Pad 3 Pro'
    'OnePlusPad2Pro' = 'OnePlus Pad 2 Pro'
    'OnePlusPadPro'  = 'OnePlus Pad Pro'
    'OnePlusPad2'    = 'OnePlus Pad 2'
    'OnePlusPad'     = 'OnePlus Pad'
    'OnePlusPadGo'   = 'OnePlus Pad Go'
}

function Get-InstalledState {
    $stateFile = Join-Path $Dest 'logs\state.txt'
    if (Test-Path $stateFile) { return (Get-Content $stateFile -Raw).Trim() } else { return 'off' }
}

if ($Device -eq 'Status') {
    Write-Host ('预建标记: ' + (Test-Path $Flag)) -ForegroundColor Cyan
    if (Test-Path $Flag) { Write-Host ('  目标设备: ' + (Get-Content $Flag -Raw).Trim()) }
    Write-Host ('Watcher 状态: ' + (Get-InstalledState))
    Write-Host ('版本: ' + (Get-Content (Join-Path $Dest 'version.txt') -Raw -ErrorAction SilentlyContinue))
    exit 0
}

if ($Device -eq 'Cancel') {
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

$name = $Names[$Device]
Set-Content -Path $Flag -Value $name -Encoding UTF8
Write-Host ('已请求预建屏: ' + $name) -ForegroundColor Green
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
