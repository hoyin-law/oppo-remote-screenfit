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

$DeviceMap = @(
    @{ Match = @('Pad 5 Pro');    W = 3392; H = 2400; Label = 'OPPO Pad 5 Pro' },
    @{ Match = @('Pad 4 Pro');    W = 3392; H = 2400; Label = 'OPPO Pad 4 Pro' },
    @{ Match = @('Pad 3 Pro');    W = 3000; H = 2120; Label = 'OPPO Pad 3 Pro' },
    @{ Match = @('Pad 5');        W = 3000; H = 2120; Label = 'OPPO Pad 5' },
    @{ Match = @('Pad 3');        W = 2800; H = 2000; Label = 'OPPO Pad 3' },
    @{ Match = @('Pad mini', 'Pad Mini'); W = 2520; H = 1680; Label = 'OPPO Pad Mini' },
    @{ Match = @('Pad Air5');     W = 2800; H = 1980; Label = 'OPPO Pad Air5' },
    @{ Match = @('Find N6');      W = 2480; H = 2248; Label = 'OPPO Find N6 (inner)' },
    @{ Match = @('OnePlus Pad 3 Pro', '一加平板 3 Pro'); W = 3392; H = 2400; Label = 'OnePlus Pad 3 Pro' },
    @{ Match = @('OnePlus Pad 2 Pro', '一加平板 2 Pro'); W = 3392; H = 2400; Label = 'OnePlus Pad 2 Pro' },
    @{ Match = @('OnePlus Pad Pro', '一加平板 Pro');     W = 3000; H = 2120; Label = 'OnePlus Pad Pro' },
    @{ Match = @('OnePlus Pad 2', '一加平板 2');         W = 3000; H = 2120; Label = 'OnePlus Pad 2' },
    @{ Match = @('OnePlus Pad', '一加平板');             W = 2800; H = 2000; Label = 'OnePlus Pad' }
)

# 可选扩展：在 scripts\devices.json 里追加设备（数组，元素形如
# {"match":["Pad 6"],"w":3000,"h":2120,"label":"OPPO Pad 6"}）
$DeviceCfg = Join-Path $Root 'devices.json'
if (Test-Path $DeviceCfg) {
    try {
        $extra = Get-Content $DeviceCfg -Raw | ConvertFrom-Json
        foreach ($e in $extra) {
            $DeviceMap = @(@{ Match = @($e.match); W = [int]$e.w; H = [int]$e.h; Label = "$($e.label)" }) + $DeviceMap
        }
    } catch { Write-Log ('devices.json 解析失败: ' + $_.Exception.Message) }
}

function Get-TargetSize($dev) {
    foreach ($entry in $DeviceMap) {
        foreach ($pat in $entry.Match) {
            if ($dev -like "*$pat*") { return @{ W = $entry.W; H = $entry.H; Label = $entry.Label } }
        }
    }
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


# ---- 显示拓扑切换（合并进 watcher，单进程负责建屏 + 切屏）----
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ScreenFitTopo {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct RAT { public uint N; public uint D; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public RAT refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC sourceInfo; public TGT targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct MODE { public uint infoType; public uint id; public LUID adapterId; public uint a,b,c,d,e,f,g,h,i,j; }
  [StructLayout(LayoutKind.Sequential)] public struct HDR { public uint type; public uint size; public LUID adapterId; public uint id; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TDN {
    public HDR header; public uint flags; public uint outputTechnology; public ushort mfg; public ushort prod; public uint connector;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string name;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, PATH[] p, uint nm, MODE[] m, uint f);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TDN n);
  const uint QDC_ALL = 1, USE = 0x20, APPLY = 0x80, INTERNAL = 0x1, INVALID = 0xFFFFFFFF;
  static string Name(PATH p) {
    var n = new TDN(); n.header.type = 2; n.header.size = (uint)Marshal.SizeOf(typeof(TDN));
    n.header.adapterId = p.targetInfo.adapterId; n.header.id = p.targetInfo.id;
    if (DisplayConfigGetDeviceInfo(ref n) == 0) return n.name + "|" + n.path; return "";
  }
  static PATH[] Query() {
    uint np, nm; int e = GetDisplayConfigBufferSizes(QDC_ALL, out np, out nm); if (e != 0) throw new Exception("buf=" + e);
    var p = new PATH[np]; var m = new MODE[nm];
    e = QueryDisplayConfig(QDC_ALL, ref np, p, ref nm, m, IntPtr.Zero); if (e != 0) throw new Exception("query=" + e);
    var r = new PATH[np]; Array.Copy(p, r, np); return r;
  }
  public static string OnlyVirtual() {
    var all = Query(); PATH pick = new PATH(); bool found = false;
    foreach (var p in all) {
      var n = Name(p);
      if (n.IndexOf("OPExtScreen", StringComparison.OrdinalIgnoreCase) >= 0 ||
          n.IndexOf("OPDisplayDriver", StringComparison.OrdinalIgnoreCase) >= 0 ||
          n.IndexOf("DELD0E6", StringComparison.OrdinalIgnoreCase) >= 0) {
        if (!found || p.flags != 0) { pick = p; found = true; if (p.flags != 0) break; }
      }
    }
    if (!found) return "no-match";
    pick.sourceInfo.modeInfoIdx = INVALID; pick.targetInfo.modeInfoIdx = INVALID;
    return "err=" + SetDisplayConfig(1, new PATH[] { pick }, 0, null, USE | APPLY);
  }
  public static string OnlyInternal() {
    return "err=" + SetDisplayConfig(0, null, 0, null, APPLY | INTERNAL);
  }
}
'@

$topoState = ''
function Set-OnlyVirtual {
    if ($script:topoState -eq 'virtual') { return }
    $r = [ScreenFitTopo]::OnlyVirtual()
    if ($r -eq 'err=0') { Write-Log "切到仅在虚拟屏: $r"; $script:topoState = 'virtual' }
    elseif ($r -ne 'no-match') { Write-Log "切虚拟屏失败: $r（下轮重试）" }
}
function Set-OnlyInternal {
    if ($script:topoState -eq 'internal') { return }
    $r = [ScreenFitTopo]::OnlyInternal()
    if ($r -eq 'err=0') { Write-Log "恢复仅内屏: $r"; $script:topoState = 'internal' }
}

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
            if (Test-Resolution $t.W $t.H) { Set-OnlyVirtual }
        }
    } else {
        if ((Get-State) -eq 'on') { Set-OnlyInternal }
        if ((Get-State) -eq 'on' -and ((Get-Date) - $lastActive).TotalSeconds -ge $GraceSec) {
            Write-Log '远程结束满 90 秒 -> 拆虚拟屏'
            Remove-VirtualDisplay
            Set-State 'off'; $topoState = ''
        }
    }
    Start-Sleep -Seconds $PollSec
}

