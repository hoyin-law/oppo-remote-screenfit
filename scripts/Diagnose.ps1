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

Section '2. OPPO 互联 会话与观看端'
$main = Get-ChildItem (Join-Path $OppLogDir '*_main.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
# 与 Watcher 使用同一份检测逻辑（ScreenFit.Core.ps1），避免诊断结论和守护行为不一致
$corePath = Join-Path $Root 'ScreenFit.Core.ps1'
if (Test-Path $corePath) {
    . $corePath
    Initialize-ScreenFit -StateDir (Join-Path $Root 'logs')
    Write-Host ('ScreenFit 版本 = ' + (Get-ScreenFitVersion))
    $s = Get-Session
    Write-Host ('远程会话活动 = ' + $s.Active)
    Write-Host ('当前/最近设备 = ' + $s.Device)
    $v = Test-ViewerActive -WindowSeconds 30
    Write-Host ('观看端在消费画面 = ' + $v.Active + '（最近消费帧 ' + $v.SecondsSinceConsumed + ' 秒前，日志 ' + $v.LogName + '）')
    Write-Host '切屏条件：会话活动 且 观看端在消费画面；切屏后 60 秒无观看端会自动恢复原布局。'
} else {
    Write-Host ('⚠ 缺少 ' + $corePath + '，无法给出与守护一致的判定') -ForegroundColor Yellow
}
if ($main) {
    Write-Host ("最近主日志: " + $main.Name)
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
