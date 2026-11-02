param(
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
New-Item -ItemType Directory -Force $LogDir | Out-Null
$log = Join-Path $LogDir 'raycast-bridge.log'

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class WinBridge {
  [StructLayout(LayoutKind.Sequential)] public struct KBD { public int vk; public int scan; public int flags; public int time; public IntPtr extra; }
  delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);
  static Proc proc; static IntPtr hook;
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr hMod, uint tid);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  public static bool Start() { proc = Cb; hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0); return hook != IntPtr.Zero; }
  public static void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
  // 返回 true 表示这次是“远程注入的裸 Win”（按下/抬起成对、期间没按别的键）
  static bool winDown = false; static DateTime winDownAt; static bool otherKey = false;
  public static event Action<string> OnEvent;
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
          if (!otherKey && dur < 700 && OnEvent != null) OnEvent("bare-win");
        }
      } else if (down && winDown) { otherKey = true; }
    }
    return CallNextHookEx(hook, n, wp, lp);
  }
  public static string ForegroundProcess() {
    uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return ""; }
  }
}
'@

if (-not [WinBridge]::Start()) { Write-Host '安装键盘钩子失败' -ForegroundColor Red; exit 1 }

$script:bridge = [WinBridge]
$script:handler = {
    param($what)
    try {
        $fg = [WinBridge]::ForegroundProcess()
        if ($fg -eq 'Raycast') {
            [WinBridge]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
            [WinBridge]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
            Add-Content -Path $log -Value ("{0}  裸Win -> 关闭 Raycast" -f (Get-Date -Format 'HH:mm:ss.fff'))
        } else {
            Start-Process 'raycast://'
            Add-Content -Path $log -Value ("{0}  裸Win -> 唤起 Raycast" -f (Get-Date -Format 'HH:mm:ss.fff'))
        }
    } catch {
        Add-Content -Path $log -Value ("{0}  失败: {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $_.Exception.Message)
    }
}
Register-ObjectEvent -InputObject ([WinBridge]) -EventName OnEvent -Action $script:handler | Out-Null

Write-Host 'Win 键桥接已启动（仅响应远程注入的裸 Win）。Ctrl+C 退出。' -ForegroundColor Green
Write-Host "日志：$log"
try {
    while ($true) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
} finally {
    [WinBridge]::Stop()
}
