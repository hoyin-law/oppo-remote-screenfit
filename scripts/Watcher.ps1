<#
  Watcher.ps1 —— OPPO 互联 远程控制屏幕自适应（由计划任务以最高权限运行，登录自启）。

  行为：
    - 只在检测到 OPPO 互联「远程控制」会话开始时才建虚拟屏并切换；
    - 设备普通连接/断开不会自动切换屏幕（避免日常打扰）；
    - 远程开始时保存“连接前”的屏幕布局（扩展/复制/仅某屏），退出时原样恢复；
    - 切换后校验确实只剩一块活动屏，失败自动重试/重建。
#>


$ErrorActionPreference = 'SilentlyContinue'
if (Test-Path (Join-Path (Split-Path -Parent $PSCommandPath) 'STOP.txt')) { exit }

$Root = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'watcher.log'
$StateFile = Join-Path $LogDir 'state.txt'
$Tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
$PollSec = 1
$GraceSec = 90
$SnapshotFile = Join-Path $LogDir 'topology.snapshot'

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class WR3 {
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

function WLog($m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-Session {
    # 读最近两个 main 日志：OPPO 每天 0 点轮转日志，只读最新文件会丢掉跨零点的会话开始事件
    $dir = Join-Path $env:APPDATA 'O+Connect\devicespace'
    $files = Get-ChildItem (Join-Path $dir '*_main.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 2
    if (-not $files) { return @{ Active = $false; Device = $null; StartTs = $null } }

    $lines = @()
    foreach ($f in ($files | Sort-Object LastWriteTime)) {
        $lines += Get-Content $f.FullName -Tail 4000 -ErrorAction SilentlyContinue
    }

    $lastStart = -1; $lastStop = -1; $dev = $null; $startTs = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match 'start remote control:') {
            $lastStart = $i
            $m = [regex]::Match($l, '"deviceName":"([^"]+)"')
            if ($m.Success) { $dev = $m.Groups[1].Value }
            if ($l -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { $startTs = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) }
        } elseif ($l -match 'stop remote control:') { $lastStop = $i }
    }
    $active = ($lastStart -ge 0 -and $lastStart -gt $lastStop)

    if ($active -and -not $dev) {
        $devFile = Join-Path $LogDir 'last-device.txt'
        if (Test-Path $devFile) { $dev = (Get-Content $devFile -Raw -ErrorAction SilentlyContinue).Trim() }
    }

    # 兜底：日志轮转后可能读不到 start，但心跳仍在（说明会话语义上还活着）
    if (-not $active) {
        $ackAge = 9999
        $newest = $files[0]
        $tail = Get-Content $newest.FullName -Tail 400 -ErrorAction SilentlyContinue
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            if ($tail[$i] -match 'ws\.heartbeat\.ack') {
                if ($tail[$i] -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                    try { $ackAge = ((Get-Date) - [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null)).TotalSeconds } catch { }
                }
                break
            }
        }
        $devFile = Join-Path $LogDir 'last-device.txt'
        if ($ackAge -lt 90 -and (Test-Path $devFile)) {
            $dev = (Get-Content $devFile -Raw -ErrorAction SilentlyContinue).Trim()
            $active = $true
            $startTs = $null
        }
    }

    return @{ Active = $active; Device = $dev; StartTs = $startTs }
}

function Get-RemoteLiveness {
    $agentAge = 9999
    $a = Get-ChildItem (Join-Path $env:APPDATA 'O+Connect\devicespace\desktop_agent.*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($a) { $agentAge = ((Get-Date) - $a.LastWriteTime).TotalSeconds }

    $ackAge = 9999
    $m = Get-ChildItem (Join-Path $env:APPDATA 'O+Connect\devicespace\*_main.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($m) {
        $lines = Get-Content $m.FullName -Tail 400 -ErrorAction SilentlyContinue
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match 'ws\.heartbeat\.ack') {
                if ($lines[$i] -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                    try { $ackAge = ((Get-Date) - [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null)).TotalSeconds } catch { }
                }
                break
            }
        }
    }
    return @{ AgentAge = $agentAge; AckAge = $ackAge }
}

