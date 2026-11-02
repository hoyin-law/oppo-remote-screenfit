<#
  Uninstall.ps1 —— 一键卸载（会自动请求一次 UAC）。
  停止并删除任务、停止守护、移除自启、拆除虚拟屏、恢复「仅内屏」、删除安装目录。
#>

$ErrorActionPreference = 'SilentlyContinue'

$Dest = Join-Path $env:LOCALAPPDATA 'OPPO-ScreenFit'
$TaskNames = @('OPPO平板分辨率适配', 'OPPO平板自动适配')

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Start-Process 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit 0
}

Write-Host '停止并删除计划任务…'
foreach ($tn in $TaskNames) {
    Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host '停止守护进程并移除自启…'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Watcher\.ps1|TopologyGuard\.ps1|watcher-run\.ps1|拓扑守护\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OPPO平板拓扑守护' -ErrorAction SilentlyContinue

Write-Host '拆除虚拟屏…'
$tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
if (Test-Path $tool) {
    Start-Process -FilePath $tool -ArgumentList @('--operation','remove') -WindowStyle Hidden -Wait
    Start-Sleep -Seconds 2
    & pnputil /remove-device "SWD\OPDISPLAYDRIVER\OPDISPLAYDRIVER" 2>$null | Out-Null
    Start-Sleep -Seconds 2
}

Write-Host '恢复「仅内屏」…'
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ScreenFitRestore {
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint n, IntPtr p, uint m, IntPtr mo, uint flags);
  public static int InternalOnly() { return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, 0x1 | 0x80); }
}
'@
[ScreenFitRestore]::InternalOnly() | Out-Null

Write-Host '删除安装目录…'
Remove-Item $Dest -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '✅ 已卸载。若屏幕未回到「仅电脑屏幕」，按 Win+P 选一次即可。' -ForegroundColor Green
Start-Sleep -Seconds 2
