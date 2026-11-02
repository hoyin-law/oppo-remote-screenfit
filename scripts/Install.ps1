<#
  Install.ps1 —— 一键安装（会请求一次 UAC）。
  做的事情：
    1) 注册计划任务「OPPO 平板分辨率适配」，登录时以最高权限运行 Watcher.ps1；
    2) 注册 HKCU Run，登录时启动 TopologyGuard.ps1（用户级，无需管理员）；
    3) 立即启动两者。
  卸载请运行 Uninstall.ps1。
#>

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$TaskName = 'OPPO平板分辨率适配'

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

$tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
if (-not (Test-Path $tool)) {
    Write-Host "⚠ 未找到 OPPO 虚拟显示器工具：$tool" -ForegroundColor Yellow
    Write-Host '  请先打开一次 OPPO 互联（或使用一次它的「屏幕扩展」）让组件解压，再重新运行安装。'
}

Write-Host '1/3 注册计划任务（登录自启、最高权限）'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Root 'Watcher.ps1')
)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host '2/3 注册 TopologyGuard 登录自启'
$runValue = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Root 'TopologyGuard.ps1')
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OPPO平板拓扑守护' -Value $runValue

Write-Host '3/3 启动'
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Watcher.ps1|TopologyGuard.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-ScheduledTask -TaskName $TaskName
Start-Process 'powershell.exe' -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'TopologyGuard.ps1'))

Write-Host ''
Write-Host '✅ 安装完成。' -ForegroundColor Green
Write-Host '   - 平时：两个守护只读日志，不动显示；'
Write-Host '   - 远程连接开始：自动建对应分辨率的虚拟屏并切换；'
Write-Host '   - 远程结束：10 秒回内屏，90 秒后拆除虚拟屏。'
Write-Host ''
Write-Host '日志目录：' (Join-Path $Root 'logs')
Write-Host '如需彻底关闭：在 scripts 目录新建 STOP.txt，或运行 Uninstall.ps1。'
