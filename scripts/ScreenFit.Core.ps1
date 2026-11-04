<#
  ScreenFit.Core.ps1 —— 纯检测逻辑（无副作用，可被 Watcher.ps1 / Diagnose.ps1 / tests 复用）。
  只做：版本号、OPPO 日志解析、会话状态、观看端证据、决策表。
  不碰显示拓扑、不启动进程、不写状态文件。
#>

$script:ScreenFitVersion = '1.2.5'
$script:ScreenFitLogDir = $null
$script:ScreenFitStateDir = $null
$script:logOffsets = @{}
$script:logRemainders = @{}
$script:sessActive = $false
$script:sessDevice = $null
$script:sessStartTs = $null
$script:sessLastEventTs = [datetime]::MinValue
$script:sessLastEventType = ''

function Get-ScreenFitVersion { return $script:ScreenFitVersion }

function Initialize-ScreenFit([string]$LogDir, [string]$StateDir) {
    if ($LogDir) { $script:ScreenFitLogDir = $LogDir }
    if ($StateDir) { $script:ScreenFitStateDir = $StateDir }
    elseif ($LogDir) { $script:ScreenFitStateDir = $LogDir }
    $script:logOffsets = @{}
    $script:logRemainders = @{}
    $script:sessActive = $false
    $script:sessDevice = $null
    $script:sessStartTs = $null
    $script:sessLastEventTs = [datetime]::MinValue
    $script:sessLastEventType = ''
}

function Get-ScreenFitLogDir {
    # 测试钩子：设置 SCREENFIT_LOG_DIR 可让 Watcher/Diagnose 指向伪造的日志目录，用于集成测试
    if ($env:SCREENFIT_LOG_DIR) { return $env:SCREENFIT_LOG_DIR }
    if ($script:ScreenFitLogDir) { return $script:ScreenFitLogDir }
    return (Join-Path $env:APPDATA 'O+Connect\devicespace')
}

function Get-ScreenFitStateDir {
    if ($script:ScreenFitStateDir) { return $script:ScreenFitStateDir }
    return (Get-ScreenFitLogDir)
}

# 增量读取日志：避免每 500ms 重复 tail 两个 4000 行文件（高 CPU 的主因）
function Read-NewLines([string]$path) {
    $item = Get-Item $path -ErrorAction SilentlyContinue
    if (-not $item) { return @() }
    $len = [long]$item.Length

    if (-not $script:logOffsets.ContainsKey($path)) {
        $lines = @(Get-Content $path -Tail 4000 -ErrorAction SilentlyContinue)
        $script:logOffsets[$path] = $len
        $script:logRemainders[$path] = ''
        return $lines
    }

    $off = [long]$script:logOffsets[$path]
    if ($len -lt $off) { $off = 0; $script:logRemainders[$path] = '' }
    if ($len -eq $off) { return @() }

    $chunk = ''
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$fs.Seek($off, [System.IO.SeekOrigin]::Begin)
        $count = [int]($len - $off)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $fs.Close()
        $script:logOffsets[$path] = $off + $read
        $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } catch { return @() }

    $text = [string]$script:logRemainders[$path] + $chunk
    $parts = $text -split "`r?`n"
    if ($parts.Count -eq 0) { return @() }
    $script:logRemainders[$path] = $parts[$parts.Count - 1]
    if ($parts.Count -eq 1) { return @() }
    return @($parts[0..($parts.Count - 2)])
}

