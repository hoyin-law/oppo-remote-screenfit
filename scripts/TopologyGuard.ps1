<#
  TopologyGuard.ps1 —— 用户级（无需管理员），随登录自启。
  作用：检测到「远程控制」会话进行中时，把显示切到「仅在虚拟屏」；
        会话结束后 10 秒切回「仅内屏」。虚拟屏的建/拆由 Watcher.ps1（管理员任务）负责。
#>

$ErrorActionPreference = 'SilentlyContinue'
if (Test-Path (Join-Path (Split-Path -Parent $PSCommandPath) 'STOP.txt')) { exit }

$Root = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'topo.log'
$OppLogDir = Join-Path $env:APPDATA 'O+Connect\devicespace'
$VirtualResolutions = @('3392x2400', '2480x2248', '2616x1140')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ScreenFitTopology {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint N; public uint D; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT {
    public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology;
    public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering;
    public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC sourceInfo; public TGT targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct MODE { public uint infoType; public uint id; public LUID adapterId; public uint a,b,c,d,e,f,g,h,i,j; }
  [StructLayout(LayoutKind.Sequential)] public struct HDR { public uint type; public uint size; public LUID adapterId; public uint id; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TDN {
    public HDR header; public uint flags; public uint outputTechnology; public ushort mfg; public ushort prod; public uint connector;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string name;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }

  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, PATH[] p, uint nm, MODE[] m, uint f);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TDN n);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool EnumDisplaySettings(string d, int m, ref DEVMODE dm);

  const uint QDC_ALL = 1, USE = 0x20, APPLY = 0x80, INTERNAL = 0x1, INVALID = 0xFFFFFFFF;

  static string TargetName(PATH p) {
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
    var all = Query();
    PATH pick = new PATH(); bool found = false;
    foreach (var p in all) {
      var n = TargetName(p);
      if (n.IndexOf("OPExtScreen", StringComparison.OrdinalIgnoreCase) >= 0 ||
          n.IndexOf("OPDisplayDriver", StringComparison.OrdinalIgnoreCase) >= 0 ||
          n.IndexOf("DELD0E6", StringComparison.OrdinalIgnoreCase) >= 0) {
        if (!found || p.flags != 0) { pick = p; found = true; if (p.flags != 0) break; }
      }
    }
    if (!found) return "no-match";
    pick.sourceInfo.modeInfoIdx = INVALID; pick.targetInfo.modeInfoIdx = INVALID;
    var arr = new PATH[] { pick };
    int err = SetDisplayConfig(1, arr, 0, null, USE | APPLY);
    return "err=" + err;
  }
  public static string OnlyInternal() {
    int err = SetDisplayConfig(0, null, 0, null, APPLY | INTERNAL);
    return "err=" + err;
  }
  public static string Mode(string dev) {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (EnumDisplaySettings(dev, -1, ref dm)) return dm.dmPelsWidth + "x" + dm.dmPelsHeight;
    return "";
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
    if (-not $main) { return @{ Active = $false } }
    $lines = Get-Content $main.FullName -Tail 8000
    $start = -1; $stop = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'start remote control:') { $start = $i }
        elseif ($lines[$i] -match 'stop remote control:') { $stop = $i }
    }
    return @{ Active = ($start -ge 0 -and $start -gt $stop) }
}

function Get-Screens {
    $r = @()
    foreach ($i in 1..200) {
        $res = [ScreenFitTopology]::Mode("\\.\DISPLAY$i")
        if ($res) { $r += [pscustomobject]@{ Dev = "DISPLAY$i"; Res = $res } }
    }
    return $r
}

Write-Log 'topology guard 启动（远程会话触发）'
$activeSince = $null
$inactiveSince = Get-Date
$lastAction = ''
while ($true) {
    try {
        $sess = Get-RemoteSession
        $screens = Get-Screens
        $virtual = @($screens | Where-Object { $VirtualResolutions -contains $_.Res })
        $onlyVirtual = ($screens.Count -eq 1 -and $virtual.Count -eq 1)

        if ($sess.Active) {
            $inactiveSince = $null
            if (-not $activeSince) { $activeSince = Get-Date }
            if (((Get-Date) - $activeSince).TotalSeconds -ge 2 -and $virtual.Count -gt 0 -and -not $onlyVirtual) {
                $r = [ScreenFitTopology]::OnlyVirtual()
                if ($r -ne $lastAction) { Write-Log ("切换到仅虚拟屏: $r（屏幕: " + (($screens | ForEach-Object { $_.Dev + '=' + $_.Res }) -join ', ') + '）'); $lastAction = $r }
            }
        } else {
            $activeSince = $null
            if (-not $inactiveSince) { $inactiveSince = Get-Date }
            if (((Get-Date) - $inactiveSince).TotalSeconds -ge 10 -and $onlyVirtual) {
                $r = [ScreenFitTopology]::OnlyInternal()
                if ($r -ne $lastAction) { Write-Log "恢复仅内屏: $r"; $lastAction = $r }
            }
        }
    } catch { Write-Log ("ERROR: " + $_.Exception.Message) }
    Start-Sleep -Seconds 2
}