$DeviceMap = @(
    @{ Match = @('Pad 5 Pro');    W = 3392; H = 2400 },
    @{ Match = @('Pad 4 Pro');    W = 3392; H = 2400 },
    @{ Match = @('Pad 3 Pro');    W = 3000; H = 2120 },
    @{ Match = @('Pad 5');        W = 3000; H = 2120 },
    @{ Match = @('Pad 3');        W = 2800; H = 2000 },
    @{ Match = @('Pad mini', 'Pad Mini'); W = 2520; H = 1680 },
    @{ Match = @('Pad Air5');     W = 2800; H = 1980 },
    @{ Match = @('Find N6');      W = 2480; H = 2248 },
    @{ Match = @('OnePlus Pad 3 Pro', '一加平板 3 Pro'); W = 3392; H = 2400 },
    @{ Match = @('OnePlus Pad 2 Pro', '一加平板 2 Pro'); W = 3392; H = 2400 },
    @{ Match = @('OnePlus Pad Pro', '一加平板 Pro');     W = 3000; H = 2120 },
    @{ Match = @('OnePlus Pad 2', '一加平板 2');         W = 3000; H = 2120 },
    @{ Match = @('OnePlus Pad', '一加平板');             W = 2800; H = 2000 }
)

function Desired($dev) {
    foreach ($entry in $DeviceMap) {
        foreach ($pat in $entry.Match) {
            if ($dev -like "*$pat*") { return @{ W = $entry.W; H = $entry.H } }
        }
    }
    return $null
}

function KillTools {
    Get-Process OPDisplayDriverTool -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

function CleanDevice {
    KillTools
    & pnputil /remove-device "SWD\OPDISPLAYDRIVER\OPDISPLAYDRIVER" 2>$null | Out-Null
    Start-Sleep -Seconds 3
}

function HasRes($w, $h) {
    $b = [ScreenFitTopo]::ActiveBounds()
    return ($b -like ("$w,$h,*"))
}

function CreateDisplay($w, $h) {
    $out = Join-Path $LogDir ("tool_{0}.out" -f (Get-Date -Format 'HHmmssfff'))
    Start-Process -FilePath $Tool -ArgumentList @('--operation','create','--width',"$w",'--height',"$h",'--freq','60') -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err" | Out-Null
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 2
        if (HasRes $w $h) { return $true }
        if ((Get-Content $out -Raw -ErrorAction SilentlyContinue) -match 'CreateSuccess') { Start-Sleep -Seconds 2; if (HasRes $w $h) { return $true } }
    }
    WLog ('   建屏失败，工具输出: ' + ((Get-Content $out -Tail 8 -ErrorAction SilentlyContinue) -join ' | '))
    return $false
}

function GetState { if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { 'off' } }
function SetState($s) { Set-Content -Path $StateFile -Value $s -Encoding UTF8 }


