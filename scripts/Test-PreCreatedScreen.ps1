<#
  Test-PreCreatedScreen.ps1 —— 实验脚本：先建好平板分辨率的虚拟屏并切到「仅虚拟屏」，
  再让平板发起 OPPO 远控，用来验证「预建屏（会话开始前就绪）能否让 OPPO 稳定出帧」。

  用法：
    # 1) 在平板上准备好，电脑上运行（会请求管理员权限）：
    pwsh -NoProfile -File scripts\Test-PreCreatedScreen.ps1 -Device Pad5Pro
    # 2) 看到提示后，用平板 OPPO 互联连这台电脑（普通远程控制，不要用屏幕扩展）
    # 3) 至少观察 2~3 分钟；按 Enter 结束，脚本会自动恢复物理扩展并打印出帧统计

  只做实验，不修改插件配置；结束后务必确认物理屏恢复为「扩展」。
#>

[CmdletBinding()]
param(
    [string]$Device = 'Pad5Pro',
    [int]$WaitMinutes = 10,
    [switch]$DryRun,
    [switch]$RemoveAfter,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$Tool = Join-Path $env:LOCALAPPDATA 'DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe'
$cfgTool = Get-ScreenFitSetting 'VirtualDisplayTool'; if ($cfgTool) { $Tool = [string]$cfgTool }
$LogDir = Join-Path $env:APPDATA 'O+Connect\devicespace'
$TaskName = 'OPPO平板分辨率适配'

# 设备表唯一来源：ScreenFit.Core.ps1
$CorePath = Join-Path (Split-Path -Parent $PSCommandPath) 'ScreenFit.Core.ps1'
if (-not (Test-Path $CorePath)) { $CorePath = Join-Path $env:LOCALAPPDATA 'OPPO-ScreenFit\ScreenFit.Core.ps1' }
if (Test-Path $CorePath) { . $CorePath; Initialize-ScreenFit -StateDir $env:TEMP }
$Catalog = if (Get-Command Get-DeviceCatalog -ErrorAction SilentlyContinue) { Get-DeviceCatalog } else { @() }
$Profiles = @{}
foreach ($e in $Catalog) { $Profiles[$e.Key] = @{ W = $e.W; H = $e.H; Label = $e.Label } }
if ($List) {
    foreach ($e in $Catalog) { Write-Host ("  " + $e.Key.PadRight(18) + $e.Label + "  " + $e.W + "x" + $e.H + $(if ($e.Verified) { '' } else { '  (规格未核实)' })) }
    exit 0
}
if ($Device -ne 'Status' -and -not $Profiles.ContainsKey($Device)) {
    Write-Host ("无法识别设备: " + $Device) -ForegroundColor Red
    Write-Host ('可用 Key: ' + (($Profiles.Keys | Sort-Object) -join ', ')) -ForegroundColor Yellow
    exit 1
}

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;using System.Collections.Generic;
public static class SFExpTopo {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID a; public uint id; public uint mi; public uint st; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID a; public uint id; public uint mi; public uint tech; public uint rot; public uint scl; public uint rn; public uint rd; public uint slo; public int avail; public uint st; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC s; public TGT t; public uint flags; }
  [StructLayout(LayoutKind.Explicit, Size=64)] public struct MODE {
    [FieldOffset(0)] public uint infoType;
    [FieldOffset(4)] public uint id;
    [FieldOffset(8)] public LUID a;
    [FieldOffset(16)] public uint width;
    [FieldOffset(20)] public uint height;
    [FieldOffset(24)] public uint pixelFormat;
    [FieldOffset(28)] public int posX;
    [FieldOffset(32)] public int posY;
  }
  [StructLayout(LayoutKind.Sequential)] public struct HDR { public uint type; public uint size; public LUID a; public uint id; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TDN { public HDR h; public uint flags; public uint ot; public ushort mfg; public ushort prod; public uint conn; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string name; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }
  [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
  [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint np, PATH[] p, uint nm, MODE[] m, uint f);
  [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TDN n);
  const uint ALL=1, USE=0x20, APPLY=0x80, INVALID=0xFFFFFFFF;
  static string Name(PATH p){ var n=new TDN(); n.h.type=2; n.h.size=(uint)Marshal.SizeOf(typeof(TDN)); n.h.a=p.t.a; n.h.id=p.t.id; if(DisplayConfigGetDeviceInfo(ref n)==0) return n.name+"|"+n.path; return ""; }
  static bool IsVirtual(PATH p){ var n=Name(p).ToLowerInvariant(); return n.Contains("opextscreen")||n.Contains("opdisplaydriver")||n.Contains("deld0e6"); }
  static PATH[] All(){ uint np,nm; int e=GetDisplayConfigBufferSizes(ALL,out np,out nm); if(e!=0) return new PATH[0]; var p=new PATH[np]; var m=new MODE[nm]; e=QueryDisplayConfig(ALL,ref np,p,ref nm,m,IntPtr.Zero); if(e!=0) return new PATH[0]; var r=new PATH[np]; Array.Copy(p,r,np); return r; }
  static PATH[] Active(){ uint np,nm; int e=GetDisplayConfigBufferSizes(2,out np,out nm); if(e!=0) return new PATH[0]; var p=new PATH[np]; var m=new MODE[nm]; e=QueryDisplayConfig(2,ref np,p,ref nm,m,IntPtr.Zero); if(e!=0) return new PATH[0]; var r=new PATH[np]; Array.Copy(p,r,np); return r; }
  public static bool VirtualExists(){ foreach(var p in All()) if(IsVirtual(p)) return true; return false; }
  public static int ActiveCount(){ return Active().Length; }
  public static int ExternalCount(){ var seen=new HashSet<string>(); foreach(var p in All()){ if(IsVirtual(p)) continue; if(p.t.tech==0x80000000) continue; var n=Name(p); int bar=n.IndexOf('|'); string dn=bar>=0?n.Substring(0,bar):n; if(!string.IsNullOrEmpty(dn)) seen.Add(dn); } return seen.Count; }
  public static string ActiveNames(){ var l=new List<string>(); foreach(var p in Active()){ var n=Name(p); int bar=n.IndexOf('|'); if(bar>=0) n=n.Substring(0,bar); if(!string.IsNullOrEmpty(n)) l.Add(n); } return string.Join(",",l.ToArray()); }
  public static string OnlyVirtual(){ foreach(var p in All()){ if(!IsVirtual(p)) continue; var q=p; q.s.mi=INVALID; q.t.mi=INVALID; return "err="+SetDisplayConfig(1,new PATH[]{q},0,null,USE|APPLY); } return "no-virtual"; }
  public static string Extend(){ return "err="+SetDisplayConfig(0,null,0,null,APPLY|0x4); }
}
'@

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Show-State([string]$tag) {
    Write-Host ("  [{0}] 活动屏 {1} 块: {2}" -f $tag, [SFExpTopo]::ActiveCount(), [SFExpTopo]::ActiveNames()) -ForegroundColor DarkGray
}
function Get-FrameStats([datetime]$from, [datetime]$to) {
    $log = Get-ChildItem $LogDir -Filter 'desktop_agent.*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return $null }
    $samples = 0; $gt0 = 0; $lastConsumed = $null; $firstConsumed = $null
    foreach ($l in (Get-Content $log.FullName -ErrorAction SilentlyContinue)) {
        if ($l -notmatch '^\[[^\]]*\]\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { continue }
        try { $ts = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
        if ($ts -lt $from -or $ts -gt $to) { continue }
        $send = $null
        $m = [regex]::Match($l, 'EncoderQualityCalc\].*?send=(\d+)'); if ($m.Success) { $send = [int]$m.Groups[1].Value }
        if ($null -eq $send) { $m = [regex]::Match($l, 'CSingleDesktop\].*?send\s+(\d+)'); if ($m.Success) { $send = [int]$m.Groups[1].Value } }
        if ($null -eq $send) { $m = [regex]::Match($l, '\[desktop\].*?\bsend\s+(\d+)'); if ($m.Success) { $send = [int]$m.Groups[1].Value } }
        if ($null -eq $send) { continue }
        $samples++
        if ($send -gt 0) { $gt0++; if (-not $firstConsumed) { $firstConsumed = $ts }; $lastConsumed = $ts }
    }
    return [pscustomobject]@{ Log = $log.Name; Samples = $samples; SendGt0 = $gt0; FirstConsumed = $firstConsumed; LastConsumed = $lastConsumed }
}

if ($Device -eq 'Status') {
    Write-Host '=== 当前显示 ===' -ForegroundColor Cyan
    Write-Host ("  活动屏 {0} 块: {1}，外接屏 {2} 块，虚拟屏存在={3}" -f [SFExpTopo]::ActiveCount(), [SFExpTopo]::ActiveNames(), [SFExpTopo]::ExternalCount(), [SFExpTopo]::VirtualExists())
    exit 0
}

$p = $Profiles[$Device]
Write-Host ("实验目标: " + $p.Label + " " + $p.W + "x" + $p.H) -ForegroundColor Cyan
Show-State '初始'

if ($DryRun) {
    Write-Host "[DryRun] 将执行：停止计划任务 -> 创建虚拟屏 -> 切换为仅虚拟屏 -> 等待你完成远控 -> 恢复扩展" -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权…' -ForegroundColor Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Device',$Device,'-WaitMinutes',$WaitMinutes)
    if ($RemoveAfter) { $a += '-RemoveAfter' }
    Start-Process 'powershell.exe' -Verb RunAs -ArgumentList $a | Out-Null
    exit 0
}
if (-not (Test-Path $Tool)) { Write-Host ("找不到 OPPO 虚拟显示器工具: " + $Tool) -ForegroundColor Red; exit 1 }

Write-Host '1/4 停止插件计划任务（避免它参与干扰）' -ForegroundColor Yellow
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host '2/4 创建虚拟屏' -ForegroundColor Yellow
Get-Process OPDisplayDriverTool -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Start-Process -FilePath $Tool -ArgumentList @('--operation','create','--width',"$($p.W)",'--height',"$($p.H)",'--freq','60') -WindowStyle Hidden | Out-Null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if ([SFExpTopo]::VirtualExists()) { break }
}
if (-not [SFExpTopo]::VirtualExists()) { Write-Host '虚拟屏创建失败，中止' -ForegroundColor Red; exit 1 }
Show-State '建屏后'

Write-Host '3/4 切换到仅虚拟屏（只应用一次，不再重复刷新）' -ForegroundColor Yellow
Write-Host ("  OnlyVirtual -> " + [SFExpTopo]::OnlyVirtual())
Start-Sleep -Seconds 2
Show-State '切换后'

$start = Get-Date
Write-Host ''
Write-Host '================ 现在开始 ================' -ForegroundColor Green
Write-Host '请在平板上用 OPPO 互联「远程控制」连接这台电脑，至少观察 2~3 分钟。' -ForegroundColor Green
Write-Host '重点看：画面是否持续刷新（不冻结）、比例是否满屏。' -ForegroundColor Green
Write-Host ("最多等待 {0} 分钟，或按 Enter 提前结束。" -f $WaitMinutes) -ForegroundColor Green
Write-Host '=========================================' -ForegroundColor Green
$deadline = (Get-Date).AddMinutes($WaitMinutes)
while ((Get-Date) -lt $deadline) {
    if ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true); break }
    Start-Sleep -Milliseconds 300
}

