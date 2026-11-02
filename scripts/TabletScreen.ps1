<#
  TabletScreen.ps1 —— 手动建/拆平板分辨率虚拟屏（不依赖自动逻辑）。
  用法：
    .\TabletScreen.ps1 -Device Pad5Pro
    .\TabletScreen.ps1 -Device FindN6
    .\TabletScreen.ps1 -Device PadMini
    .\TabletScreen.ps1 -Device Off
    .\TabletScreen.ps1 -Status
  需要管理员权限（会自动请求 UAC）。
#>

[CmdletBinding()]
param(
    [ValidateSet(
        'Pad5Pro', 'Pad4Pro', 'Pad5', 'Pad3Pro', 'Pad3', 'PadMini', 'PadAir5',
        'FindN6',
        'OnePlusPad3Pro', 'OnePlusPad2Pro', 'OnePlusPadPro', 'OnePlusPad2', 'OnePlusPad',
        'Off', 'Status'
    )]
    [string]$Device = 'Pad5Pro',
    [switch]$KeepWindow
)

$ErrorActionPreference = 'Stop'
$Tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'

$Profiles = @{
    'Pad5Pro'         = @{ W = 3392; H = 2400; Label = 'OPPO Pad 5 Pro (13.2" 3392x2400)' }
    'Pad4Pro'         = @{ W = 3392; H = 2400; Label = 'OPPO Pad 4 Pro (13.2" 3392x2400)' }
    'Pad5'            = @{ W = 3000; H = 2120; Label = 'OPPO Pad 5 (12.1" 3000x2120)' }
    'Pad3Pro'         = @{ W = 3000; H = 2120; Label = 'OPPO Pad 3 Pro (12.1" 3000x2120)' }
    'Pad3'            = @{ W = 2800; H = 2000; Label = 'OPPO Pad 3 (11.61" 2800x2000)' }
    'PadMini'         = @{ W = 2520; H = 1680; Label = 'OPPO Pad Mini (8.8" 2520x1680)' }
    'PadAir5'         = @{ W = 2800; H = 1980; Label = 'OPPO Pad Air5 (12.1" 2800x1980)' }
    'FindN6'          = @{ W = 2480; H = 2248; Label = 'OPPO Find N6 内屏 (2480x2248)' }
    'OnePlusPad3Pro'  = @{ W = 3392; H = 2400; Label = 'OnePlus Pad 3 Pro (13.2" 3392x2400)' }
    'OnePlusPad2Pro'  = @{ W = 3392; H = 2400; Label = 'OnePlus Pad 2 Pro (13.2" 3392x2400)' }
    'OnePlusPadPro'   = @{ W = 3000; H = 2120; Label = 'OnePlus Pad Pro (12.1" 3000x2120)' }
    'OnePlusPad2'     = @{ W = 3000; H = 2120; Label = 'OnePlus Pad 2 (12.1" 3000x2120)' }
    'OnePlusPad'      = @{ W = 2800; H = 2000; Label = 'OnePlus Pad (11.61" 2800x2000)' }
}

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ScreenFitModes {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool EnumDisplaySettings(string d, int m, ref DEVMODE dm);
  public static string Current(string dev) {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (EnumDisplaySettings(dev, -1, ref dm)) return dm.dmPelsWidth + "x" + dm.dmPelsHeight + " pos(" + dm.dmPositionX + "," + dm.dmPositionY + ")";
    return "";
  }
}
'@

function Get-Monitors {
    $list = @()
    foreach ($i in 1..200) {
        $cur = [ScreenFitModes]::Current("\\.\DISPLAY$i")
        if ($cur) { $list += "DISPLAY$i = $cur" }
    }
    return $list
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Device -eq 'Status') {
    Write-Host '=== 当前活动显示 ===' -ForegroundColor Cyan
    Get-Monitors
    exit 0
}

if (-not (Test-Path $Tool)) {
    Write-Host "找不到 OPPO 虚拟显示器工具：$Tool" -ForegroundColor Red
    Write-Host '请先启动一次 OPPO 互联 的「屏幕扩展」功能，让它解压组件后再试。' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限来创建/删除虚拟显示器，正在请求提权…' -ForegroundColor Yellow
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Device', $Device)
    if ($KeepWindow) { $args += '-KeepWindow' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args | Out-Null }
    catch { Write-Host '提权被取消。' -ForegroundColor Red }
    exit 0
}

if ($Device -eq 'Off') {
    Write-Host '正在移除虚拟显示器…' -ForegroundColor Yellow
    Start-Process -FilePath $Tool -ArgumentList @('--operation','remove') -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 3
    & pnputil /remove-device "SWD\OPDISPLAYDRIVER\OPDISPLAYDRIVER" 2>$null | Out-Null
    Write-Host '完成。若屏幕未恢复，按 Win+P → 仅电脑屏幕。' -ForegroundColor Green
    Get-Monitors
    exit 0
}

$p = $Profiles[$Device]
Write-Host ("正在创建虚拟屏: " + $p.Label) -ForegroundColor Cyan
Get-Process OPDisplayDriverTool -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Start-Process -FilePath $Tool -ArgumentList @('--operation','create','--width',"$($p.W)",'--height',"$($p.H)",'--freq','60') -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 8
Write-Host '=== 当前活动显示 ===' -ForegroundColor Cyan
Get-Monitors
Write-Host ''
Write-Host '提示：到 Windows「设置 → 系统 → 显示」选中该虚拟屏，缩放建议 200%（只需一次，之后会记住）。' -ForegroundColor DarkGray
if ($KeepWindow) { Read-Host '按回车退出' | Out-Null }
