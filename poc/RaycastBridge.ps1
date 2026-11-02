param(
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
New-Item -ItemType Directory -Force $LogDir | Out-Null
$log = Join-Path $LogDir 'raycast-bridge.log'

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class WinBridge {
  [StructLayout(LayoutKind.Sequential)] public struct KBD { public int vk; public int scan; public int flags; public int time; public IntPtr extra; }
  delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);
  static Proc proc; static IntPtr hook;
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr hMod, uint tid);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string ProcessOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return ""; } }
  static System.Collections.Concurrent.ConcurrentQueue<string> q = new System.Collections.Concurrent.ConcurrentQueue<string>();
  public static string Take() { string s; return q.TryDequeue(out s) ? s : null; }
  public static bool Start() { proc = Cb; hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0); return hook != IntPtr.Zero; }
  public static void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
  static bool winDown = false; static DateTime winDownAt; static bool otherKey = false;
  static IntPtr Cb(int n, IntPtr wp, IntPtr lp) {
    if (n >= 0) {
      var d = (KBD)Marshal.PtrToStructure(lp, typeof(KBD));
      int msg = wp.ToInt32(); bool down = (msg == 0x100 || msg == 0x104);
      bool injected = (d.flags & 0x10) != 0;
      bool isWin = (d.vk == 0x5B || d.vk == 0x5C);
      if (isWin && injected) {
        if (down) { winDown = true; winDownAt = DateTime.Now; otherKey = false; }
        else if (winDown) {
          var dur = (DateTime.Now - winDownAt).TotalMilliseconds;
          winDown = false;
          if (!otherKey && dur < 700) q.Enqueue("bare-win");
        }
      } else if (down && winDown) { otherKey = true; }
    }
    return CallNextHookEx(hook, n, wp, lp);
  }
}
'@

if (-not [WinBridge]::Start()) { Write-Host '安装键盘钩子失败' -ForegroundColor Red; exit 1 }

$script:launcherHwnd = [IntPtr]::Zero

function Invoke-BareWin {
    $fgNow = [WinBridge]::GetForegroundWindow()
    if ([WinBridge]::ProcessOf($fgNow) -eq 'Raycast') {
        Add-Content -Path $log -Value ("{0}  裸Win -> Launcher 在前台，忽略" -f (Get-Date -Format 'HH:mm:ss.fff'))
        return
    }
    Start-Process 'raycast://'
    $fg = [IntPtr]::Zero
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 200
        $fg = [WinBridge]::GetForegroundWindow()
        if ([WinBridge]::ProcessOf($fg) -eq 'Raycast') { break }
    }
    if ([WinBridge]::ProcessOf($fg) -eq 'Raycast') {
        $script:launcherHwnd = $fg
        Add-Content -Path $log -Value ("{0}  裸Win -> 打开 Launcher (hwnd={1})" -f (Get-Date -Format 'HH:mm:ss.fff'), $fg)
    } else {
        Add-Content -Path $log -Value ("{0}  裸Win -> 打开失败，前台={1}" -f (Get-Date -Format 'HH:mm:ss.fff'), [WinBridge]::ProcessOf($fg))
    }
}

Write-Host 'Win 键桥接（仅打开 launcher）已启动；关闭请用触控板点一下别处。Ctrl+C 退出。' -ForegroundColor Green
Write-Host "日志：$log"
try {
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        $ev = [WinBridge]::Take()
        while ($ev) { Invoke-BareWin; $ev = [WinBridge]::Take() }
        Start-Sleep -Milliseconds 30
    }
} finally {
    [WinBridge]::Stop()
}
