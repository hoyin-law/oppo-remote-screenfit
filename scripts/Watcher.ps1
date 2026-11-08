<#
  Watcher.ps1 —— OPPO 互联 远程控制屏幕自适应（由计划任务以最高权限运行，登录自启）。

  行为：
    - 只在检测到 OPPO 互联「远程控制」会话开始时才建虚拟屏并切换；
    - 设备普通连接/断开不会自动切换屏幕（避免日常打扰）；
    - 必须有观看端在消费画面（最近 30 秒内有 send>0 的帧）才切屏；
      切屏后连续 60 秒没有观看端则自动恢复原布局，避免把物理屏锁死；
    - 远程开始时保存“连接前”的屏幕布局（扩展/复制/仅某屏）与窗口位置，退出时原样恢复；
    - 切换后校验确实只剩一块活动屏，失败自动重试/重建。
    - 版本号见 ScreenFit.Core.ps1（Get-ScreenFitVersion）。
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
$WindowSnapshotFile = Join-Path $LogDir 'window.snapshot.txt'
$PreArmFile = Join-Path $Root 'PREARM.txt'
$ArmTimeoutSec = 900
$ViewerWindowSec = 30        # 最近 30 秒内有 send>0 的帧，才认为有观看端在消费画面
$ViewerGraceSec = 60         # 切屏后连续 60 秒无观看端 -> 自动恢复原布局
$NoViewerKillSec = 180       # 远程引擎存活但长时间无观看端 -> 只恢复布局，不杀引擎