# ---- 显示拓扑切换（直接由 watcher 完成）----
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ScreenFitTopo {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct RAT { public uint N; public uint D; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public RAT refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC sourceInfo; public TGT targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Explicit, Size=64)] public struct MODE {
    [FieldOffset(0)] public uint infoType;
    [FieldOffset(4)] public uint id;
    [FieldOffset(8)] public LUID adapterId;
    [FieldOffset(16)] public uint width;
    [FieldOffset(20)] public uint height;
    [FieldOffset(24)] public uint pixelFormat;
    [FieldOffset(28)] public int posX;
    [FieldOffset(32)] public int posY;
  }
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
  static bool IsVirtualPath(PATH p) {
    var n = Name(p);
    return n.IndexOf("OPExtScreen", StringComparison.OrdinalIgnoreCase) >= 0 ||
           n.IndexOf("OPDisplayDriver", StringComparison.OrdinalIgnoreCase) >= 0 ||
           n.IndexOf("DELD0E6", StringComparison.OrdinalIgnoreCase) >= 0;
  }
  public static bool VirtualPathExists() {
    foreach (var p in Query()) { if (IsVirtualPath(p)) return true; }
    return false;
  }
  static PATH[] QueryActive() {
    uint np, nm; int e = GetDisplayConfigBufferSizes(2, out np, out nm); if (e != 0) throw new Exception("buf=" + e);
    var p = new PATH[np]; var m = new MODE[nm];
    e = QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero); if (e != 0) throw new Exception("query=" + e);
    var r = new PATH[np]; Array.Copy(p, r, np); return r;
  }
  public static bool VirtualActive() {
    foreach (var p in QueryActive()) { if (IsVirtualPath(p)) return true; }
    return false;
  }
  public static int ActiveCount() { return QueryActive().Length; }
  public static string ActiveBounds() {
    uint np, nm; int e = GetDisplayConfigBufferSizes(2, out np, out nm); if (e != 0) return "";
    var paths = new PATH[np]; var modes = new MODE[nm];
    e = QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero); if (e != 0) return "";
    for (int i = 0; i < np; i++) {
      if (paths[i].sourceInfo.modeInfoIdx == INVALID) continue;
      var m = modes[paths[i].sourceInfo.modeInfoIdx];
      if (m.infoType == 1) return m.width + "," + m.height + "," + m.posX + "," + m.posY;
    }
    return "";
  }
  public static string Extend() {
    return "err=" + SetDisplayConfig(0, null, 0, null, APPLY | 0x8);
  }
  public static string DeactivateVirtual() {
    uint np, nm; int e = GetDisplayConfigBufferSizes(2, out np, out nm); if (e != 0) return "buf=" + e;
    var paths = new PATH[np]; var modes = new MODE[nm];
    e = QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero); if (e != 0) return "query=" + e;
    var kept = new System.Collections.Generic.List<PATH>();
    for (int i = 0; i < np; i++) { if (!IsVirtualPath(paths[i])) kept.Add(paths[i]); }
    if (kept.Count == 0) return "no-physical";
    int minX = int.MaxValue, minY = int.MaxValue;
    foreach (var p in kept) {
      if (p.sourceInfo.modeInfoIdx != INVALID) {
        var m = modes[p.sourceInfo.modeInfoIdx];
        if (m.infoType == 1) { if (m.posX < minX) minX = m.posX; if (m.posY < minY) minY = m.posY; }
      }
    }
    if (minX == int.MaxValue) { minX = 0; minY = 0; }
    var keepP = new System.Collections.Generic.List<PATH>();
    var keepM = new System.Collections.Generic.List<MODE>();
    foreach (var q0 in kept) {
      var q = q0;
      if (q.sourceInfo.modeInfoIdx != INVALID) {
        var m = modes[q.sourceInfo.modeInfoIdx];
        if (m.infoType == 1) { m.posX -= minX; m.posY -= minY; }
        keepM.Add(m); q.sourceInfo.modeInfoIdx = (uint)(keepM.Count - 1);
      }
      if (q.targetInfo.modeInfoIdx != INVALID) {
        keepM.Add(modes[q.targetInfo.modeInfoIdx]); q.targetInfo.modeInfoIdx = (uint)(keepM.Count - 1);
      }
      keepP.Add(q);
    }
    return "err=" + SetDisplayConfig((uint)keepP.Count, keepP.ToArray(), (uint)keepM.Count, keepM.ToArray(), USE | APPLY);
  }
  static PATH[] sPaths = null;
  static byte[] sModes = null;
  static uint sNp = 0, sNm = 0;
  public static bool HasSnapshot() { return sPaths != null; }
  public static string SaveSnapshot(string file) {
    uint np, nm; int e = GetDisplayConfigBufferSizes(2, out np, out nm); if (e != 0) return "buf=" + e;
    var paths = new PATH[np]; var modes = new MODE[nm];
    e = QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero); if (e != 0) return "query=" + e;
    var keepP = new System.Collections.Generic.List<PATH>();
    var keepM = new System.Collections.Generic.List<MODE>();
    for (int i = 0; i < np; i++) {
      var q = paths[i];
      if (IsVirtualPath(q)) continue;
      if (q.sourceInfo.modeInfoIdx != INVALID) { keepM.Add(modes[q.sourceInfo.modeInfoIdx]); q.sourceInfo.modeInfoIdx = (uint)(keepM.Count - 1); }
      if (q.targetInfo.modeInfoIdx != INVALID) { keepM.Add(modes[q.targetInfo.modeInfoIdx]); q.targetInfo.modeInfoIdx = (uint)(keepM.Count - 1); }
      keepP.Add(q);
    }
    if (keepP.Count == 0) return "only-virtual";
    sNp = (uint)keepP.Count; sNm = (uint)keepM.Count;
    sPaths = keepP.ToArray();
    int msz = Marshal.SizeOf(typeof(MODE));
    sModes = new byte[msz * (int)sNm];
    if (sNm > 0) {
      IntPtr p = Marshal.AllocHGlobal(msz * (int)sNm);
      for (int i = 0; i < sNm; i++) Marshal.StructureToPtr(keepM[i], IntPtr.Add(p, i * msz), false);
      Marshal.Copy(p, sModes, 0, sModes.Length); Marshal.FreeHGlobal(p);
    }
    try {
      int psz = Marshal.SizeOf(typeof(PATH));
      using (var fs = new System.IO.FileStream(file, System.IO.FileMode.Create))
      using (var bw = new System.IO.BinaryWriter(fs)) {
        bw.Write(sNp); bw.Write(sNm); bw.Write(psz); bw.Write(msz);
        IntPtr pp = Marshal.AllocHGlobal(psz * (int)sNp);
        for (int i = 0; i < sNp; i++) Marshal.StructureToPtr(sPaths[i], IntPtr.Add(pp, i * psz), false);
        var pb = new byte[psz * (int)sNp]; Marshal.Copy(pp, pb, 0, pb.Length); Marshal.FreeHGlobal(pp);
        bw.Write(pb); bw.Write(sModes);
      }
    } catch { }
    return "saved np=" + sNp + " nm=" + sNm;
  }
  public static string LoadSnapshot(string file) {
    try {
      using (var fs = new System.IO.FileStream(file, System.IO.FileMode.Open))
      using (var br = new System.IO.BinaryReader(fs)) {
        sNp = br.ReadUInt32(); sNm = br.ReadUInt32(); int psz = br.ReadInt32(); int msz = br.ReadInt32();
        var pb = br.ReadBytes(psz * (int)sNp); var mb = br.ReadBytes(msz * (int)sNm);
        sPaths = new PATH[sNp];
        IntPtr pp = Marshal.AllocHGlobal(pb.Length);
        Marshal.Copy(pb, 0, pp, pb.Length);
        for (int i = 0; i < sNp; i++) sPaths[i] = (PATH)Marshal.PtrToStructure(IntPtr.Add(pp, i * psz), typeof(PATH));
        Marshal.FreeHGlobal(pp); sModes = mb;
      }
      return "loaded np=" + sNp + " nm=" + sNm;
    } catch (Exception ex) { return "load-fail:" + ex.Message; }
  }
  public static string RestoreSnapshot() {
    if (sPaths == null) return "no-snapshot";
    int msz = Marshal.SizeOf(typeof(MODE));
    var modes = new MODE[sNm];
    if (sNm > 0) {
      IntPtr p = Marshal.AllocHGlobal(msz * (int)sNm);
      Marshal.Copy(sModes, 0, p, sModes.Length);
      for (int i = 0; i < sNm; i++) modes[i] = (MODE)Marshal.PtrToStructure(IntPtr.Add(p, i * msz), typeof(MODE));
      Marshal.FreeHGlobal(p);
    }
    int e = SetDisplayConfig(sNp, sPaths, sNm, modes, USE | APPLY);
    sPaths = null; sModes = null;
    return "err=" + e;
  }

}
'@

