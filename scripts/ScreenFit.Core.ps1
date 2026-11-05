<#
  ScreenFit.Core.ps1 —— 纯检测逻辑（无副作用，可被 Watcher.ps1 / Diagnose.ps1 / tests 复用）。
  只做：版本号、OPPO 日志解析、会话状态、观看端证据、决策表。
  不碰显示拓扑、不启动进程、不写状态文件。
#>

$script:ScreenFitVersion = '1.3.1'
$script:ScreenFitLogDir = $null
$script:ScreenFitStateDir = $null
$script:logOffsets = @{}
$script:logRemainders = @{}
$script:sessActive = $false
$script:sessDevice = $null
$script:sessStartTs = $null
$script:sessLastEventTs = [datetime]::MinValue
$script:sessLastEventType = ''
$script:agentSnap = $null
$script:agentSnapTs = [datetime]::MinValue

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
    $script:agentSnap = $null
    $script:agentSnapTs = [datetime]::MinValue
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

# 远程引擎状态快照（带 2 秒缓存）：Get-Process / 目录枚举是主循环里最贵的两步，
# 每 500ms 调一次会把 CPU 拉到 10%+，缓存后空闲时接近 0。
function Get-AgentSnapshot {
    param([double]$TtlSeconds = 2)
    if ($script:agentSnap -and ((Get-Date) - $script:agentSnapTs).TotalSeconds -lt $TtlSeconds) {
        return $script:agentSnap
    }
    $logPath = $null; $logName = $null; $age = 9999
    $a = Get-ChildItem (Join-Path (Get-ScreenFitLogDir) 'desktop_agent.*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($a) { $logPath = $a.FullName; $logName = $a.Name; $age = ((Get-Date) - $a.LastWriteTime).TotalSeconds }
    $running = @(Get-Process SLDesktopAgent -ErrorAction SilentlyContinue).Count -gt 0
    $script:agentSnap = [pscustomobject]@{ LogPath = $logPath; LogName = $logName; AgeSec = $age; Running = $running }
    $script:agentSnapTs = Get-Date
    return $script:agentSnap
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
        $snap = Get-AgentSnapshot
        if ($snap.Running -and $snap.AgeSec -lt 60 -and (Test-Path $devFile)) {
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
  Get-CastState —— 识别 OPPO「屏幕扩展 / 屏幕镜像 / 屏幕共享」状态（原生链路）。
  日志依据（main 日志，可能带转义引号）：
    [screenshare_ipc] castScreenStatusChanged to screenShare: {"castMirrorScreenStatus":0,"gameCastStatus":0,"appMirrorScreenStatus":0,...}
  任一状态 > 0 即为原生屏幕协同中；取最近两份主日志的最后一条状态。
#>
function Get-CastState {
    param([int]$TailLines = 1500, [int]$MaxFiles = 1)
    $result = [pscustomobject]@{ Active = $false; Mirror = $false; AppMirror = $false; GameCast = $false; LastTs = $null }
    $dir = Get-ScreenFitLogDir
    $files = Get-ChildItem (Join-Path $dir '*_main*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First $MaxFiles
    if (-not $files) { return $result }
    foreach ($f in ($files | Sort-Object LastWriteTime)) {
        foreach ($l in (Get-Content $f.FullName -Tail $TailLines -ErrorAction SilentlyContinue)) {
            if ($l -notmatch 'castScreenStatusChanged') { continue }
            $m1 = [regex]::Match($l, '\\?"castMirrorScreenStatus\\?"\s*:\s*(\d+)')
            $m2 = [regex]::Match($l, '\\?"gameCastStatus\\?"\s*:\s*(\d+)')
            $m3 = [regex]::Match($l, '\\?"appMirrorScreenStatus\\?"\s*:\s*(\d+)')
            if (-not ($m1.Success -or $m2.Success -or $m3.Success)) { continue }
            $mir = if ($m1.Success) { [int]$m1.Groups[1].Value } else { 0 }
            $game = if ($m2.Success) { [int]$m2.Groups[1].Value } else { 0 }
            $app = if ($m3.Success) { [int]$m3.Groups[1].Value } else { 0 }
            $result.Mirror = ($mir -gt 0)
            $result.AppMirror = ($app -gt 0)
            $result.GameCast = ($game -gt 0)
            $result.Active = ($mir -gt 0 -or $app -gt 0 -or $game -gt 0)
            $mt = [regex]::Match($l, '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
            if ($mt.Success) { $result.LastTs = $mt.Groups[1].Value }
        }
    }
    return $result
}

<#
  Get-NativeExtendState —— OPPO 原生「屏幕扩展/镜像」是否在进行。
  原生链路由 app_process\screenshare.exe 负责建屏与推流，不经过 SunLogin 远控内核，
  因此插件在此模式下只做守护（不自行建屏），结束后负责恢复扩展布局。
#>
function Get-NativeExtendState {
    param([int]$TailLines = 1500, [int]$GraceSeconds = 120)
    $sharing = @(Get-Process screenshare -ErrorAction SilentlyContinue).Count -gt 0
    $cast = Get-CastState -TailLines $TailLines
    $recent = $false
    if ($cast.LastTs) {
        try {
            $ts = [datetime]::ParseExact($cast.LastTs, 'yyyy-MM-dd HH:mm:ss', $null)
            $recent = ((Get-Date) - $ts).TotalSeconds -le $GraceSeconds
        } catch { }
    }
    $active = [bool]($cast.Active -and ($sharing -or $recent))
    return [pscustomobject]@{
        Active  = $active
        Sharing = $sharing
        Cast    = $cast.Active
        LastTs  = $cast.LastTs
    }
}

<# 原生协同模式下的行为决策（纯函数）：observe=守护不建屏，restore=结束后恢复布局，idle=无关 #>
function Get-NativeExtendDecision {
    param([bool]$NativeActive, [string]$State = 'off')
    if ($NativeActive) { return 'observe' }
    if ($State -eq 'native') { return 'restore' }
    return 'idle'
}

<#
  Get-PreArmAction —— 「预建屏（会话前就绪）」模式的状态机（纯函数）。
    arm     : 已请求预建，但还没执行 -> 建屏并切到仅虚拟屏
    wait    : 已预建，等待平板发起远控（超时前）
    promote : 已检测到远控会话且观看端在消费 -> 进入正常会话
    restore : 撤防（用户取消）或等待超时 -> 恢复物理扩展布局
    idle    : 未请求预建且当前不是预建状态
#>
function Get-PreArmAction {
    param(
        [bool]$Armed,
        [string]$State = 'off',
        [bool]$SessionActive = $false,
        [bool]$ViewerActive = $false,
        [Nullable[double]]$SecondsSinceArm = $null,
        [double]$ArmTimeoutSeconds = 900
    )
    if (-not $Armed) {
        if ($State -eq 'prearmed') { return 'restore' }
        return 'idle'
    }
    if ($State -ne 'prearmed') { return 'arm' }
    if ($SessionActive -and $ViewerActive) { return 'promote' }
    if ($SecondsSinceArm -ne $null -and $SecondsSinceArm -ge $ArmTimeoutSeconds) { return 'restore' }
    return 'wait'
}

<#
  Get-ViewerEvidence —— 从一份 desktop_agent 日志判断「观看端是否在消费画面」。
  OPPO 不同版本/不同会话的日志格式不一样，必须同时兼容：
    旧版逐帧行: [CSingleDesktop] Too few frames sent, drop 0, send 7, fps 40
    新版质量行: [EncoderQualityCalc] ... drop=0, send=39, line=187   （约每 5 秒一行）
    新版汇总行: [desktop] total 137 calc 0 encode 125 send 0 push 12 ...
  规则：最后一次 send>0 距 Now（默认取日志内最后时间戳，回放模式）不超过 WindowSeconds 视为在观看。
  -TailLines <= 0 表示读整个文件（测试回放用）；默认只读最后 600 行（生产用，避免每次轮询读大文件）。
#>
function Get-FrameSendValue([string]$line) {
    $m = [regex]::Match($line, 'EncoderQualityCalc\].*?send=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    $m = [regex]::Match($line, 'CSingleDesktop\].*?send\s+(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    $m = [regex]::Match($line, '\[desktop\].*?\bsend\s+(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

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

        $sendValue = Get-FrameSendValue $l
        if ($null -ne $sendValue) {
            $result.Samples++
            if ($sendValue -gt 0) {
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

<#
  Get-RestoreAction —— 会话结束后的布局恢复策略（纯函数，无 IO）。
  用户的硬性要求：只要外接屏还在，断开远控后必须是「扩展」，不能塌缩成「仅电脑屏幕」。
    外接屏存在但活动屏不足 2 块 -> extend（强制扩展）
    没有外接屏且一块屏都没有   -> internal（兜底回内屏）
    其余情况                   -> none（布局已正确）
#>
function Get-RestoreAction {
    param(
        [bool]$HasSnapshot,
        [bool]$RestoreFailed,
        [bool]$ExternalPresent,
        [int]$ActiveCount,
        [bool]$StateOn
    )
    if ($ExternalPresent -and $ActiveCount -lt 2) { return 'extend' }
    if (-not $ExternalPresent -and $ActiveCount -lt 1) { return 'internal' }
    return 'none'
}

# ===== 设备目录（唯一来源）=====
# Key     : 脚本参数用的稳定标识（Prepare-Remote / TabletScreen / Test-PreCreatedScreen）
# Aliases : 匹配 OPPO 互联日志 deviceName 的别名（中英文），越具体的条目越靠前
# Verified: 规格是否经官方页面核实；false 仅作候选，不参与自动决策时可回退
$script:DeviceCatalog = @(
    @{ Key = 'FindN6';        Aliases = @('Find N6'); W = 2480; H = 2248; Label = 'OPPO Find N6（内屏）'; Verified = $true },
    @{ Key = 'FindN5';        Aliases = @('Find N5'); W = 2480; H = 2248; Label = 'OPPO Find N5（内屏）'; Verified = $true },
    @{ Key = 'FindN3Flip';    Aliases = @('Find N3 Flip', 'Find N2 Flip'); W = 2520; H = 1080; Label = 'OPPO Find N3/N2 Flip（内屏）'; Verified = $false },
    @{ Key = 'FindN3';        Aliases = @('Find N3'); W = 2440; H = 2268; Label = 'OPPO Find N3（内屏）'; Verified = $false },
    @{ Key = 'FindN2';        Aliases = @('Find N2'); W = 1920; H = 1792; Label = 'OPPO Find N2（内屏）'; Verified = $false },
    @{ Key = 'FindN1';        Aliases = @('Find N');  W = 1920; H = 1792; Label = 'OPPO Find N（一代，内屏）'; Verified = $false },

    @{ Key = 'OnePlusPad3Pro'; Aliases = @('OnePlus Pad 3 Pro', '一加平板 3 Pro'); W = 3392; H = 2400; Label = 'OnePlus Pad 3 Pro'; Verified = $true },
    @{ Key = 'OnePlusPad2Pro'; Aliases = @('OnePlus Pad 2 Pro', '一加平板 2 Pro'); W = 3392; H = 2400; Label = 'OnePlus Pad 2 Pro'; Verified = $true },
    @{ Key = 'OnePlusPadPro';  Aliases = @('OnePlus Pad Pro', '一加平板 Pro');     W = 3000; H = 2120; Label = 'OnePlus Pad Pro'; Verified = $true },
    @{ Key = 'OnePlusPad2';    Aliases = @('OnePlus Pad 2', '一加平板 2');         W = 3000; H = 2120; Label = 'OnePlus Pad 2'; Verified = $true },
    @{ Key = 'OnePlusPadGo2';  Aliases = @('OnePlus Pad Go 2', '一加平板 Go 2');   W = 2800; H = 2000; Label = 'OnePlus Pad Go 2'; Verified = $false },
    @{ Key = 'OnePlusPadGo';   Aliases = @('OnePlus Pad Go', '一加平板 Go');       W = 2408; H = 1720; Label = 'OnePlus Pad Go'; Verified = $false },

    @{ Key = 'Pad5Pro'; Aliases = @('Pad 5 Pro', 'Pad 5Pro'); W = 3392; H = 2400; Label = 'OPPO Pad 5 Pro'; Verified = $true },
    @{ Key = 'Pad4Pro'; Aliases = @('Pad 4 Pro', 'Pad 4Pro'); W = 3392; H = 2400; Label = 'OPPO Pad 4 Pro'; Verified = $true },
    @{ Key = 'Pad3Pro'; Aliases = @('Pad 3 Pro'); W = 3000; H = 2120; Label = 'OPPO Pad 3 Pro'; Verified = $true },
    @{ Key = 'Pad5';    Aliases = @('Pad 5');     W = 3000; H = 2120; Label = 'OPPO Pad 5'; Verified = $true },
    @{ Key = 'Pad6';    Aliases = @('Pad 6');     W = 3000; H = 2120; Label = 'OPPO Pad 6'; Verified = $false },
    @{ Key = 'PadAir5'; Aliases = @('Pad Air5');  W = 2800; H = 1980; Label = 'OPPO Pad Air5'; Verified = $true },
    @{ Key = 'PadAir2'; Aliases = @('Pad Air2', 'Pad Air 2'); W = 2408; H = 1720; Label = 'OPPO Pad Air2'; Verified = $false },
    @{ Key = 'PadNeo';  Aliases = @('Pad Neo');   W = 2408; H = 1720; Label = 'OPPO Pad Neo'; Verified = $false },
    @{ Key = 'PadAir';  Aliases = @('Pad Air');   W = 2000; H = 1200; Label = 'OPPO Pad Air'; Verified = $false },
    @{ Key = 'PadSE';   Aliases = @('Pad SE');    W = 1920; H = 1200; Label = 'OPPO Pad SE'; Verified = $false },
    @{ Key = 'PadMini'; Aliases = @('Pad mini', 'Pad Mini'); W = 2520; H = 1680; Label = 'OPPO Pad Mini'; Verified = $true },
    @{ Key = 'Pad2';    Aliases = @('Pad 2');     W = 2800; H = 2000; Label = 'OPPO Pad 2'; Verified = $false },
    @{ Key = 'Pad3';    Aliases = @('Pad 3');     W = 2800; H = 2000; Label = 'OPPO Pad 3'; Verified = $true },
    @{ Key = 'OPPOPad1'; Aliases = @('OPPO Pad'); W = 2560; H = 1600; Label = 'OPPO Pad（一代）'; Verified = $false },

    @{ Key = 'OnePlusPad1'; Aliases = @('OnePlus Pad', '一加平板'); W = 2800; H = 2000; Label = 'OnePlus Pad（一代）'; Verified = $true }
)

<# 设备目录（唯一来源）：所有脚本都从这里取设备清单与分辨率 #>
function Get-DeviceCatalog { return $script:DeviceCatalog }

<# 设备 Key 列表（供脚本参数校验） #>
function Get-DeviceKeys { return @($script:DeviceCatalog | ForEach-Object { $_.Key }) }

<#
  Get-DeviceProfile —— 接受设备 Key（大小写不敏感）或 deviceName 片段，返回
  @{ Key; W; H; Label; Verified }；无法识别返回 $null。
#>
function Get-DeviceProfile($dev) {
    if (-not $dev) { return $null }
    $d = [string]$dev
    foreach ($entry in $script:DeviceCatalog) {
        if ($entry.Key -and $entry.Key -ieq $d) { return $entry }
    }
    foreach ($entry in $script:DeviceCatalog) {
        foreach ($pat in $entry.Aliases) {
            if ($d -like ("*" + $pat + "*")) { return $entry }
        }
    }
    return $null
}

function Desired($dev) { return (Get-DeviceProfile $dev) }