# 检测逻辑集中在 ScreenFit.Core.ps1（纯函数，tests\Test-Detection.ps1 用真实日志回放验证）
. (Join-Path $Root 'ScreenFit.Core.ps1')
Initialize-ScreenFit -StateDir $LogDir   # 日志目录用 Core 默认（OPPO devicespace），状态文件用本目录
# ===== 事件驱动唤醒：OPPO 日志 / 安装目录标记有变化时立即处理，空闲时靠超时兜底 =====
$script:sfWatchers = @()
function Initialize-ScreenFitWatchers {
    foreach ($spec in @(
        @{ Dir = (Get-ScreenFitLogDir); Filter = '*_main*.log'; Id = 'ScreenFitMainLog' },
        @{ Dir = (Get-ScreenFitLogDir); Filter = 'desktop_agent.*.log'; Id = 'ScreenFitAgentLog' },
        @{ Dir = $Root; Filter = '*.txt'; Id = 'ScreenFitRootFlag' }
    )) {
        try {
            if (-not (Test-Path $spec.Dir)) { continue }
            $w = New-Object System.IO.FileSystemWatcher $spec.Dir, $spec.Filter
            $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::Size -bor [System.IO.NotifyFilters]::CreationTime
            $w.EnableRaisingEvents = $true
            Register-ObjectEvent -InputObject $w -EventName Changed -SourceIdentifier $spec.Id | Out-Null
            $script:sfWatchers += $w
        } catch { }
    }
}
<# 阻塞等待文件事件或超时；返回 $true 表示有变化 #>
function Wait-ScreenFitWake([int]$TimeoutMs = 2000) {
    try {
        $ev = Wait-Event -Timeout ([math]::Round($TimeoutMs / 1000.0, 2))
        if ($ev) { Get-Event | Remove-Event -ErrorAction SilentlyContinue; return $true }
        return $false
    } catch {
        Start-Sleep -Milliseconds $TimeoutMs
        return $false
    }
}
Initialize-ScreenFitWatchers

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
    // SDC_TOPOLOGY_EXTEND = 0x4（此前误写成 0x8 = SDC_TOPOLOGY_EXTERNAL「仅外接屏」）
    return "err=" + SetDisplayConfig(0, null, 0, null, APPLY | 0x4);
  }
  // 真实外接屏数量：排除内屏（outputTechnology=0x80000000）与 OPPO 虚拟屏
  public static int ExternalMonitorCount() {
    var seen = new System.Collections.Generic.HashSet<string>();
    foreach (var p in Query()) {
      if (IsVirtualPath(p)) continue;
      if (p.targetInfo.outputTechnology == 0x80000000) continue;
      var n = Name(p);
      if (string.IsNullOrEmpty(n)) continue;
      int bar = n.IndexOf('|');
      string dn = bar >= 0 ? n.Substring(0, bar) : n;
      if (string.IsNullOrEmpty(dn)) continue;   // 幽灵 target 的 Name() 是 "|"，必须排除
      seen.Add(dn);
    }
    return seen.Count;
  }
  public static string ActiveNames() {
    var list = new System.Collections.Generic.List<string>();
    foreach (var p in QueryActive()) {
      var n = Name(p);
      if (string.IsNullOrEmpty(n)) continue;
      int bar = n.IndexOf('|'); if (bar >= 0) n = n.Substring(0, bar);
      list.Add(n);
    }
    return string.Join(",", list.ToArray());
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SRCNAME { public HDR header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string gdiDeviceName; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
  [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo", CharSet=CharSet.Unicode)] static extern int DisplayConfigGetDeviceInfoSrc(ref SRCNAME n);
  public static string EnsureNativeInternalMode() {
    string result = "";
    foreach (var p in QueryActive()) {
      if (p.targetInfo.outputTechnology != 0x80000000) continue;
      var sn = new SRCNAME(); sn.header.type = 1; sn.header.size = (uint)Marshal.SizeOf(typeof(SRCNAME));
      sn.header.adapterId = p.sourceInfo.adapterId; sn.header.id = p.sourceInfo.id;
      if (DisplayConfigGetDeviceInfoSrc(ref sn) != 0) continue;
      string dev = sn.gdiDeviceName;
      int bw = 0, bh = 0, bf = 0; long area = 0;
      for (int i = 0; i < 500; i++) { var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); if (!EnumDisplaySettings(dev, i, ref dm)) break; long a = (long)dm.dmPelsWidth * dm.dmPelsHeight; if (a > area || (a == area && dm.dmDisplayFrequency > bf)) { area = a; bw = dm.dmPelsWidth; bh = dm.dmPelsHeight; bf = dm.dmDisplayFrequency; } }
      if (bw == 0) continue;
      var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); if (!EnumDisplaySettings(dev, -1, ref cur)) continue;
      if (cur.dmPelsWidth == bw && cur.dmPelsHeight == bh) { result = dev + " already " + bw + "x" + bh; continue; }
      cur.dmPelsWidth = bw; cur.dmPelsHeight = bh; cur.dmDisplayFrequency = bf;
      cur.dmFields = 0x00080000 | 0x00100000 | 0x00400000;
      int r = ChangeDisplaySettingsEx(dev, ref cur, IntPtr.Zero, 0x1, IntPtr.Zero);
      result = dev + " -> " + bw + "x" + bh + "@" + bf + " err=" + r;
    }
    return result;
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
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
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

  // ---- 窗口位置快照 / 回搬：远控结束后把窗口放回原位 ----
  public static int SaveAll(string file) {
    int n = 0;
    var sb = new StringBuilder();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      int cloak = 0; try { DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloak, 4); } catch { }
      if (cloak != 0) return true;
      if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
      if (GetWindowTextLength(h) == 0) return true;
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      if (SkipClass(cls.ToString())) return true;
      RECT r; if (!GetPhysicalRect(h, out r)) return true;
      int lx = r.Left, ty = r.Top, rx = r.Right, by = r.Bottom;
      if (rx - lx <= 0 || by - ty <= 0) return true;
      int cmd = 1;
      var wp = new WINDOWPLACEMENT(); wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
      bool hasWp = GetWindowPlacement(h, ref wp);
      if (IsIconic(h)) {
        // 最小化窗口的物理矩形是 -32000 哨兵，必须存 rcNormalPosition（还原后的位置）
        cmd = 2;
        if (hasWp) { lx = wp.rcNormalPosition.Left; ty = wp.rcNormalPosition.Top; rx = wp.rcNormalPosition.Right; by = wp.rcNormalPosition.Bottom; }
      } else if (IsZoomed(h)) { cmd = 3; }
      if (rx - lx <= 0 || by - ty <= 0) return true;
      sb.AppendLine(h.ToInt64() + "|" + lx + "|" + ty + "|" + rx + "|" + by + "|" + cmd);
      n++;
      return true;
    }, IntPtr.Zero);
    try { System.IO.File.WriteAllText(file, sb.ToString()); } catch { }
    return n;
  }

  public static int RestoreAll(string file) {
    int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
    if (sw <= 0 || sh <= 0) return 0;
    string[] lines;
    try { lines = System.IO.File.ReadAllLines(file); } catch { return 0; }
    int restored = 0;
    foreach (var line in lines) {
      var p = line.Split('|');
      if (p.Length < 6) continue;
      long hv; int l, t, rr, b, cmd;
      if (!long.TryParse(p[0], out hv)) continue;
      if (!int.TryParse(p[1], out l) || !int.TryParse(p[2], out t)) continue;
      if (!int.TryParse(p[3], out rr) || !int.TryParse(p[4], out b) || !int.TryParse(p[5], out cmd)) continue;
      IntPtr h = new IntPtr(hv);
      if (!IsWindow(h)) continue;
      int w = rr - l, hh = b - t;
      if (w <= 0 || hh <= 0) continue;
      if (w > sw) w = sw; if (hh > sh) hh = sh;
      if (l < 0) l = 0; if (t < 0) t = 0;
      if (l + w > sw) l = Math.Max(0, sw - w);
      if (t + hh > sh) t = Math.Max(0, sh - hh);
      var wp = new WINDOWPLACEMENT(); wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
      bool hasWp = GetWindowPlacement(h, ref wp);
      if (cmd == 2 && hasWp) {
        wp.rcNormalPosition = new RECT { Left = l, Top = t, Right = l + w, Bottom = t + hh };
        wp.showCmd = SW_SHOWMINIMIZED;
        SetWindowPlacement(h, ref wp);
      } else {
        SetWindowPos(h, IntPtr.Zero, l, t, w, hh, SWP_NOZORDER | SWP_NOACTIVATE);
        if (cmd == 3) ShowWindow(h, SW_MAXIMIZE);
      }
      restored++;
    }
    return restored;
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

function Save-WindowLayout {
    try {
        [WindowMover]::InitDpi()
        $n = [WindowMover]::SaveAll($WindowSnapshotFile)
        if ($n -gt 0) { WLog ("保存窗口位置: " + $n + " 个") }
        return $n
    } catch { return 0 }
}

function Restore-WindowLayout {
    try {
        if (-not (Test-Path $WindowSnapshotFile)) { return 0 }
        [WindowMover]::InitDpi()
        $n = [WindowMover]::RestoreAll($WindowSnapshotFile)
        Remove-Item $WindowSnapshotFile -Force -ErrorAction SilentlyContinue
        if ($n -gt 0) { WLog ("恢复窗口位置: " + $n + " 个") }
        return $n
    } catch { return 0 }
}

# 所有退出路径共用：恢复拓扑（外接屏必须回到扩展）-> 等系统稳定 -> 回搬窗口 -> 拆除虚拟屏
function Restore-Layout {
    $did = $false
    $restoreFailed = $false
    if ([ScreenFitTopo]::HasSnapshot()) {
        $r = [ScreenFitTopo]::RestoreSnapshot()
        Remove-Item $SnapshotFile -Force -ErrorAction SilentlyContinue
        WLog ("   恢复连接前布局: " + $r)
        $restoreFailed = ($r -ne 'err=0')
        $did = $true
    } elseif ((GetState) -eq 'on' -or (GetState) -eq 'prearmed' -or $script:topoState -eq 'virtual') {
        $did = $true
    }
    if (-not $did) {
        $script:snapshotTried = $false
        $script:windowsMoved = $false
        return $false
    }

    SetState 'off'
    Start-Sleep -Milliseconds 600

    $external = 0
    try { $external = [ScreenFitTopo]::ExternalMonitorCount() } catch { }
    $active = 0
    try { $active = [ScreenFitTopo]::ActiveCount() } catch { }
    $action = Get-RestoreAction -HasSnapshot $true -RestoreFailed $restoreFailed -ExternalPresent ($external -gt 0) -ActiveCount $active -StateOn $true

    if ($action -eq 'extend') {
        # 用户的硬性要求：只要外接屏还在，断开远控后必须是扩展，不能塌缩成「仅电脑屏幕」
        for ($i = 1; $i -le 2; $i++) {
            $r2 = [ScreenFitTopo]::Extend()
            Start-Sleep -Milliseconds 800
            $active = [ScreenFitTopo]::ActiveCount()
            WLog ("   恢复扩展布局(第" + $i + "次): " + $r2 + "，活动屏 " + $active + " 块 [外接屏 " + $external + "]")
            if ($active -ge 2) { break }
        }
        $script:postRestoreUntil = (Get-Date).AddSeconds(30)
    } elseif ($action -eq 'internal') {
        Set-OnlyInternal
    }
    try { $nm = [ScreenFitTopo]::EnsureNativeInternalMode(); if ($nm) { WLog ("   内屏模式校验: " + $nm) } } catch { }

    Restore-WindowLayout | Out-Null
    if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }

    # 拆除虚拟屏后 Windows 可能再次塌缩成单屏：做一次收尾校验
    Start-Sleep -Milliseconds 500
    try {
        if ([ScreenFitTopo]::ExternalMonitorCount() -gt 0 -and [ScreenFitTopo]::ActiveCount() -lt 2) {
            [void][ScreenFitTopo]::Extend()
            $script:postRestoreUntil = (Get-Date).AddSeconds(30)
            WLog ("   拆除虚拟屏后布局塌缩，已再次恢复扩展（活动屏 " + [ScreenFitTopo]::ActiveCount() + " 块：" + [ScreenFitTopo]::ActiveNames() + "）")
        }
    } catch { }

    $script:snapshotTried = $false
    $script:windowsMoved = $false
    $script:noViewerSince = $null
    $script:topoState = 'off'
    $script:prearmWaitLogged = $false
    Remove-Item (Join-Path $Root 'PREARM.txt') -Force -ErrorAction SilentlyContinue
    return $true
}

