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

Write-Host '== 4. 原生屏幕扩展（screenshare）识别 =='
$nativeCases = @(
    @{ native = $true; state = 'off'; expect = 'observe' },
    @{ native = $true; state = 'native'; expect = 'observe' },
    @{ native = $false; state = 'native'; expect = 'restore' },
    @{ native = $false; state = 'off'; expect = 'idle' },
    @{ native = $false; state = 'on'; expect = 'idle' }
)
foreach ($c in $nativeCases) {
    $d = Get-NativeExtendDecision -NativeActive $c.native -State $c.state
    Check ($d -eq $c.expect) ("native-decision:native=" + $c.native + ",state=" + $c.state) ("expected=" + $c.expect + " got=" + $d)
}

$castTmp = Join-Path $env:TEMP ("sf-cast-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $castTmp | Out-Null
$oldCastLogDir = $env:SCREENFIT_LOG_DIR
try {
    $castLog = Join-Path $castTmp '2026-11-04_main.1.log'
    [System.IO.File]::WriteAllText($castLog,
        ('[16.2.20][info][pid:1] 2026-11-04 23:10:00.000 - [screenshare_ipc] castScreenStatusChanged to screenShare: {"castMirrorScreenStatus":1,"gameCastStatus":0,"appMirrorScreenStatus":0,"isHaveScreenShareAbility":true}' + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    $env:SCREENFIT_LOG_DIR = $castTmp
    Initialize-ScreenFit -StateDir $castTmp
    $c1 = Get-CastState
    Check ($c1.Active -eq $true) 'cast-active-detected' ("active=" + $c1.Active)
    Check ($c1.Mirror -eq $true) 'cast-mirror-flag' ("mirror=" + $c1.Mirror)

    [System.IO.File]::AppendAllText($castLog,
        ('[16.2.20][info][pid:1] 2026-11-04 23:20:00.000 - [screenshare_ipc] castScreenStatusChanged to screenShare: {"castMirrorScreenStatus":0,"gameCastStatus":0,"appMirrorScreenStatus":0,"isHaveScreenShareAbility":false}' + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    Initialize-ScreenFit -StateDir $castTmp
    $c2 = Get-CastState
    Check ($c2.Active -eq $false) 'cast-stop-detected' ("active=" + $c2.Active)
} finally {
    $env:SCREENFIT_LOG_DIR = $oldCastLogDir
    Remove-Item $castTmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '== 5. 预建屏状态机 =='
$preArmCases = @(
    @{ armed = $true;  state = 'off';      sess = $false; viewer = $false; secs = $null; expect = 'arm' },
    @{ armed = $true;  state = 'prearmed'; sess = $false; viewer = $false; secs = 10;    expect = 'wait' },
    @{ armed = $true;  state = 'prearmed'; sess = $true;  viewer = $true;  secs = 30;    expect = 'promote' },
    @{ armed = $true;  state = 'prearmed'; sess = $true;  viewer = $false; secs = 30;    expect = 'wait' },
    @{ armed = $true;  state = 'prearmed'; sess = $false; viewer = $false; secs = 1000;  expect = 'restore' },
    @{ armed = $false; state = 'prearmed'; sess = $false; viewer = $false; secs = $null; expect = 'restore' },
    @{ armed = $false; state = 'off';      sess = $false; viewer = $false; secs = $null; expect = 'idle' }
)
foreach ($c in $preArmCases) {
    $d = Get-PreArmAction -Armed $c.armed -State $c.state -SessionActive $c.sess -ViewerActive $c.viewer -SecondsSinceArm $c.secs -ArmTimeoutSeconds 900
    Check ($d -eq $c.expect) ("prearm:armed=" + $c.armed + ",state=" + $c.state + ",sess=" + $c.sess + ",viewer=" + $c.viewer + ",secs=" + $c.secs) ("expected=" + $c.expect + " got=" + $d)
}

Write-Host '== 6. 设备档案（折叠屏 / OPPO 平板 / 一加平板） =='
$deviceCases = @(
    @{ name = 'OPPO Pad 5 Pro'; w = 3392; h = 2400 },
    @{ name = 'OPPO Pad 3 Pro'; w = 3000; h = 2120 },
    @{ name = 'OPPO Pad 5';     w = 3000; h = 2120 },
    @{ name = 'OPPO Pad 6';     w = 3000; h = 2120 },
    @{ name = 'OPPO Pad Mini';  w = 2520; h = 1680 },
    @{ name = 'OPPO Pad Air5';  w = 2800; h = 1980 },
    @{ name = 'OPPO Pad Air2';  w = 2408; h = 1720 },
    @{ name = 'OPPO Pad 3';     w = 2800; h = 2000 },
    @{ name = 'OPPO Find N6';   w = 2480; h = 2248 },
    @{ name = 'OPPO Find N5';   w = 2480; h = 2248 },
    @{ name = 'OPPO Find N3';   w = 2440; h = 2268 },
    @{ name = 'OPPO Find N2';   w = 1920; h = 1792 },
    @{ name = 'OnePlus Pad 3 Pro'; w = 3392; h = 2400 },
    @{ name = '一加平板 2 Pro';  w = 3392; h = 2400 },
    @{ name = '一加平板 Pro';    w = 3000; h = 2120 },
    @{ name = 'OnePlus Pad Go 2'; w = 2800; h = 2000 },
    @{ name = 'OnePlus Pad Go';  w = 2408; h = 1720 },
    @{ name = '一加平板';         w = 2800; h = 2000 }
)
foreach ($c in $deviceCases) {
    $p = Get-DeviceProfile $c.name
    Check ($p -ne $null -and $p.W -eq $c.w -and $p.H -eq $c.h) ("device:" + $c.name) ("expected=" + $c.w + "x" + $c.h + " got=" + $(if($p){"$($p.W)x$($p.H)"}else{'null'}))
}
Check ($null -eq (Get-DeviceProfile 'Nintendo Switch')) 'device:unknown-returns-null'

Write-Host '== 7. 版本一致性 =='
$ver = Get-ScreenFitVersion
Check ($ver -match '^\d+\.\d+\.\d+$') 'version-format' ("got=" + $ver)
$verFile = Join-Path $RepoRoot 'VERSION'
if (Test-Path $verFile) {
    Check (((Get-Content $verFile -Raw).Trim()) -eq $ver) 'version-file-matches-core' ("file=" + ((Get-Content $verFile -Raw).Trim()) + " core=" + $ver)
}

Write-Host ''
Write-Host ("结果: PASS={0} FAIL={1}" -f $script:passCount, $script:failCount)
if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