$topoState = ''
# ---- 把遗留在已关闭显示器上的窗口移回虚拟屏 ----
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class WindowMover {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition; }
  delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT2 { public int Left, Top, Right, Bottom; }
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT2 val, int size);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  public static void InitDpi() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { } }
  const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
  static bool GetPhysicalRect(IntPtr h, out RECT r) {
    RECT2 r2;
    if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r2, Marshal.SizeOf(typeof(RECT2))) == 0 && r2.Right > r2.Left) {
      r = new RECT { Left = r2.Left, Top = r2.Top, Right = r2.Right, Bottom = r2.Bottom }; return true;
    }
    return GetWindowRect(h, out r);
  }
  const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, DWMWA_CLOAKED = 14;
  const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
  const int SW_RESTORE = 9, SW_MAXIMIZE = 3, SW_SHOWMINIMIZED = 2;
  static bool SkipClass(string c) {
    return c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd" ||
           c == "Windows.UI.Core.CoreWindow" || c == "ApplicationFrameWindow";
  }
  public static int MoveAll(int sw, int sh) {
    if (sw <= 0 || sh <= 0) return 0;
    int moved = 0;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      int cloak = 0;
      try { DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloak, 4); } catch { }
      if (cloak != 0) return true;
      if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
      if (GetWindowTextLength(h) == 0) return true;
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      if (SkipClass(cls.ToString())) return true;
      RECT r; if (!GetPhysicalRect(h, out r)) return true;
      int w = r.Right - r.Left, hh = r.Bottom - r.Top;
      bool intersects = r.Right > 0 && r.Left < sw && r.Bottom > 0 && r.Top < sh;
      if (intersects && w > 0 && hh > 0) {
        int ix = Math.Max(0, Math.Min(r.Right, sw) - Math.Max(r.Left, 0));
        int iy = Math.Max(0, Math.Min(r.Bottom, sh) - Math.Max(r.Top, 0));
        if ((double)ix * iy / ((double)w * hh) >= 0.35) return true;
      }
      var wp = new WINDOWPLACEMENT(); wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
      bool hasWp = GetWindowPlacement(h, ref wp);
      bool min = IsIconic(h);
      bool max = IsZoomed(h);
      if (w <= 0 || hh <= 0) {
        if (hasWp) { w = wp.rcNormalPosition.Right - wp.rcNormalPosition.Left; hh = wp.rcNormalPosition.Bottom - wp.rcNormalPosition.Top; }
      }
      if (w <= 0) w = 800; if (hh <= 0) hh = 600;
      if (w > sw) w = sw; if (hh > sh) hh = sh;
      int x = Math.Max(0, (sw - w) / 2), y = Math.Max(0, (sh - hh) / 2);
      if (min && hasWp) {
        wp.rcNormalPosition = new RECT { Left = x, Top = y, Right = x + w, Bottom = y + hh };
        wp.showCmd = SW_SHOWMINIMIZED;
        SetWindowPlacement(h, ref wp); moved++; return true;
      }
      if (max) ShowWindow(h, SW_RESTORE);
      SetWindowPos(h, IntPtr.Zero, x, y, w, hh, SWP_NOZORDER | SWP_NOACTIVATE);
      if (max) ShowWindow(h, SW_MAXIMIZE);
      moved++;
      return true;
    }, IntPtr.Zero);
    return moved;
  }
}
'@

