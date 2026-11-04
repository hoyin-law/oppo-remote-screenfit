<#
  Probe-OPPO-Pipeline.ps1 —— 只读分析 OPPO 互联远控的采集/编码管线。
  用法：
    pwsh -NoProfile -File scripts\Probe-OPPO-Pipeline.ps1
    pwsh -NoProfile -File scripts\Probe-OPPO-Pipeline.ps1 -Last 10 -Output C:\temp\report.json

  对每份 desktop_agent 日志输出：
    - 会话起始时间、agent 初始化时枚举到的显示器数量（virtual / orayidd / useidd）
    - 选择的采集模式（0-full / 1-gditracer / 2-mirrortracer / 3-dwm / 4-idd）
    - IddCxDevice open 失败次数、DXGI duplication 失败次数
    - 首次/末次 send>0 帧、连续无帧的最长间隔（秒）
  用于判断「虚拟屏被切走后视频停帧」发生在哪一环。
#>

[CmdletBinding()]
param(
    [string]$LogDir = (Join-Path $env:APPDATA 'O+Connect\devicespace'),
    [int]$Last = 0,
    [string]$Output = ''
)

$ErrorActionPreference = 'Stop'
$script:SendPatterns = @(
    'CSingleDesktop\].*?send\s+(\d+)',
    'EncoderQualityCalc\].*?send=(\d+)',
    '\[desktop\].*?\bsend\s+(\d+)'
)

function Get-LogStats([string]$path) {
    $name = Split-Path -Leaf $path
    $stats = [ordered]@{
        log = $name
        sessionStart = $null
        monitorCount = $null
        virtualCount = $null
        orayIddCount = $null
        useIdd = $null
        captureMode = $null
        iddOpenFailures = 0
        dxgiDuplicationFailures = 0
        displayChanges = 0
        firstConsumedFrame = $null
        lastConsumedFrame = $null
        consumedSamples = 0
        sendSamples = 0
        maxNoFrameGapSec = $null
        frameGaps = @()
    }
    if (-not (Test-Path $path)) { return $stats }

    $lines = Get-Content $path -ErrorAction SilentlyContinue
    $consumedTimes = New-Object System.Collections.Generic.List[datetime]
    $sampleTimes = New-Object System.Collections.Generic.List[datetime]

    foreach ($l in $lines) {
        if ($l -match '^\[[^\]]*\]\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
            $ts = $null
            try { $ts = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { }
        } else { $ts = $null }

        if (-not $stats.sessionStart -and $ts) { $stats.sessionStart = $ts }

        if ($l -match 'monitor \[ count (\d+) virtual (\d+) orayidd (\d+) \], useidd (\d+)') {
            $stats.monitorCount = [int]$matches[1]
            $stats.virtualCount = [int]$matches[2]
            $stats.orayIddCount = [int]$matches[3]
            $stats.useIdd = [int]$matches[4]
        }
        if ($l -match 'Create new capture mode=(\d+)') {
            $stats.captureMode = [int]$matches[1]
        }
        if ($l -match 'IddCxDevice\] open device fail') { $stats.iddOpenFailures++ }
        if ($l -match 'Failed to get duplicate output|Failed to acquire next frame') { $stats.dxgiDuplicationFailures++ }
        if ($l -match 'Display changed') { $stats.displayChanges++ }

        $send = $null
        foreach ($pat in $script:SendPatterns) {
            $m = [regex]::Match($l, $pat)
            if ($m.Success) { $send = [int]$m.Groups[1].Value; break }
        }
        if ($null -ne $send) {
            $stats.sendSamples++
            if ($ts) {
                $sampleTimes.Add($ts)
                if ($send -gt 0) { $consumedTimes.Add($ts) }
            }
        }
    }

    if ($consumedTimes.Count -gt 0) {
        $stats.firstConsumedFrame = $consumedTimes[0]
        $stats.lastConsumedFrame = $consumedTimes[$consumedTimes.Count - 1]
        $stats.consumedSamples = $consumedTimes.Count
    }

    # 连续无帧最长间隔：在两次成功出帧之间、或最后一次出帧之后到日志结尾
    $times = @($sampleTimes)
    $gaps = New-Object System.Collections.Generic.List[double]
    if ($times.Count -gt 1) {
        for ($i = 1; $i -lt $times.Count; $i++) {
            $gap = ($times[$i] - $times[$i - 1]).TotalSeconds
            if ($gap -ge 30) { $gaps.Add([math]::Round($gap, 1)) }
        }
    }
    if ($gaps.Count -gt 0) {
        $stats.frameGaps = @($gaps)
        $stats.maxNoFrameGapSec = ($gaps | Measure-Object -Maximum).Maximum
    }
    return $stats
}

Write-Host ("扫描目录: " + $LogDir)
$files = Get-ChildItem (Join-Path $LogDir 'desktop_agent.*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($Last -gt 0) { $files = $files | Select-Object -First $Last }
if (-not $files) { Write-Host '未找到 desktop_agent 日志' -ForegroundColor Yellow; exit 1 }

$all = @()
foreach ($f in ($files | Sort-Object LastWriteTime)) {
    $all += [pscustomobject](Get-LogStats $f.FullName)
}

Write-Host ''
Write-Host ('会话数: ' + $all.Count)
$all | Select-Object log, sessionStart, monitorCount, virtualCount, orayIddCount, useIdd, captureMode, iddOpenFailures, dxgiDuplicationFailures, consumedSamples, sendSamples, maxNoFrameGapSec |
    Format-Table -AutoSize | Out-String -Width 220 | Write-Host

$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    logDir = $LogDir
    sessions = $all.Count
    withVirtualDisplayAtInit = @($all | Where-Object { $_.virtualCount -gt 0 }).Count
    withOrayIddAtInit = @($all | Where-Object { $_.orayIddCount -gt 0 }).Count
    withUseIdd = @($all | Where-Object { $_.useIdd -eq 1 }).Count
    byCaptureMode = @($all | Group-Object captureMode | ForEach-Object { [ordered]@{ mode = $_.Name; count = $_.Count } })
    sessionsWithLongNoFrameGap = @($all | Where-Object { $_.maxNoFrameGapSec -ne $null }).Count
    details = $all
}

if ($Output) {
    $json = $summary | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Output, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('已写出: ' + $Output) -ForegroundColor Green
}
Write-Host ''
Write-Host ('结论摘要: 会话 ' + $summary.sessions + ' 个；初始化时见到虚拟屏 ' + $summary.withVirtualDisplayAtInit + ' 个；见到 OrayIdd ' + $summary.withOrayIddAtInit + ' 个；useidd=1 的 ' + $summary.withUseIdd + ' 个；存在 ≥30s 无帧间隔的 ' + $summary.sessionsWithLongNoFrameGap + ' 个。')