<#
  Invoke-PreArm —— 预建屏：保存当前布局 -> 建指定设备分辨率的虚拟屏 -> 切到仅虚拟屏。
  用于「会话前就绪」：让 OPPO 远控从会话一开始就抓到这块屏，避免会话中切换导致 DXGI 失效。
#>
function Invoke-PreArm {
    param([string]$DeviceName)
    $t = Desired $DeviceName
    if (-not $t) {
        $devFile = Join-Path $LogDir 'last-device.txt'
        if (Test-Path $devFile) {
            $d2 = (Get-Content $devFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($d2) { $t = Desired $d2; if ($t) { WLog ("预建屏：设备名未识别，回退到最后设备 " + $d2) } }
        }
    }
    if (-not $t) { WLog ("预建屏失败：无法识别设备 '" + $DeviceName + "' 的分辨率"); return $false }

    if (-not [ScreenFitTopo]::HasSnapshot()) {
        $r = [ScreenFitTopo]::SaveSnapshot($SnapshotFile)
        WLog ("预建屏：保存连接前屏幕布局: " + $r)
        Save-WindowLayout | Out-Null
    }
    CleanDevice
    Start-Create $t.W $t.H | Out-Null
    if (-not (Wait-VirtualPath 10)) { WLog '预建屏失败：虚拟屏未出现'; return $false }
    $switched = Ensure-OnlyVirtual
    if (-not $switched) { WLog '预建屏：切换到仅虚拟屏失败'; return $false }
    SetState 'prearmed'
    WLog ("预建屏就绪：" + $DeviceName + " " + $t.W + "x" + $t.H + "（现在可用平板发起远控；结束/超时会自动恢复）")
    return $true
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
$script:noViewerSince = $null
$script:lastStayLog = $null
$script:postRestoreUntil = [datetime]::MinValue
$script:lastGuardExtend = [datetime]::MinValue
$script:remoteDisabledLogged = $false
$script:nativeCache = $null
$script:lastNativeCheck = [datetime]::MinValue
$script:lastAliveLog = Get-Date
$script:prearmWaitLogged = $false
$script:prearmWaitLogged = $false
$script:stateCacheValue = $null
$script:stateCacheTs = [datetime]::MinValue
$script:sharingCache = $false
$script:sharingCacheTs = [datetime]::MinValue
$script:sessionCache = $null
$script:sessionCacheTs = [datetime]::MinValue
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
# 若 OPPO 原生屏幕扩展/镜像正在进行，或已请求预建屏，则不要动布局
$native0 = Get-NativeExtendState
if (-not $native0.Active -and -not (Test-Path $PreArmFile)) {
    $s0 = Get-Session
    if (-not $s0.Active) {
        if (Test-Path $SnapshotFile) {
            [ScreenFitTopo]::LoadSnapshot($SnapshotFile) | Out-Null
            $r = [ScreenFitTopo]::RestoreSnapshot()
            WLog ("启动恢复上次屏幕布局: " + $r)
            Remove-Item $SnapshotFile -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
            Restore-WindowLayout | Out-Null
        }
        if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }
        SetState 'off'
    }
}

while ($true) {
    # STOP.txt 实时生效：运行中新建也能立即停止并恢复布局
    if (Test-Path (Join-Path $Root 'STOP.txt')) {
        WLog '检测到 STOP.txt -> 恢复布局并退出'
        Restore-Layout | Out-Null
        exit
    }

    # 每 10 分钟写一次存活心跳，便于判断进程是否还在正常工作
    if (((Get-Date) - $script:lastAliveLog).TotalSeconds -ge 600) {
        $script:lastAliveLog = Get-Date
$script:prearmWaitLogged = $false
$script:prearmWaitLogged = $false
$script:stateCacheValue = $null
$script:stateCacheTs = [datetime]::MinValue
$script:sharingCache = $false
$script:sharingCacheTs = [datetime]::MinValue
$script:sessionCache = $null
$script:sessionCacheTs = [datetime]::MinValue
        try {
            $aliveNative = if ($script:nativeCache) { $script:nativeCache.Active } else { '?' }
            WLog ("存活：state=" + (GetState) + " native=" + $aliveNative + " 活动屏=" + [ScreenFitTopo]::ActiveCount() + " 虚拟屏=" + [ScreenFitTopo]::VirtualActive())
        } catch { }
    }

    # OPPO 原生「屏幕扩展 / 屏幕镜像」：由 screenshare.exe 自行建屏推流，插件只守护
    # 性能：主日志可达数 MB，不能每 500ms 全量 tail 解析。策略：
    #   - 没有 screenshare 进程且上次判定为非原生模式 -> 沿用缓存，最多每 15 秒复查一次
    #   - 其余情况最多每 3 秒解析一次
    if (-not $script:sharingCacheTs -or ((Get-Date) - $script:sharingCacheTs).TotalSeconds -ge 15) {
        $script:sharingCache = @(Get-Process screenshare -ErrorAction SilentlyContinue).Count -gt 0
        $script:sharingCacheTs = Get-Date
    }
    $sharingNow = $script:sharingCache
    $sinceNativeCheck = ((Get-Date) - $script:lastNativeCheck).TotalSeconds
    $needNativeCheck = $false
    if (-not $script:nativeCache) {
        $needNativeCheck = $true
    } elseif ($sharingNow -or $script:nativeCache.Active) {
        # 原生协同进行中，或刚结束：每 2 秒复查
        $needNativeCheck = ($sinceNativeCheck -ge 2)
    } else {
        # 空闲：每 60 秒复查一次即可（主日志读取是主要 CPU 开销）
        $needNativeCheck = ($sinceNativeCheck -ge 60)
    }
    if ($needNativeCheck) {
        $native = Get-NativeExtendState
        $script:nativeCache = $native
        $script:lastNativeCheck = Get-Date
    } else {
        $native = $script:nativeCache
    }
    $nativeDecision = Get-NativeExtendDecision -NativeActive $native.Active -State (GetState)
    if ($nativeDecision -eq 'observe') {
        if ((GetState) -ne 'native') {
            SetState 'native'
            WLog ("检测到 OPPO 原生屏幕扩展/镜像（screenshare=" + $native.Sharing + "）-> 原生模式，插件不自行建屏")
        }
        Start-Sleep -Milliseconds 500
        continue
    }
    if ($nativeDecision -eq 'restore') {
        WLog 'OPPO 原生屏幕扩展结束 -> 检查并恢复扩展布局'
        SetState 'off'
        try {
            if ([ScreenFitTopo]::ExternalMonitorCount() -gt 0 -and [ScreenFitTopo]::ActiveCount() -lt 2) {
                [void][ScreenFitTopo]::Extend()
                Start-Sleep -Milliseconds 800
                WLog ("   已恢复扩展布局（活动屏 " + [ScreenFitTopo]::ActiveCount() + " 块：" + [ScreenFitTopo]::ActiveNames() + "）")
            }
        } catch { }
        $script:postRestoreUntil = (Get-Date).AddSeconds(30)
        Start-Sleep -Milliseconds 500
        continue
    }

    # 模式闸门：NO_REMOTE_ADAPT 存在且当前无预建/会话状态时，完全不需要解析远控会话，
    # 只保留原生扩展守护（上面已检查）与预建请求（会由 .txt 文件事件立即唤醒）。
    $adaptiveDisabled = Test-Path (Join-Path $Root 'NO_REMOTE_ADAPT.txt')
    $armedNow = Test-Path $PreArmFile
    if ($adaptiveDisabled -and -not $armedNow -and (GetState) -eq 'off') {
        [void](Wait-ScreenFitWake 20000)
        continue
    }

    # 会话检测 1 秒缓存（空闲时减少日志解析压力；检测延迟最多 1 秒）
    $sessionTtl = if ((GetState) -in @('on','prearmed','native')) { 1 } else { 4 }
    if (-not $script:sessionCache -or ((Get-Date) - $script:sessionCacheTs).TotalSeconds -ge $sessionTtl) {
        $s = Get-Session
        $script:sessionCache = $s
        $script:sessionCacheTs = Get-Date
    } else {
        $s = $script:sessionCache
    }

    # ===== 预建屏模式（会话前就绪）=====
    # 由 Prepare-Remote.ps1 写入 PREARM.txt 触发；建屏后等待平板发起远控，
    # 会话开始（有观看端）后转 on；撤防/超时/结束则恢复物理扩展布局。
    $armed = Test-Path $PreArmFile
    $armSeconds = $null
    if ($armed) {
        try { $armSeconds = ((Get-Date) - (Get-Item $PreArmFile).LastWriteTime).TotalSeconds } catch { }
    }
    if ($armed) {
        $viewerPre = if ($s.Cast) { $true } else { (Test-ViewerActive -WindowSeconds $ViewerWindowSec).Active }
        $preArmDecision = Get-PreArmAction -Armed $true -State (GetState) -SessionActive $s.Active -ViewerActive $viewerPre -SecondsSinceArm $armSeconds -ArmTimeoutSeconds $ArmTimeoutSec
        switch ($preArmDecision) {
            'arm' {
                $devName = (Get-Content $PreArmFile -Raw -ErrorAction SilentlyContinue).Trim()
                WLog ("收到预建请求（设备: " + $devName + "）-> 建屏并切到仅虚拟屏")
                if (-not (Invoke-PreArm -DeviceName $devName)) {
                    Remove-Item $PreArmFile -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 500
                continue
            }
            'promote' {
                if ((GetState) -ne 'on') {
                    WLog '预建屏检测到远控会话且观看端在消费 -> 进入会话模式'
                    SetState 'on'
                }
                # 继续往下走正常会话分支
            }
            'wait' {
                Start-Sleep -Milliseconds 500
                continue
            }
            'restore' {
                WLog '预建屏撤防或等待超时 -> 恢复物理扩展布局'
                Restore-Layout | Out-Null
                Remove-Item $PreArmFile -Force -ErrorAction SilentlyContinue
                if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }
                SetState 'off'
                Start-Sleep -Milliseconds 500
                continue
            }
        }
    } elseif ((GetState) -eq 'prearmed') {
        WLog '预建标记消失（已撤防）-> 恢复物理扩展布局'
        Restore-Layout | Out-Null
        if ([ScreenFitTopo]::VirtualPathExists()) { CleanDevice }
        SetState 'off'
        Start-Sleep -Milliseconds 500
        continue
    }

    # 可选的模式开关：NO_REMOTE_ADAPT.txt 存在时，只保留「原生屏幕扩展守护 + 恢复扩展」，
    # 不再尝试为远程控制自建虚拟屏（当前 OPPO 16.2.20.0 下该路线已证伪）。
    # 例外：预建屏已 promote 到 state=on 时，仍要走正常会话逻辑（含观看端丢失恢复）。
    if ($s.Active -and -not $s.Cast -and (GetState) -ne 'on' -and (Test-Path (Join-Path $Root 'NO_REMOTE_ADAPT.txt'))) {
        if (-not $script:remoteDisabledLogged) {
            WLog '远程控制自适应已关闭（NO_REMOTE_ADAPT.txt）：仅守护原生屏幕扩展与恢复布局'
            $script:remoteDisabledLogged = $true
        }
        Start-Sleep -Milliseconds 500
        continue
    }
    if ($s.Active) {
        $live = Get-RemoteLiveness
        if (-not $live.AgentRunning) {
            if (Test-Path $PreArmFile) {
                if ((GetState) -eq 'on') { SetState 'prearmed' }
                try { (Get-Item $PreArmFile).LastWriteTime = Get-Date } catch { }
                WLog '远程引擎已退出 -> 预建屏保持就绪，等待重连（物理屏保持虚拟屏）'
                Start-Sleep -Milliseconds 500
                continue
            }
            if (Restore-Layout) { WLog '远程引擎已退出 -> 已恢复原布局' }
            Start-Sleep -Milliseconds 500
            continue
        }

        # 观看端门禁：OPPO 的「远控态 = true」只说明设备连上了，不等于有人在看画面。
        # 只有最近 ViewerWindowSec 秒内确有 send>0 的帧（观看端在消费画面）才允许切屏。
        $viewer = Test-ViewerActive -WindowSeconds $ViewerWindowSec
        if (-not $viewer.Active) {
            if (-not $script:noViewerSince) { $script:noViewerSince = Get-Date }
        } else {
            $script:noViewerSince = $null
            $script:lastStayLog = $null
        }
        $noViewerSec = $null
        if ($script:noViewerSince) { $noViewerSec = ((Get-Date) - $script:noViewerSince).TotalSeconds }
        $decision = Get-ScreenFitDecision -SessionActive $true -ViewerActive $true -State (GetState) -NoViewerSeconds $noViewerSec -ViewerGraceSeconds $ViewerGraceSec
        if ($decision -eq 'restore') {
            if (Test-Path $PreArmFile) {
                WLog ("无观看端已 " + [math]::Round($noViewerSec) + "s -> 预建屏保持就绪，等待重连")
                SetState 'prearmed'
                try { (Get-Item $PreArmFile).LastWriteTime = Get-Date } catch { }
                $script:noViewerSince = $null
                Start-Sleep -Milliseconds 700
                continue
            }
            WLog ("无观看端已 " + [math]::Round($noViewerSec) + "s -> 恢复原布局（避免物理屏被锁在虚拟屏）")
            Restore-Layout | Out-Null
            Start-Sleep -Milliseconds 500
            continue
        }
        if ($decision -eq 'stay') {
            if (-not $script:lastStayLog -or ((Get-Date) - $script:lastStayLog).TotalSeconds -ge 60) {
                WLog ("会话存在但无观看端（最近消费帧 " + $viewer.SecondsSinceConsumed + "s 前）-> 暂不切屏")
                $script:lastStayLog = Get-Date
            }
            Start-Sleep -Milliseconds 500
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
                Save-WindowLayout | Out-Null
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
        # 会话结束（或本来就没有会话）
        if ((Test-Path $PreArmFile) -and ((GetState) -eq 'on' -or (GetState) -eq 'prearmed')) {
            if ((GetState) -eq 'on') { SetState 'prearmed' }
            try { (Get-Item $PreArmFile).LastWriteTime = Get-Date } catch { }
            if (-not $script:prearmWaitLogged) {
                WLog '远控已断开 -> 保持虚拟屏等待重连（15 分钟内重连将从虚拟屏开始）'
                $script:prearmWaitLogged = $true
            }
        } else {
            if (Restore-Layout) { WLog '远程结束 -> 已恢复连接前屏幕布局' }
        }
        # 恢复后 30 秒内持续盯外接屏：OPPO 或系统可能再次把外接屏关掉（用户要求断开后保持扩展）
        if ($script:postRestoreUntil -and (Get-Date) -lt $script:postRestoreUntil -and
            ((Get-Date) - $script:lastGuardExtend).TotalSeconds -ge 3) {
            try {
                if ([ScreenFitTopo]::ExternalMonitorCount() -gt 0 -and [ScreenFitTopo]::ActiveCount() -lt 2) {
                    $script:lastGuardExtend = Get-Date
                    [void][ScreenFitTopo]::Extend()
                    WLog ("   外接屏被关闭，已恢复扩展布局（活动屏 " + [ScreenFitTopo]::ActiveCount() + " 块：" + [ScreenFitTopo]::ActiveNames() + "）")
                }
            } catch { }
        }
        $script:snapshotTried = $false
        $script:windowsMoved = $false
        $script:noViewerSince = $null
    }
    if (-not $s.Active -and (GetState) -eq 'off' -and -not (Test-Path $PreArmFile)) {
        [void](Wait-ScreenFitWake 20000)
    } else {
        [void](Wait-ScreenFitWake 700)
    }
}

