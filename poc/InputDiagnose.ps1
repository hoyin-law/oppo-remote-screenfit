<#
  InputDiagnose.ps1 —— V2 PoC：远程外接键鼠输入诊断

  目的：
    在 Windows 本机记录“远程客户端（OPPO 互联）实际注入到系统的键鼠事件”，
    用来判断平板专属键盘/触控板的按键、触控板手势、Windows 键等
    是否真的到达电脑、以什么形式到达（键码/扫描码/鼠标事件/滚轮）。

  用法（建议管理员运行，覆盖管理员权限应用）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\InputDiagnose.ps1

  自检（不连远程也能验证脚本本身）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\InputDiagnose.ps1 -SelfTest -DurationSec 4

  输出：
    poc\logs\input-<时间>.jsonl    原始事件（仅键码/坐标，不记录文字内容）
    poc\logs\summary-<时间>.txt    汇总
#>

param(
    [int]$DurationSec = 0,
    [switch]$SelfTest,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
New-Item -ItemType Directory -Force $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonl = Join-Path $LogDir "input-$stamp.jsonl"
$summaryFile = Join-Path $LogDir "summary-$stamp.txt"

Add-Type -TypeDefinition @'
using System;using System.IO;using System.Runtime.InteropServices;using System.Text;
public static class OPPOInputHook {
  [StructLayout(LayoutKind.Sequential)] public struct KBD { public int vk; public int scan; public int flags; public int time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct MS { public PT pt; public int mouseData; public int flags; public int time; public IntPtr extra; }
  delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);
  static Proc kbP, msP; static IntPtr kbH, msH; static StreamWriter w; static object gate = new object();
  static int lastX, lastY; static bool hasLast;
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr hMod, uint tid);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr wp, IntPtr lp);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

  public static void TestMouse() { mouse_event(0x0001, 10, 5, 0, IntPtr.Zero); System.Threading.Thread.Sleep(120); mouse_event(0x0001, -10, -5, 0, IntPtr.Zero); }
  public static bool Start(string path) {
    w = new StreamWriter(path, true, new UTF8Encoding(false)); w.AutoFlush = true;
    kbP = Kb; msP = Ms;
    IntPtr mod = GetModuleHandle(null);
    kbH = SetWindowsHookEx(13, kbP, mod, 0);
    msH = SetWindowsHookEx(14, msP, mod, 0);
    return kbH != IntPtr.Zero && msH != IntPtr.Zero;
  }
  public static void Stop() {
    if (kbH != IntPtr.Zero) { UnhookWindowsHookEx(kbH); kbH = IntPtr.Zero; }
    if (msH != IntPtr.Zero) { UnhookWindowsHookEx(msH); msH = IntPtr.Zero; }
    if (w != null) { w.Flush(); w.Dispose(); w = null; }
  }
  static void Emit(string json) { lock (gate) { if (w != null) w.WriteLine(json); } }
  static IntPtr Kb(int n, IntPtr wp, IntPtr lp) {
    if (n >= 0) {
      var d = (KBD)Marshal.PtrToStructure(lp, typeof(KBD));
      int msg = wp.ToInt32(); bool down = (msg == 0x100 || msg == 0x104);
      Emit("{\"t\":\"" + DateTime.Now.ToString("O") + "\",\"kind\":\"key\",\"down\":" + (down ? "true" : "false") + ",\"vk\":" + d.vk + ",\"scan\":" + d.scan + ",\"flags\":" + d.flags + "}");
    }
    return CallNextHookEx(kbH, n, wp, lp);
  }
  static IntPtr Ms(int n, IntPtr wp, IntPtr lp) {
    if (n >= 0) {
      var d = (MS)Marshal.PtrToStructure(lp, typeof(MS));
      int dx = 0, dy = 0;
      if (hasLast) { dx = d.pt.x - lastX; dy = d.pt.y - lastY; }
      lastX = d.pt.x; lastY = d.pt.y; hasLast = true;
      int wheel = (d.mouseData >> 16) & 0xffff; if (wheel > 32767) wheel -= 65536;
      Emit("{\"t\":\"" + DateTime.Now.ToString("O") + "\",\"kind\":\"mouse\",\"msg\":" + wp.ToInt32() + ",\"x\":" + d.pt.x + ",\"y\":" + d.pt.y + ",\"dx\":" + dx + ",\"dy\":" + dy + ",\"wheel\":" + wheel + ",\"flags\":" + d.flags + "}");
    }
    return CallNextHookEx(msH, n, wp, lp);
  }
}
'@