$end = Get-Date
Write-Host ''
Write-Host '4/4 恢复物理扩展布局' -ForegroundColor Yellow
Write-Host ("  Extend -> " + [SFExpTopo]::Extend())
Start-Sleep -Seconds 2
Show-State '恢复后'

$stats = Get-FrameStats -from $start -to $end
Write-Host ''
Write-Host '=== 本次实验出帧统计 ===' -ForegroundColor Cyan
if ($stats) {
    Write-Host ("  日志: " + $stats.Log)
    Write-Host ("  帧样本: " + $stats.Samples + "，其中 send>0: " + $stats.SendGt0)
    Write-Host ("  首次出帧: " + $stats.FirstConsumed + "   末次出帧: " + $stats.LastConsumed)
    if ($stats.SendGt0 -gt 0) { Write-Host '  结论: 预建屏方案【有出帧】——记录持续时长，判断能否达 10 分钟。' -ForegroundColor Green }
    else { Write-Host '  结论: 预建屏方案【没有出帧】——OPPO 无法采集该虚拟屏，需换方案。' -ForegroundColor Red }
} else { Write-Host '  未找到帧统计日志' -ForegroundColor Yellow }

if ($RemoveAfter) {
    Write-Host '清理：移除虚拟屏设备' -ForegroundColor Yellow
    Start-Process -FilePath $Tool -ArgumentList @('--operation','remove') -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    & pnputil /remove-device "SWD\OPDISPLAYDRIVER\OPDISPLAYDRIVER" 2>$null | Out-Null
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Write-Host '完成。若屏幕未恢复，按 Win+P 选择「扩展」。' -ForegroundColor Green