function Move-WindowsToVirtual {
    try {
        [WindowMover]::InitDpi()
        $b = [ScreenFitTopo]::ActiveBounds()
        $m = [regex]::Match($b, '^(\d+),(\d+),(\d+),(\d+)$')
        if (-not $m.Success) { return 0 }
        $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
        return [WindowMover]::MoveAll($w, $h)
    } catch { return 0 }
}

function Set-OnlyVirtual {
    $script:topoResult = 'ok'
    $r = [ScreenFitTopo]::OnlyVirtual()
    if ($r -eq 'err=0') { WLog "切到仅在虚拟屏: $r"; $script:topoState = 'virtual'; $script:topoResult = 'ok' }
    else { $script:topoResult = $r; WLog "切虚拟屏失败: $r（下轮重试）" }
}
function Set-OnlyInternal {
    if ($script:topoState -eq 'internal') { return }
    $r = [ScreenFitTopo]::OnlyInternal()
    if ($r -eq 'err=0') { WLog "恢复仅内屏: $r"; $script:topoState = 'internal' }
}

$prebuildStableSec = 20
$lastPrebuildTry = [datetime]::MinValue
$devConnectedSince = $null


function Get-ActiveCount {
    try { return [ScreenFitTopo]::ActiveCount() } catch { return 99 }
}

function Ensure-OnlyVirtual {
    if (-not [ScreenFitTopo]::VirtualActive()) {
        [ScreenFitTopo]::Extend() | Out-Null
        Start-Sleep -Milliseconds 400
    }
    if (-not [ScreenFitTopo]::VirtualActive()) { return $false }
    Set-OnlyVirtual
    return ($script:topoResult -eq 'ok')
}