if (-not [OPPOInputHook]::Start($jsonl)) {
    Write-Host '安装输入钩子失败，请用管理员 PowerShell 运行。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== 输入诊断已开始 ===' -ForegroundColor Green
Write-Host "日志：$jsonl"
Write-Host ''
Write-Host '请在远程会话中，用平板专属键盘/触控板依次做：' -ForegroundColor Cyan
Write-Host '  1) 字母数字：a b c 1 2 3；Shift/Ctrl/Alt/Tab/Esc/Enter/Backspace/方向键/F1'
Write-Host '  2) Windows 键：单独按 Win、Win+R、Win+D、Win+Tab、Alt+Tab'
Write-Host '  3) 触控板：单指移动、单击、双击、双指滚动、双指右键、三指上滑/左右'
Write-Host '  4) 键盘上的多媒体键（音量/播放等，如果有）'
Write-Host ''
if ($SelfTest) {
    Write-Host '自检模式：将自动发送 a / 1 / Enter 与一次鼠标移动…' -ForegroundColor Yellow
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 700
    $t.Add_Tick({
        $t.Stop()
        [System.Windows.Forms.SendKeys]::SendWait('a')
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('1')
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        [OPPOInputHook]::TestMouse()
    })
    $t.Start()
}
if ($DurationSec -gt 0) {
    Write-Host "将在 $DurationSec 秒后自动停止…" -ForegroundColor Yellow
} else {
    Write-Host '按 Ctrl+C 停止并生成汇总…' -ForegroundColor Yellow
}

$script:running = $true
$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }
try {
    while ($script:running -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
} finally {
    [OPPOInputHook]::Stop()
}

# 汇总
$lines = Get-Content $jsonl -ErrorAction SilentlyContinue
$keys = @(); $buttons = @{}; $wheel = 0; $moves = 0
foreach ($l in $lines) {
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if ($o.kind -eq 'key') { $keys += [pscustomobject]@{ vk = [int]$o.vk; scan = [int]$o.scan; down = [bool]$o.down; flags = [int]$o.flags } }
    elseif ($o.kind -eq 'mouse') {
        $msg = [int]$o.msg
        if ($msg -eq 0x200) { $moves++ }
        if ($msg -in 0x201,0x202,0x204,0x205,0x207,0x208) { $buttons[$msg] = 1 + ($buttons[$msg]) }
        if ($msg -in 0x20A,0x20E) { $wheel += [int]$o.wheel }
    }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("输入诊断汇总 $stamp")
[void]$sb.AppendLine("事件数: $($lines.Count)")
[void]$sb.AppendLine("鼠标移动事件: $moves")
[void]$sb.AppendLine("滚轮总量: $wheel")
[void]$sb.AppendLine("鼠标按键事件: " + (($buttons.GetEnumerator() | ForEach-Object { ('0x{0:X}={1}' -f $_.Key, $_.Value) }) -join ', '))
$winKeys = $keys | Where-Object { $_.vk -in 0x5B,0x5C }
[void]$sb.AppendLine("Windows 键事件数: $($winKeys.Count)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('按下的键（vk / scan / 次数）:')
$keys | Where-Object { $_.down } | Group-Object vk, scan | Sort-Object Name | ForEach-Object {
    [void]$sb.AppendLine(('  vk=0x{0:X2} scan=0x{1:X2} count={2}' -f $_.Group[0].vk, $_.Group[0].scan, $_.Count))
}
$text = $sb.ToString()
$text | Set-Content -Path $summaryFile -Encoding UTF8
Write-Host ''
Write-Host $text
Write-Host "汇总已保存：$summaryFile" -ForegroundColor Green
Write-Host '把这个 jsonl + summary 发我，就能分析键盘/触控板/AI 键的差异。' -ForegroundColor Cyan

