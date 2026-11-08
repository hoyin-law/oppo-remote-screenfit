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
    [string]$Device = 'Pad5Pro',
    [switch]$KeepWindow,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$Tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
$cfgTool = Get-ScreenFitSetting 'VirtualDisplayTool'; if ($cfgTool) { $Tool = [string]$cfgTool }

# 设备表唯一来源：ScreenFit.Core.ps1
$CorePath = Join-Path (Split-Path -Parent $PSCommandPath) 'ScreenFit.Core.ps1'
if (-not (Test-Path $CorePath)) { $CorePath = Join-Path $env:LOCALAPPDATA 'OPPO-ScreenFit\ScreenFit.Core.ps1' }
if (Test-Path $CorePath) { . $CorePath; Initialize-ScreenFit -StateDir $env:TEMP }
$Catalog = if (Get-Command Get-DeviceCatalog -ErrorAction SilentlyContinue) { Get-DeviceCatalog } else { @() }
$Profiles = @{}
foreach ($e in $Catalog) { $Profiles[$e.Key] = @{ W = $e.W; H = $e.H; Label = $e.Label } }
if ($List) {
    foreach ($e in $Catalog) { Write-Host ("  " + $e.Key.PadRight(18) + $e.Label + "  " + $e.W + "x" + $e.H + $(if ($e.Verified) { '' } else { '  (规格未核实)' })) }
    exit 0
}
if ($Device -notin @('Off', 'Status') -and -not $Profiles.ContainsKey($Device)) {
    Write-Host ("无法识别设备: " + $Device) -ForegroundColor Red
    Write-Host ('可用 Key: ' + (($Profiles.Keys | Sort-Object) -join ', ')) -ForegroundColor Yellow
    exit 1
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
