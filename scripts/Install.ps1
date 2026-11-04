<#
  Install.ps1 —— 一键安装（会自动请求一次 UAC）。
  做四件事：
    1) 把运行所需的脚本复制到 %LOCALAPPDATA%\OPPO-ScreenFit；
    2) 清理旧版本遗留（旧任务名、旧守护进程、旧登录自启）；
    3) 注册计划任务（登录自启、最高权限）；
    4) 立即启动。
  卸载请运行 Uninstall.ps1 或「一键卸载.cmd」。
#>

$ErrorActionPreference = 'Stop'

$Src = Split-Path -Parent $PSCommandPath
$Dest = Join-Path $env:LOCALAPPDATA 'OPPO-ScreenFit'
$TaskName = 'OPPO平板分辨率适配'
$LegacyTask = 'OPPO平板自动适配'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权…' -ForegroundColor Yellow
    Start-Process 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit 0
}

Write-Host '1/4 复制程序文件到固定目录'
New-Item -ItemType Directory -Force $Dest | Out-Null
foreach ($f in @('Watcher.ps1', 'ScreenFit.Core.ps1', 'TabletScreen.ps1', 'Diagnose.ps1', 'Uninstall.ps1')) {
    $p = Join-Path $Src $f
    if (Test-Path $p) { Copy-Item $p $Dest -Force }
}
if (Test-Path (Join-Path $Src 'devices.json')) { Copy-Item (Join-Path $Src 'devices.json') $Dest -Force }

# 版本号：候选位置 = Src、Src 的上一级（Release 包根）、当前仓库根
$verFile = $null
foreach ($cand in @((Join-Path $Src 'VERSION'), (Join-Path (Split-Path -Parent $Src) 'VERSION'), 'VERSION')) {
    if ($cand -and (Test-Path $cand)) { $verFile = $cand; break }
}
if ($verFile) {
    $ver = (Get-Content $verFile -Raw).Trim()
    Set-Content -Path (Join-Path $Dest 'version.txt') -Value $ver -Encoding UTF8
    Write-Host ("   版本：" + $ver)
} else {
    Write-Host '   ⚠ 未找到 VERSION 文件，安装副本将没有版本标识' -ForegroundColor Yellow
}

# 临时关闭标记会让 Watcher 启动即退出；升级/重装时必须显式处理，不能静默失效
$stopFile = Join-Path $Dest 'STOP.txt'
if (Test-Path $stopFile) {
    $bak = Join-Path $Dest ("STOP.txt.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item $stopFile $bak -Force -ErrorAction SilentlyContinue
    Write-Host ("⚠ 检测到临时关闭标记 STOP.txt，已备份为 " + (Split-Path -Leaf $bak) + "，本次安装会重新启用。") -ForegroundColor Yellow
}

$tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
if (-not (Test-Path $tool)) {
    Write-Host "⚠ 未找到 OPPO 虚拟显示器工具：$tool" -ForegroundColor Yellow
    Write-Host '  请先安装并打开一次 OPPO 互联（或用一次它的「屏幕扩展」）让组件解压，再重新运行安装。'
    Write-Host '  安装会继续，但功能要等该工具出现后才能使用。'
}

Write-Host '2/4 清理旧版本遗留'
foreach ($tn in @($TaskName, $LegacyTask)) {
    Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Watcher\.ps1|TopologyGuard\.ps1|watcher-run\.ps1|拓扑守护\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OPPO平板拓扑守护' -ErrorAction SilentlyContinue

Write-Host '3/4 注册计划任务（登录自启、最高权限）'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Dest 'Watcher.ps1')
)
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
# 每 5 分钟检查一次（任务已在跑时 IgnoreNew 不会重复启动）；任务被异常终止后能自动恢复
$triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($triggerLogon, $triggerRepeat) -Principal $principal -Settings $settings -Force | Out-Null

Write-Host '4/4 启动'
Start-ScheduledTask -TaskName $TaskName

Write-Host ''
Write-Host '✅ 安装完成。' -ForegroundColor Green
Write-Host '   - 平时：守护只读日志，不动显示；'
Write-Host '   - 远程连接开始且确有观看端在消费画面：自动建对应分辨率的虚拟屏，并切换为「仅在虚拟屏上显示」；'
Write-Host '   - 切屏后连续 60 秒没有观看端：自动恢复原布局（不会再锁死物理屏）；'
Write-Host '   - 远程结束：按连接前快照恢复屏幕布局与窗口位置，随后拆除虚拟屏。'
Write-Host ''
Write-Host ('安装目录：' + $Dest)
Write-Host ('日志目录：' + (Join-Path $Dest 'logs'))
Write-Host '如需临时关闭：在安装目录新建 STOP.txt（或用「一键卸载.cmd」）。'
Start-Sleep -Seconds 2
