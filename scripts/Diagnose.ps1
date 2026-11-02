<#
  Diagnose.ps1 —— 只读诊断，不改任何设置。
  输出：当前显示器、OPPO 互联 会话/设备、最近编码分辨率、相关日志。
#>

$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSCommandPath
$OppLogDir = Join-Path $env:APPDATA 'O+Connect\devicespace'

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ScreenFitDiag {
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

function Section($t) { Write-Host ''; Write-Host "==== $t ====" -ForegroundColor Cyan }

Section '1. 当前显示器'
foreach ($i in 1..200) {
    $cur = [ScreenFitDiag]::Current("\\.\DISPLAY$i")
    if ($cur) { Write-Host ("DISPLAY{0} = {1}" -f $i, $cur) }
}

Section '2. OPPO 互联 会话与设备'
$main = Get-ChildItem (Join-Path $OppLogDir '*_main.log') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($main) {
    $lines = Get-Content $main.FullName -Tail 8000
    $start = -1; $stop = -1; $dev = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'start remote control:') {
            $start = $i
            $m = [regex]::Match($lines[$i], '"deviceName":"([^"]+)"')
            if ($m.Success) { $dev = $m.Groups[1].Value }
        } elseif ($lines[$i] -match 'stop remote control:') { $stop = $i }
    }
    Write-Host ("日志: " + $main.Name)
    Write-Host ("远程会话活动 = " + ($start -ge 0 -and $start -gt $stop))
    Write-Host ("当前/最近设备 = " + $dev)
}

Section '3. 最近编码分辨率'
$agent = Get-ChildItem (Join-Path $OppLogDir 'desktop_agent.*.log') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($agent) {
    Select-String -Path $agent.FullName -Pattern 'encoder init|Display changed|PRIMARY' |
        Select-Object -Last 8 | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
}

Section '4. 本项目日志'
foreach ($name in @('watcher.log', 'topo.log')) {
    $f = Join-Path $Root ("logs\\" + $name)
    if (Test-Path $f) {
        Write-Host ("--- " + $name)
        Get-Content $f -Tail 6 | ForEach-Object { Write-Host ('  ' + $_) }
    }
}