function Get-Session {
    $dir = Get-ScreenFitLogDir
    $files = Get-ChildItem (Join-Path $dir '*_main.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 2
    if (-not $files) { return @{ Active = $false; Device = $null; StartTs = $null } }

    foreach ($f in ($files | Sort-Object LastWriteTime)) {
        foreach ($l in (Read-NewLines $f.FullName)) {
            $ts = $null
            if ($l -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                try { $ts = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { }
            }
            if ($l -match 'start remote control:') {
                if (-not $ts -or $ts -ge $script:sessLastEventTs) {
                    $script:sessActive = $true
                    $script:sessLastEventType = 'start'
                    if ($ts) { $script:sessLastEventTs = $ts; $script:sessStartTs = $ts }
                    $m = [regex]::Match($l, '"deviceName":"([^"]+)"')
                    if ($m.Success) { $script:sessDevice = $m.Groups[1].Value }
                }
            } elseif ($l -match 'stop remote control:') {
                if (-not $ts -or $ts -ge $script:sessLastEventTs) {
                    $script:sessActive = $false
                    $script:sessLastEventType = 'stop'
                    if ($ts) { $script:sessLastEventTs = $ts }
                }
            }
        }
    }

    $active = $script:sessActive
    $dev = $script:sessDevice
    $startTs = $script:sessStartTs
    $devFile = Join-Path (Get-ScreenFitStateDir) 'last-device.txt'

    if ($active -and -not $dev -and (Test-Path $devFile)) {
        $dev = (Get-Content $devFile -Raw -ErrorAction SilentlyContinue).Trim()
    }

    # 兜底：日志轮转导致读不到 start 时，用远程引擎进程 + 引擎日志新鲜度判断。
    # 若最近 120 秒内刚看到 stop，则不做兜底，避免刚结束时被重新判成活动。
    $stopRecently = ($script:sessLastEventType -eq 'stop' -and ((Get-Date) - $script:sessLastEventTs).TotalSeconds -lt 120)
    if (-not $active -and -not $stopRecently) {
        $agentAge = 9999
        $a = Get-ChildItem (Join-Path (Get-ScreenFitLogDir) 'desktop_agent.*.log') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($a) { $agentAge = ((Get-Date) - $a.LastWriteTime).TotalSeconds }
        $agentRunning = @(Get-Process SLDesktopAgent -ErrorAction SilentlyContinue).Count -gt 0
        if ($agentRunning -and $agentAge -lt 60 -and (Test-Path $devFile)) {
            $dev = (Get-Content $devFile -Raw -ErrorAction SilentlyContinue).Trim()
            $active = $true
            $startTs = $null
        }
    }

    return @{ Active = $active; Device = $dev; StartTs = $startTs }
}

function Get-RemoteLiveness {
    $agentAge = 9999
    $a = Get-ChildItem (Join-Path (Get-ScreenFitLogDir) 'desktop_agent.*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($a) { $agentAge = ((Get-Date) - $a.LastWriteTime).TotalSeconds }
    $agentRunning = @(Get-Process SLDesktopAgent -ErrorAction SilentlyContinue).Count -gt 0
    return @{ AgentAge = $agentAge; AgentRunning = $agentRunning }
}

<#
  Get-ViewerEvidence —— 从一份 desktop_agent 日志判断「观看端是否在消费画面」。
  依据：日志行形如 "[...] 2026-11-04 13:57:49.282  ... [CSingleDesktop] Too few frames sent, drop 0, send 0, fps 40"。
  规则：最后一次 send>0 距 Now（默认取日志内最后时间戳，回放模式）不超过 WindowSeconds 视为在观看。
  -TailLines <= 0 表示读整个文件（测试回放用）；默认只读最后 600 行（生产用，避免每次轮询读大文件）。
#>
function Get-ViewerEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [int]$WindowSeconds = 30,
        [Nullable[datetime]]$Now = $null,
        [int]$TailLines = 600
    )

    $result = [pscustomobject]@{
        Samples            = 0
        SamplesWithSend    = 0
        LastSampleTs       = $null
        LastConsumedTs     = $null
        SecondsSinceConsumed = $null
        Active             = $false
    }
    if (-not (Test-Path $LogPath)) { return $result }

    if ($TailLines -gt 0) {
        $lines = @(Get-Content $LogPath -Tail $TailLines -ErrorAction SilentlyContinue)
    } else {
        $lines = @(Get-Content $LogPath -ErrorAction SilentlyContinue)
    }

    foreach ($l in $lines) {
        $mTs = [regex]::Match($l, '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if (-not $mTs.Success) { continue }
        $ts = $null
        try { $ts = [datetime]::ParseExact($mTs.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }

        if (-not $result.LastSampleTs -or $ts -gt $result.LastSampleTs) { $result.LastSampleTs = $ts }

        $mSend = [regex]::Match($l, 'CSingleDesktop\].*?send\s+(\d+)')
        if ($mSend.Success) {
            $result.Samples++
            $send = 0
            [void][int]::TryParse($mSend.Groups[1].Value, [ref]$send)
            if ($send -gt 0) {
                $result.SamplesWithSend++
                if (-not $result.LastConsumedTs -or $ts -gt $result.LastConsumedTs) { $result.LastConsumedTs = $ts }
            }
        }
    }

    $nowTs = $Now
    if (-not $nowTs) { $nowTs = $result.LastSampleTs }

    if ($result.LastConsumedTs -and $nowTs) {
        $gap = ($nowTs - $result.LastConsumedTs).TotalSeconds
        $result.SecondsSinceConsumed = [math]::Round($gap, 1)
        if ($gap -le $WindowSeconds) { $result.Active = $true }
    }

    return $result
}

# 取最新一份 desktop_agent 日志做观看端判断（生产路径）
function Test-ViewerActive {
    param(
        [int]$WindowSeconds = 30,
        [Nullable[datetime]]$Now = $null
    )
    $a = Get-ChildItem (Join-Path (Get-ScreenFitLogDir) 'desktop_agent.*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $a) {
        return [pscustomobject]@{ Active = $false; LogName = $null; SecondsSinceConsumed = $null; LastConsumedTs = $null }
    }
    $ev = Get-ViewerEvidence -LogPath $a.FullName -WindowSeconds $WindowSeconds -Now $Now -TailLines 600
    return [pscustomobject]@{
        Active               = $ev.Active
        LogName              = $a.Name
        SecondsSinceConsumed = $ev.SecondsSinceConsumed
        LastConsumedTs       = $ev.LastConsumedTs
    }
}

<#
  Get-ScreenFitDecision —— 纯决策表（无 IO）。
    session / viewer / state / NoViewerSeconds(距上次切屏后无观看端的秒数) -> idle | stay | switch | restore
  规则：
    无会话：state=on 则 restore，否则 idle
    有会话且观看端在消费：switch
    有会话但无观看端：state=on 且超过宽限期 -> restore；否则 stay（等待，不切屏）
#>
function Get-ScreenFitDecision {
    param(
        [bool]$SessionActive,
        [bool]$ViewerActive,
        [string]$State = 'off',
        [Nullable[double]]$NoViewerSeconds = $null,
        [double]$ViewerGraceSeconds = 60
    )

    if (-not $SessionActive) {
        if ($State -eq 'on') { return 'restore' }
        return 'idle'
    }
    if ($ViewerActive) { return 'switch' }
    if ($State -eq 'on' -and $NoViewerSeconds -ne $null -and $NoViewerSeconds -ge $ViewerGraceSeconds) { return 'restore' }
    return 'stay'
}

$script:DeviceMap = @(
    @{ Match = @('Pad 5 Pro');    W = 3392; H = 2400 },
    @{ Match = @('Pad 4 Pro');    W = 3392; H = 2400 },
    @{ Match = @('Pad 3 Pro');    W = 3000; H = 2120 },
    @{ Match = @('Pad 5');        W = 3000; H = 2120 },
    @{ Match = @('Pad 3');        W = 2800; H = 2000 },
    @{ Match = @('Pad mini', 'Pad Mini'); W = 2520; H = 1680 },
    @{ Match = @('Pad Air5');     W = 2800; H = 1980 },
    @{ Match = @('Find N6');      W = 2480; H = 2248 },
    @{ Match = @('OnePlus Pad 3 Pro', '一加平板 3 Pro'); W = 3392; H = 2400 },
    @{ Match = @('OnePlus Pad 2 Pro', '一加平板 2 Pro'); W = 3392; H = 2400 },
    @{ Match = @('OnePlus Pad Pro', '一加平板 Pro');     W = 3000; H = 2120 },
    @{ Match = @('OnePlus Pad 2', '一加平板 2');         W = 3000; H = 2120 },
    @{ Match = @('OnePlus Pad', '一加平板');             W = 2800; H = 2000 }
)

function Desired($dev) {
    foreach ($entry in $script:DeviceMap) {
        foreach ($pat in $entry.Match) {
            if ($dev -and $dev -like ("*" + $pat + "*")) { return @{ W = $entry.W; H = $entry.H } }
        }
    }
    return $null
}
