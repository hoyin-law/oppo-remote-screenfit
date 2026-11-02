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
  delegate bool EnumProc(IntPtr h, IntPtr l);
  static Proc proc; static IntPtr hook;
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr hMod, uint tid);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  static IntPtr found;
  public static IntPtr FindByPid(int pid) {
    found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == (uint)pid) {
        if (IsWindowVisible(h) && GetWindowTextLength(h) > 0) { found = h; return false; }
        if (found == IntPtr.Zero) found = h;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static bool Start() { proc = Cb; hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0); return hook != IntPtr.Zero; }
  public static void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
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
}
'@

if (-not [WinBridge]::Start()) { Write-Host '安装键盘钩子失败' -ForegroundColor Red; exit 1 }

function Get-RaycastWindow {
    $p = Get-Process Raycast -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return [IntPtr]::Zero }
    if ($p.MainWindowHandle -ne 0) { return [IntPtr]$p.MainWindowHandle }
    return [WinBridge]::FindByPid($p.Id)
}

$script:hidden = $false
$script:handler = {
    param($what)
    try {
        $h = Get-RaycastWindow
        if ($script:hidden) {
            if ($h -ne [IntPtr]::Zero -and [WinBridge]::IsWindow($h)) {
                [WinBridge]::ShowWindow($h, 5) | Out-Null
                [WinBridge]::SetForegroundWindow($h) | Out-Null
                $script:hidden = $false
                Add-Content -Path $log -Value ("{0}  裸Win -> 重新显示 Raycast" -f (Get-Date -Format 'HH:mm:ss.fff'))
                return
            }
            $script:hidden = $false
        }
        if ($h -ne [IntPtr]::Zero -and [WinBridge]::IsWindow($h)) {
            if ([WinBridge]::IsWindowVisible($h)) {
                [WinBridge]::ShowWindow($h, 0) | Out-Null
                $script:hidden = $true
                Add-Content -Path $log -Value ("{0}  裸Win -> 隐藏 Raycast" -f (Get-Date -Format 'HH:mm:ss.fff'))
            } else {
                [WinBridge]::ShowWindow($h, 5) | Out-Null
                [WinBridge]::SetForegroundWindow($h) | Out-Null
                Add-Content -Path $log -Value ("{0}  裸Win -> 显示 Raycast" -f (Get-Date -Format 'HH:mm:ss.fff'))
            }
        } else {
            Start-Process 'raycast://'
            Start-Sleep -Milliseconds 400
            $h2 = Get-RaycastWindow
            if ($h2 -ne [IntPtr]::Zero) { [WinBridge]::SetForegroundWindow($h2) | Out-Null }
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
