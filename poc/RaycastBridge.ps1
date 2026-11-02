param(
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'raycast-bridge.json')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
New-Item -ItemType Directory -Force $LogDir | Out-Null
$log = Join-Path $LogDir 'raycast-bridge.log'

# ---- 配置：默认关闭，绝不硬编码劫持 Win 键 ----
if (-not (Test-Path $ConfigPath)) {
    @{ enabled = $false; uri = 'raycast://' } | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "未找到配置，已生成默认配置（enabled=false）：$ConfigPath" -ForegroundColor Yellow
    Write-Host '未启用：Win 键保持系统开始菜单行为。' -ForegroundColor Yellow
    exit 0
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.enabled) {
    Write-Host 'Raycast 桥接未启用（配置 enabled=false）：Win 键保持系统开始菜单行为。' -ForegroundColor Yellow
    exit 0
}
$uri = if ($cfg.uri) { [string]$cfg.uri } else { 'raycast://' }
if (-not (Get-Process Raycast -ErrorAction SilentlyContinue)) {
    Write-Host '未检测到 Raycast 进程，为避免吞掉 Win 键，桥接不启动。' -ForegroundColor Yellow
    exit 0
}

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
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string ProcessOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return ""; } }
  static System.Collections.Concurrent.ConcurrentQueue<long> q = new System.Collections.Concurrent.ConcurrentQueue<long>();
  public static long TakeTicks() { long t; return q.TryDequeue(out t) ? t : 0; }
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
          if (!otherKey && dur < 700) q.Enqueue(DateTime.UtcNow.Ticks);
        }
      } else if (down && winDown) { otherKey = true; }
    }
    return CallNextHookEx(hook, n, wp, lp);
  }
}
'@

if (-not [WinBridge]::Start()) { Write-Host '安装键盘钩子失败' -ForegroundColor Red; exit 1 }

function Invoke-BareWin([long]$ticks) {
    $fgNow = [WinBridge]::GetForegroundWindow()
    if ([WinBridge]::ProcessOf($fgNow) -eq 'Raycast') {
        Add-Content -Path $log -Value ("{0}  裸Win -> Launcher 在前台，忽略" -f (Get-Date -Format 'HH:mm:ss.fff'))
        return
    }
    $t0 = Get-Date
    Start-Process $uri
    $fg = [IntPtr]::Zero
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 150
        $fg = [WinBridge]::GetForegroundWindow()
        if ([WinBridge]::ProcessOf($fg) -eq 'Raycast') { break }
    }
    $ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds)
    if ([WinBridge]::ProcessOf($fg) -eq 'Raycast') {
        Add-Content -Path $log -Value ("{0}  裸Win -> 打开 Launcher (hwnd={1}, 启动耗时 {2}ms)" -f (Get-Date -Format 'HH:mm:ss.fff'), $fg, $ms)
    } else {
        Add-Content -Path $log -Value ("{0}  裸Win -> 打开失败，前台={1}" -f (Get-Date -Format 'HH:mm:ss.fff'), [WinBridge]::ProcessOf($fg))
    }
}

Write-Host "Win 键桥接已启用（配置：$ConfigPath，目标：$uri）。Ctrl+C 退出。" -ForegroundColor Green
Write-Host "日志：$log"
try {
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        $ticks = [WinBridge]::TakeTicks()
        while ($ticks -ne 0) { Invoke-BareWin $ticks; $ticks = [WinBridge]::TakeTicks() }
        Start-Sleep -Milliseconds 10
    }
} finally {
    [WinBridge]::Stop()
}