function Start-Create($w, $h) {
    $out = Join-Path $LogDir ("tool_{0}.out" -f (Get-Date -Format 'HHmmssfff'))
    Start-Process -FilePath $Tool -ArgumentList @('--operation','create','--width',"$w",'--height',"$h",'--freq','60') `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err" | Out-Null
    return $out
}

function Wait-VirtualPath($timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ([ScreenFitTopo]::VirtualPathExists()) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$lastCreateTry = [datetime]::MinValue
$script:snapshotTried = $false
$script:windowsMoved = $false
$script:lastReapply = [datetime]::MinValue
$script:reapplyFails = 0
# 日志清理：只保留最近 40 个工具输出，watcher.log 超过 5MB 截断
try {
    Get-ChildItem $LogDir -Filter 'tool_*' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 40 | Remove-Item -Force -ErrorAction SilentlyContinue
    if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 5MB) {
        $tail = Get-Content $LogFile -Tail 2000
        Set-Content -Path $LogFile -Value $tail -Encoding UTF8
    }
} catch { }

WLog 'watcher-run 启动（仅远程信号触发 + 退出恢复布局）'

# 空闲启动：恢复残留快照，清理虚拟屏，保持用户原布局
$s0 = Get-Session
if (-not $s0.Active) {
    if (Test-Path $SnapshotFile) {
        [ScreenFitTopo]::LoadSnapshot($SnapshotFile) | Out-Null
        $r = [ScreenFitTopo]::RestoreSnapshot()
        WLog ("启动恢复上次屏幕布局: " + $r)
        Remove-Item $SnapshotFile -Force -ErrorAction SilentlyContinue
    }
    if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }
    SetState 'off'
}

while ($true) {
    $s = Get-Session
    if ($s.Active) {
        # 僵尸会话看门狗：会话在，但远程引擎日志/心跳都长时间无更新（典型是平板 App 崩了）
        $live = Get-RemoteLiveness
        if (-not $script:lastZombieKill) { $script:lastZombieKill = [datetime]::MinValue }
        if ($live.AgentAge -gt 120 -and $live.AckAge -gt 90 -and
            ((Get-Date) - $script:lastZombieKill).TotalSeconds -gt 300) {
            WLog ("检测到僵尸会话（远程引擎 " + [math]::Round($live.AgentAge) + "s / 心跳 " + [math]::Round($live.AckAge) + "s 无更新）→ 恢复布局并重启远程引擎")
            if ([ScreenFitTopo]::HasSnapshot()) {
                $r = [ScreenFitTopo]::RestoreSnapshot()
                Remove-Item $SnapshotFile -Force -ErrorAction SilentlyContinue
                WLog ("   恢复连接前布局: " + $r)
            } else {
                Set-OnlyInternal
            }
            SetState 'off'
            Get-Process SLDesktopAgent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $script:lastZombieKill = Get-Date
            $script:windowsMoved = $false
            Start-Sleep -Seconds 2
            continue
        }
        $t = Desired $s.Device
        $bounds = [ScreenFitTopo]::ActiveBounds()
        $resOk = ($t -and $bounds -like ("$($t.W),$($t.H),*"))
        # 已经是“目标分辨率 + 仅虚拟屏 + 只有 1 块屏”时直接跳过
        if ((GetState) -eq 'on' -and [ScreenFitTopo]::VirtualActive() -and ((Get-ActiveCount) -eq 1) -and $resOk) {
            if (-not $script:windowsMoved) {
                Start-Sleep -Milliseconds 300
                $n = Move-WindowsToVirtual
                WLog ("已把 $n 个窗口移回虚拟屏")
                $script:windowsMoved = $true
            }
            $script:reapplyFails = 0
            Start-Sleep -Milliseconds 500
            continue
        }
        if ((GetState) -eq 'on' -and [ScreenFitTopo]::VirtualActive() -and ((Get-ActiveCount) -gt 1)) {
            if (((Get-Date) - $script:lastReapply).TotalSeconds -ge 2) {
                $script:lastReapply = Get-Date
                Set-OnlyVirtual
                $script:windowsMoved = $false
                $script:reapplyFails++
                WLog ("检测到额外屏幕，重新切回仅虚拟屏（err=" + $script:topoResult + "，当前 " + (Get-ActiveCount) + " 块，第 " + $script:reapplyFails + " 次）")
                if ($script:reapplyFails -ge 5) {
                    [ScreenFitTopo]::OnlyInternal() | Out-Null
                    Start-Sleep -Milliseconds 400
                    Set-OnlyVirtual
                    WLog ("额外屏反复恢复，已改用 internal->virtual 强制重切（err=" + $script:topoResult + "）")
                }
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        if ($t) {
            # 分辨率与设备不符（例如会话中换了平板）→ 重建虚拟屏
            if ([ScreenFitTopo]::VirtualActive() -and -not $resOk) {
                if (((Get-Date) - $lastCreateTry).TotalSeconds -ge 15) {
                    $lastCreateTry = Get-Date
                    WLog ('设备分辨率变化 -> 重建虚拟屏 ' + $t.W + 'x' + $t.H)
                    CleanDevice
                    Start-Create $t.W $t.H | Out-Null
                    Wait-VirtualPath 10 | Out-Null
                }
            }
            if (-not [ScreenFitTopo]::HasSnapshot() -and -not $script:snapshotTried) {
                $script:snapshotTried = $true
                $r = [ScreenFitTopo]::SaveSnapshot($SnapshotFile)
                WLog ("保存连接前屏幕布局: " + $r)
            }
            $t0 = Get-Date
            if (-not [ScreenFitTopo]::VirtualActive()) {
                if ([ScreenFitTopo]::VirtualPathExists()) {
                    [ScreenFitTopo]::Extend() | Out-Null
                } elseif (((Get-Date) - $lastCreateTry).TotalSeconds -ge 15) {
                    $lastCreateTry = Get-Date
                    Set-Content -Path (Join-Path $LogDir 'last-device.txt') -Value $s.Device -Encoding UTF8
                    WLog ('检测到远程会话 -> 建屏 ' + $s.Device + ' ' + $t.W + 'x' + $t.H)
                    CleanDevice
                    Start-Create $t.W $t.H | Out-Null
                    Wait-VirtualPath 10 | Out-Null
                }
            }
            $switched = $false
            if ([ScreenFitTopo]::VirtualActive()) { $switched = Ensure-OnlyVirtual }
            if (-not $switched -and -not [ScreenFitTopo]::VirtualActive()) {
                if (((Get-Date) - $lastCreateTry).TotalSeconds -ge 15) {
                    $lastCreateTry = Get-Date
                    WLog '虚拟屏未激活，重建后重试'
                    CleanDevice
                    Start-Create $t.W $t.H | Out-Null
                    if (Wait-VirtualPath 10) { $switched = Ensure-OnlyVirtual }
                }
            }
            if ($switched) {
                if ((GetState) -ne 'on') {
                    SetState 'on'
                    WLog ("已切到 " + $t.W + "x" + $t.H + " 仅虚拟屏（" + [math]::Round(((Get-Date) - $t0).TotalSeconds,1) + " 秒）")
                }
                if (-not $script:windowsMoved) {
                    Start-Sleep -Milliseconds 500
                    $n = Move-WindowsToVirtual
                    WLog ("已把 $n 个窗口移回虚拟屏")
                    $script:windowsMoved = $true
                }
            } elseif ((Get-ActiveCount) -gt 1) {
                Ensure-OnlyVirtual | Out-Null
            }
        }
    } else {
        if ([ScreenFitTopo]::HasSnapshot()) {
            $r = [ScreenFitTopo]::RestoreSnapshot()
            Remove-Item $SnapshotFile -Force -ErrorAction SilentlyContinue
            WLog ("远程结束 -> 恢复连接前屏幕布局: " + $r)
            if ($r -ne 'err=0') { Set-OnlyInternal; WLog '   快照恢复失败，已兜底回到仅内屏' }
            SetState 'off'
            if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }
        } elseif ((GetState) -eq 'on' -or $script:topoState -eq 'virtual') {
            Set-OnlyInternal
            SetState 'off'
            Remove-Item $SnapshotFile -Force -ErrorAction SilentlyContinue
            if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }
        }
        $script:snapshotTried = $false
        $script:windowsMoved = $false
    }
    Start-Sleep -Milliseconds 500
}

