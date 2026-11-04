<#
  Test-Detection.ps1 —— 检测逻辑回归测试（离线、确定性，不读写真实 OPPO 状态）。
  用法：pwsh -NoProfile -File tests\Test-Detection.ps1
  退出码：0 = 全部通过；1 = 有失败；2 = 缺少被测模块（红）
#>

param(
    [string]$FixturesDir = (Join-Path $PSScriptRoot 'fixtures')
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Core = Join-Path $RepoRoot 'scripts\ScreenFit.Core.ps1'

$script:passCount = 0
$script:failCount = 0

function Check([bool]$cond, [string]$name, [string]$detail = '') {
    if ($cond) {
        $script:passCount++
        Write-Host ("PASS  " + $name)
    } else {
        $script:failCount++
        Write-Host ("FAIL  " + $name + "  " + $detail) -ForegroundColor Red
    }
}

if (-not (Test-Path $Core)) {
    Write-Host ("RED: 缺少被测模块 " + $Core) -ForegroundColor Yellow
    exit 2
}
. $Core

Write-Host '== 1. 观看端识别（真实日志回放） =='
$expect = Get-Content (Join-Path $FixturesDir 'expectations.json') -Raw | ConvertFrom-Json
foreach ($c in $expect.cases) {
    $path = Join-Path $FixturesDir $c.file
    Check (Test-Path $path) ("fixture-exists:" + $c.file)
    if (-not (Test-Path $path)) { continue }
    $now = [datetime]::ParseExact($c.lastTs, 'yyyy-MM-dd HH:mm:ss', $null)
    # -TailLines 0：回放模式读整份日志，保证样本计数可核对（生产默认只读尾部 600 行）
    $ev = Get-ViewerEvidence -LogPath $path -WindowSeconds 30 -Now $now -TailLines 0
    Check ($ev.Samples -eq [int]$c.samples) ("fixture-sample-count:" + $c.file) ("expected=" + $c.samples + " got=" + $ev.Samples)
    Check ($ev.Active -eq [bool]$c.viewer) ("viewer:" + $c.file) ("expected=" + $c.viewer + " got=" + $ev.Active + " secondsSinceConsumed=" + $ev.SecondsSinceConsumed)
    # 哨兵：false 用例在历史上确实收到过帧，证明结论来自时间窗判定，而不是输入里根本没有帧
    if (-not [bool]$c.viewer) {
        Check ([int]$c.samplesGt0 -gt 0) ("fixture-sentinel:" + $c.file) ("samplesGt0=" + $c.samplesGt0)
    }
}

Write-Host '== 2. 决策表（纯函数） =='
$cases = @(
    @{ session = $false; viewer = $false; state = 'off'; gap = $null; expect = 'idle' },
    @{ session = $false; viewer = $false; state = 'on'; gap = $null; expect = 'restore' },
    @{ session = $true; viewer = $true; state = 'off'; gap = $null; expect = 'switch' },
    @{ session = $true; viewer = $true; state = 'on'; gap = $null; expect = 'switch' },
    @{ session = $true; viewer = $false; state = 'off'; gap = 999; expect = 'stay' },
    @{ session = $true; viewer = $false; state = 'on'; gap = 10; expect = 'stay' },
    @{ session = $true; viewer = $false; state = 'on'; gap = $null; expect = 'stay' },
    @{ session = $true; viewer = $false; state = 'on'; gap = 61; expect = 'restore' }
)
foreach ($c in $cases) {
    $d = Get-ScreenFitDecision -SessionActive $c.session -ViewerActive $c.viewer -State $c.state -NoViewerSeconds $c.gap -ViewerGraceSeconds 60
    Check ($d -eq $c.expect) ("decision:session=" + $c.session + ",viewer=" + $c.viewer + ",state=" + $c.state + ",gap=" + $c.gap) ("expected=" + $c.expect + " got=" + $d)
}

Write-Host '== 3. 布局恢复策略（外接屏必须回到扩展） =='
$restoreCases = @(
    @{ external = $true;  active = 1; failed = $false; snap = $true;  expect = 'extend' },
    @{ external = $true;  active = 0; failed = $true;  snap = $true;  expect = 'extend' },
    @{ external = $true;  active = 2; failed = $false; snap = $true;  expect = 'none' },
    @{ external = $false; active = 0; failed = $false; snap = $false; expect = 'internal' },
    @{ external = $false; active = 1; failed = $false; snap = $true;  expect = 'none' },
    @{ external = $false; active = 1; failed = $true;  snap = $true;  expect = 'none' }
)
foreach ($c in $restoreCases) {
    $a = Get-RestoreAction -HasSnapshot $c.snap -RestoreFailed $c.failed -ExternalPresent $c.external -ActiveCount $c.active -StateOn $true
    Check ($a -eq $c.expect) ("restore:external=" + $c.external + ",active=" + $c.active + ",failed=" + $c.failed) ("expected=" + $c.expect + " got=" + $a)
}

Write-Host '== 4. 日志轮转与投屏识别 =='
$tmp = Join-Path $env:TEMP ("sf-rot-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$oldLogDir = $env:SCREENFIT_LOG_DIR
try {
    # 轮转文件名：2026-11-04_main.1.log 必须能被识别（旧代码只匹配 *_main.log）
    $mainTxt = @(
        '[16.2.20][info][pid:1] 2026-11-04 22:56:00.671 - [WsClient.js] start remote control: {"content":{"body":{"currentDevice":{"deviceName":"OPPO Pad 5 Pro"}}}}'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $tmp '2026-11-04_main.1.log'), $mainTxt + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $env:SCREENFIT_LOG_DIR = $tmp
    Initialize-ScreenFit -StateDir $tmp
    $s1 = Get-Session
    Check ($s1.Active -eq $true) 'rotated-main-log-session-active' ("active=" + $s1.Active)
    Check ($s1.Device -eq 'OPPO Pad 5 Pro') 'rotated-main-log-device' ("device=" + $s1.Device)
    Check ($s1.Cast -eq $false) 'rotated-main-log-not-cast' ("cast=" + $s1.Cast)

    # 投屏状态：任一模式非 0 -> Active/Cast；回落 0 -> 不再投屏
    [System.IO.File]::AppendAllText((Join-Path $tmp '2026-11-04_main.1.log'),
        ('[16.2.20][info][pid:1] 2026-11-04 23:10:00.000 - [screenshare_ipc] castScreenStatusChanged to screenShare: {"castMirrorScreenStatus":1,"gameCastStatus":0,"appMirrorScreenStatus":0,"isHaveScreenShareAbility":true}' + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    Initialize-ScreenFit -StateDir $tmp
    $s2 = Get-Session
    Check ($s2.Cast -eq $true) 'cast-mirror-detected' ("cast=" + $s2.Cast)
    Check ($s2.Active -eq $true) 'cast-makes-session-active' ("active=" + $s2.Active)

    [System.IO.File]::AppendAllText((Join-Path $tmp '2026-11-04_main.1.log'),
        ('[16.2.20][info][pid:1] 2026-11-04 23:20:00.000 - [screenshare_ipc] castScreenStatusChanged to screenShare: {"castMirrorScreenStatus":0,"gameCastStatus":0,"appMirrorScreenStatus":0,"isHaveScreenShareAbility":false}' + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    Initialize-ScreenFit -StateDir $tmp
    $s3 = Get-Session
    Check ($s3.Cast -eq $false) 'cast-stop-detected' ("cast=" + $s3.Cast)
} finally {
    $env:SCREENFIT_LOG_DIR = $oldLogDir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '== 5. 版本一致性 =='
$ver = Get-ScreenFitVersion
Check ($ver -match '^\d+\.\d+\.\d+$') 'version-format' ("got=" + $ver)
$verFile = Join-Path $RepoRoot 'VERSION'
if (Test-Path $verFile) {
    Check (((Get-Content $verFile -Raw).Trim()) -eq $ver) 'version-file-matches-core' ("file=" + ((Get-Content $verFile -Raw).Trim()) + " core=" + $ver)
}

Write-Host ''
Write-Host ("结果: PASS={0} FAIL={1}" -f $script:passCount, $script:failCount)
if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
