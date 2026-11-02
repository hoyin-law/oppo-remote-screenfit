param(
    [int]$DurationSec = 0,
    [switch]$SelfTest,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
New-Item -ItemType Directory -Force $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $LogDir "windows-$stamp.jsonl"

Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class WinWatch {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  public static List<string> Visible() {
    var list = new List<string>();
    EnumWindows((h, l) => {
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.Length == 0) return true;
      var t = new StringBuilder(256); GetWindowText(h, t, 256);
      string cls = c.ToString(), title = t.ToString();
      bool interesting = cls.IndexOf("CoreWindow", StringComparison.OrdinalIgnoreCase) >= 0
        || cls == "#32770" || cls.IndexOf("XamlExplorerHostIslandWindow", StringComparison.OrdinalIgnoreCase) >= 0
        || cls.IndexOf("DV2ControlHost", StringComparison.OrdinalIgnoreCase) >= 0
        || title == "开始" || title == "Start" || title == "运行" || title == "Run"
        || title.IndexOf("任务视图", StringComparison.OrdinalIgnoreCase) >= 0 || title.IndexOf("Task View", StringComparison.OrdinalIgnoreCase) >= 0;
      if (!interesting) return true;
      bool vis = IsWindowVisible(h);
      list.Add(cls + "|" + title + "|" + (vis ? "1" : "0"));
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static void PressWin() { keybd_event(0x5B, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(80); keybd_event(0x5B, 0, 2, IntPtr.Zero); }
  public static void PressCtrlEsc() { keybd_event(0x11, 0, 0, IntPtr.Zero); keybd_event(0x1B, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(80); keybd_event(0x1B, 0, 2, IntPtr.Zero); keybd_event(0x11, 0, 2, IntPtr.Zero); }
  public static void PressEsc() { keybd_event(0x1B, 0, 0, IntPtr.Zero); keybd_event(0x1B, 0, 2, IntPtr.Zero); }
}
'@

$known = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($w in [WinWatch]::Visible()) { [void]$known.Add($w) }
$sw = New-Object System.IO.StreamWriter($out, $false, (New-Object System.Text.UTF8Encoding($false)))
$sw.AutoFlush = $true

Write-Host "窗口变化监测开始：$out" -ForegroundColor Green
Write-Host '请依次按：单独 Win、Win+R、Win+D、Win+Tab；每次间隔 3 秒。' -ForegroundColor Cyan
if ($SelfTest) {
    Write-Host '自检：3 秒后模拟按 Win 键，再按 Esc 关闭…' -ForegroundColor Yellow
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 3000
    $t.Add_Tick({ $t.Stop(); [WinWatch]::PressCtrlEsc(); Start-Sleep -Milliseconds 800; [WinWatch]::PressEsc() })
    $t.Start()
}
$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }
$script:running = $true
try {
    while ($script:running -and (Get-Date) -lt $deadline) {
        $cur = [WinWatch]::Visible()
        $curSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($w in $cur) { [void]$curSet.Add($w) }
        foreach ($w in $cur) {
            if (-not $known.Contains($w)) {
                $sw.WriteLine('{"t":"' + (Get-Date -Format o) + '","event":"show","w":"' + ($w.Replace('\','\\').Replace('"','\"')) + '"}')
            }
        }
        foreach ($w in $known) {
            if (-not $curSet.Contains($w)) {
                $sw.WriteLine('{"t":"' + (Get-Date -Format o) + '","event":"hide","w":"' + ($w.Replace('\','\\').Replace('"','\"')) + '"}')
            }
        }
        $known = $curSet
        Start-Sleep -Milliseconds 120
    }
} finally {
    $sw.Flush(); $sw.Dispose()
}
Write-Host "已保存：$out" -ForegroundColor Green

