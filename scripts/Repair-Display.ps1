<#
  Repair-Display.ps1 —— 显示模式修复：内屏回到原生（最大）分辨率 + 外接屏恢复「扩展」。

  为什么需要它：
    ToDesk / 向日葵 / 其他远控或虚拟屏软件可能把笔记本内屏改成 16:9（如 1920x1080），
    而 ROG 这类 16:10 面板（2560x1600）在「保持比例」缩放下就会出现上下黑边。
    Watcher 在恢复布局时也会自动做同样的校验，但如果你手动跑过 ToDesk 或想立刻恢复，
    可以直接运行本脚本（无需管理员）。

  用法：
    pwsh -NoProfile -File scripts\Repair-Display.ps1
    pwsh -NoProfile -File scripts\Repair-Display.ps1 -CheckOnly
#>

[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class RepairDisplay {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID a; public uint id; public uint mi; public uint st; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID a; public uint id; public uint mi; public uint tech; public uint rot; public uint scl; public uint rn; public uint rd; public uint slo; public int avail; public uint st; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC s; public TGT t; public uint flags; }
  [StructLayout(LayoutKind.Explicit, Size=64)] public struct MODE { [FieldOffset(0)] public uint infoType; [FieldOffset(4)] public uint id; [FieldOffset(8)] public LUID a; [FieldOffset(16)] public uint width; [FieldOffset(20)] public uint height; [FieldOffset(24)] public uint pixelFormat; [FieldOffset(28)] public int posX; [FieldOffset(32)] public int posY; }
  [StructLayout(LayoutKind.Sequential)] public struct HDR { public uint type; public uint size; public LUID a; public uint id; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TDN { public HDR h; public uint flags; public uint ot; public ushort mfg; public ushort prod; public uint conn; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string name; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SRCNAME { public HDR h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string gdi; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
  [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint np, PATH[] p, uint nm, MODE[] m, uint f);
  [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TDN n);
  [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] public static extern int DisplayConfigGetDeviceInfoSrc(ref SRCNAME n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);

  public static PATH[] Active() {
    uint np, nm; int e = GetDisplayConfigBufferSizes(2, out np, out nm); if (e != 0) return new PATH[0];
    var p = new PATH[np]; var m = new MODE[nm];
    e = QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero); if (e != 0) return new PATH[0];
    var r = new PATH[np]; Array.Copy(p, r, np); return r;
  }
  public static string InternalInfo() {
    var paths = Active();
    foreach (var p in paths) {
      if (p.t.tech != 0x80000000) continue;
      var sn = new SRCNAME(); sn.h.type = 1; sn.h.size = (uint)Marshal.SizeOf(typeof(SRCNAME)); sn.h.a = p.s.a; sn.h.id = p.s.id;
      if (DisplayConfigGetDeviceInfoSrc(ref sn) != 0) continue;
      var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(sn.gdi, -1, ref dm)) continue;
      return sn.gdi + "|" + dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
    }
    return "";
  }
  public static string NativeInternalMode() {
    var paths = Active();
    foreach (var p in paths) {
      if (p.t.tech != 0x80000000) continue;
      var sn = new SRCNAME(); sn.h.type = 1; sn.h.size = (uint)Marshal.SizeOf(typeof(SRCNAME)); sn.h.a = p.s.a; sn.h.id = p.s.id;
      if (DisplayConfigGetDeviceInfoSrc(ref sn) != 0) continue;
      return sn.gdi;
    }
    return "";
  }
  public static string EnsureNative() {
    string dev = NativeInternalMode();
    if (string.IsNullOrEmpty(dev)) return "no-internal";
    int bw = 0, bh = 0, bf = 0; long area = 0;
    for (int i = 0; i < 500; i++) {
      var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(dev, i, ref dm)) break;
      long a = (long)dm.dmPelsWidth * dm.dmPelsHeight;
      if (a > area || (a == area && dm.dmDisplayFrequency > bf)) { area = a; bw = dm.dmPelsWidth; bh = dm.dmPelsHeight; bf = dm.dmDisplayFrequency; }
    }
    if (bw == 0) return "no-modes";
    var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(dev, -1, ref cur)) return "enum-current-failed";
    if (cur.dmPelsWidth == bw && cur.dmPelsHeight == bh) return "already " + bw + "x" + bh;
    cur.dmPelsWidth = bw; cur.dmPelsHeight = bh; cur.dmDisplayFrequency = bf;
    cur.dmFields = 0x00080000 | 0x00100000 | 0x00400000;
    int r = ChangeDisplaySettingsEx(dev, ref cur, IntPtr.Zero, 0x1, IntPtr.Zero);
    return dev + " -> " + bw + "x" + bh + "@" + bf + " err=" + r;
  }
  public static int ExternalCount() {
    var seen = new System.Collections.Generic.HashSet<string>();
    foreach (var p in Active()) {
      if (p.t.tech == 0x80000000) continue;
      var n = new TDN(); n.h.type = 2; n.h.size = (uint)Marshal.SizeOf(typeof(TDN)); n.h.a = p.t.a; n.h.id = p.t.id;
      if (DisplayConfigGetDeviceInfo(ref n) != 0) continue;
      if (!string.IsNullOrEmpty(n.name) && n.name != "|") seen.Add(n.name);
    }
    return seen.Count;
  }
  public static int ActiveCount() { return Active().Length; }
  public static string Extend() { return "err=" + SetDisplayConfig(0, null, 0, null, 0x80 | 0x4); }
}
'@

Write-Host ('内屏当前: ' + [RepairDisplay]::InternalInfo())
Write-Host ('活动屏: ' + [RepairDisplay]::ActiveCount() + ' 块，外接屏: ' + [RepairDisplay]::ExternalCount() + ' 块')
if ($CheckOnly) {
    $cur = [RepairDisplay]::InternalInfo()
    $dev = [RepairDisplay]::NativeInternalMode()
    Write-Host ('检查模式：内屏设备 ' + $dev + '，当前 ' + $cur) -ForegroundColor Cyan
    exit 0
}

$r1 = [RepairDisplay]::EnsureNative()
Write-Host ('内屏模式修复: ' + $r1) -ForegroundColor Green

Start-Sleep -Milliseconds 800
$ext = [RepairDisplay]::ExternalCount()
$act = [RepairDisplay]::ActiveCount()
if ($ext -gt 0 -and $act -lt 2) {
    $r2 = [RepairDisplay]::Extend()
    Start-Sleep -Milliseconds 800
    Write-Host ('恢复扩展布局: ' + $r2 + '，现在活动屏 ' + [RepairDisplay]::ActiveCount() + ' 块') -ForegroundColor Green
} else {
    Write-Host ('布局已正确（活动屏 ' + $act + ' 块，外接屏 ' + $ext + ' 块）') -ForegroundColor Green
}
Write-Host ('修复后内屏: ' + [RepairDisplay]::InternalInfo())
Write-Host '完成。若仍有黑边：到「设置 → 系统 → 显示」确认缩放模式为「保持显示缩放比例」且分辨率为面板原生值。' -ForegroundColor DarkGray
