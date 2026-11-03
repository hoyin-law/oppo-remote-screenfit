<#
  RefreshProbe.ps1 —— V2 PoC：远程刷新率/帧率探测（只读日志，不改设置）

  监控 OPPO 互联 desktop_agent 日志，抓取：
    - 客户端请求帧率：OnProtoSetFrameRateV2 fps N
    - 主机实际限制：SetMaxFps set max frame rate=N
    - 客户端屏幕刷新率：DisplayRefreshRateDetect hz=N
    - 编码分辨率：encoder init h264 ok, WxH
    - 实际发送统计：Too few frames sent ... send N, fps M
    - 码率：bandwidth=...

  用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\RefreshProbe.ps1 [-DurationSec 300]
#>
param(
    [int]$DurationSec = 0,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $LogDir "refresh-$stamp.log"
$agentDir = Join-Path $env:APPDATA 'O+Connect\devicespace'

function Write-Line($s) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $s
    Add-Content -Path $out -Value $line -Encoding UTF8
    Write-Host $line
}

Write-Line "刷新率探测开始（只读），输出：$out"
Write-Line '请在远程里切换画质/帧率档位，每档停 3 秒。'

$seen = @{}
$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }
$lastFile = $null
while ((Get-Date) -lt $deadline) {
    $f = Get-ChildItem $agentDir -Filter 'desktop_agent.*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { Start-Sleep -Seconds 1; continue }
    if ($f.FullName -ne $lastFile) {
        $lastFile = $f.FullName
        Write-Line ("切换日志文件: " + $f.Name)
    }
    $lines = Get-Content $f.FullName -Tail 400 -ErrorAction SilentlyContinue
    foreach ($l in $lines) {
        if ($l -match 'OnProtoSetFrameRateV2 fps (\d+)') {
            $v = $matches[1]
            if ($seen["req:$v"] -ne $true) { $seen["req:$v"] = $true; Write-Line "客户端请求帧率 fps=$v" }
        } elseif ($l -match 'SetMaxFps set max frame rate=(\d+)') {
            $v = $matches[1]
            if ($seen["max:$v"] -ne $true) { $seen["max:$v"] = $true; Write-Line "主机限制帧率 max=$v" }
        } elseif ($l -match 'DisplayRefreshRateDetect hz=(\d+)') {
            $v = $matches[1]
            if ($seen["hz:$v"] -ne $true) { $seen["hz:$v"] = $true; Write-Line "客户端刷新率 hz=$v" }
        } elseif ($l -match 'encoder init h264 ok, (\d+x\d+)') {
            $v = $matches[1]
            if ($seen["res:$v"] -ne $true) { $seen["res:$v"] = $true; Write-Line "编码分辨率 $v" }
        } elseif ($l -match 'Too few frames sent.*send (\d+), fps (\d+)') {
            $k = "stat:$($matches[1]):$($matches[2])"
            if (-not $seen.ContainsKey($k)) {
                $seen[$k] = $true
                Write-Line ("发送统计 send=" + $matches[1] + " fps=" + $matches[2])
            }
        }
    }
    Start-Sleep -Milliseconds 500
}
Write-Line '探测结束。'
