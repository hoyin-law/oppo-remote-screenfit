<#
  Watcher.ps1 —— 由计划任务以最高权限运行。
  作用：检测 OPPO 互联 的「远程控制」会话，在会话开始时为平板/折叠屏创建对应分辨率的虚拟屏，
        会话结束宽限 90 秒后拆除。显示拓扑切换由 TopologyGuard.ps1（用户级）负责。
  触发依据（读取 OPPO 互联 自己的日志，不注入进程）：
    start remote control: {... "deviceName":"OPPO Find N6" ...}
    stop  remote control: {...}
#>

$ErrorActionPreference = 'SilentlyContinue'
if (Test-Path (Join-Path (Split-Path -Parent $PSCommandPath) 'STOP.txt')) { exit }

$Root = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'watcher.log'
$StateFile = Join-Path $LogDir 'state.txt'
$OppLogDir = Join-Path $env:APPDATA 'O+Connect\devicespace'
$Tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
$PollSec = 2
$GraceSec = 90

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ScreenFitDisplay {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool EnumDisplaySettings(string d, int m, ref DEVMODE dm);
  public static string All() {
    string s = "";
    for (int i = 1; i <= 200; i++) {
      string dev = "\\\\.\\DISPLAY" + i;
      var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (EnumDisplaySettings(dev, -1, ref dm)) s += "DISPLAY" + i + "=" + dm.dmPelsWidth + "x" + dm.dmPelsHeight + ";";
    }
    return s;
  }
}
'@

function Write-Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-RemoteSession {
    $main = Get-ChildItem (Join-Path $OppLogDir '*_main.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $main) { return @{ Active = $false; Device = $null } }
    $lines = Get-Content $main.FullName -Tail 8000
    $lastStart = -1; $lastStop = -1; $dev = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'start remote control:') {
            $lastStart = $i
            $m = [regex]::Match($lines[$i], '"deviceName":"([^"]+)"')
            if ($m.Success) { $dev = $m.Groups[1].Value }
        } elseif ($lines[$i] -match 'stop remote control:') { $lastStop = $i }
    }
    return @{ Active = ($lastStart -ge 0 -and $lastStart -gt $lastStop); Device = $dev }
}

function Get-TargetSize($dev) {
    if ($dev -like '*Find N6*')   { return @{ W = 2480; H = 2248 } }
    if ($dev -like '*Pad 5 Pro*') { return @{ W = 3392; H = 2400 } }
    return $null
}

function Remove-VirtualDisplay {
    Get-Process OPDisplayDriverTool -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    & pnputil /remove-device "SWD\OPDISPLAYDRIVER\OPDISPLAYDRIVER" 2>$null | Out-Null
    Start-Sleep -Seconds 3
}

function Test-Resolution($w, $h) { return ([ScreenFitDisplay]::All() -match ("{0}x{1}" -f $w, $h)) }

function New-VirtualDisplay($w, $h) {
    $out = Join-Path $LogDir ("tool_{0}.out" -f (Get-Date -Format 'HHmmssfff'))
    Start-Process -FilePath $Tool -ArgumentList @('--operation','create','--width',"$w",'--height',"$h",'--freq','60') `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err" | Out-Null
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Resolution $w $h) { return $true }
        if ((Get-Content $out -Raw -ErrorAction SilentlyContinue) -match 'CreateSuccess') {
            Start-Sleep -Seconds 2
            if (Test-Resolution $w $h) { return $true }
        }
    }
    Write-Log ('   建屏失败，工具输出: ' + ((Get-Content $out -Tail 8 -ErrorAction SilentlyContinue) -join ' | '))
    return $false
}

function Get-State { if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { 'off' } }
function Set-State($s) { Set-Content -Path $StateFile -Value $s -Encoding UTF8 }

Write-Log 'watcher 启动（远程会话触发）'
$lastActive = Get-Date
if ((Get-State) -eq 'on') {
    $s0 = Get-RemoteSession
    if (-not $s0.Active) { Write-Log '启动清理：上次遗留'; Remove-VirtualDisplay; Set-State 'off'; $lastActive = Get-Date }
}

$lastTry = [datetime]::MinValue
while ($true) {
    $s = Get-RemoteSession
    if ($s.Active) {
        $lastActive = Get-Date
        $t = Get-TargetSize $s.Device
        if ($t) {
            if (-not (Test-Resolution $t.W $t.H)) {
                if (((Get-Date) - $lastTry).TotalSeconds -ge 30) {
                    $lastTry = Get-Date
                    Write-Log ('远程会话开始 -> 建屏 ' + $s.Device + ' ' + $t.W + 'x' + $t.H + '（当前: ' + [ScreenFitDisplay]::All() + '）')
                    Remove-VirtualDisplay
                    if (-not (New-VirtualDisplay $t.W $t.H)) {
                        Write-Log '   第一次失败，重试'; Remove-VirtualDisplay; New-VirtualDisplay $t.W $t.H | Out-Null
                    }
                }
            }
            if ((Get-State) -ne 'on' -and (Test-Resolution $t.W $t.H)) { Set-State 'on'; Write-Log ('虚拟屏就绪: ' + [ScreenFitDisplay]::All()) }
        }
    } else {
        if ((Get-State) -eq 'on' -and ((Get-Date) - $lastActive).TotalSeconds -ge $GraceSec) {
            Write-Log '远程结束满 90 秒 -> 拆虚拟屏'
            Remove-VirtualDisplay
            Set-State 'off'
        }
    }
    Start-Sleep -Seconds $PollSec
}
