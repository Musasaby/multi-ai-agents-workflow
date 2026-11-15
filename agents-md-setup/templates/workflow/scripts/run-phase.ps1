# タスクが今どの段階にあるかを、state.json と runs/ のファイルの有無だけで判定する(読み取り専用)。
# Usage: run-phase.ps1 <TaskId>
# stdout: "Phase: <段階> <試行回数>" の 1 行だけ
# exit: 0=判定した / 1=使い方不備・state.json が無い・タスクが state.json に無い
#
# <段階> の意味:
#   start        = この試行番号で起動する
#   running      = 実装の run の完了待ち
#   review-start = レビューを起動する
#   reviewing    = レビューの完了待ち
#   collect      = 取り込む
#   gate         = 品質ゲートとコミット
#   retry        = レビュー不合格の再 dispatch
#   manual       = 親が今の手順で処理する
#   pending / done / failed = 対象外の状態をそのまま出す
param(
    [Parameter(Position = 0)][string]$TaskId,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Usage = 'Usage: run-phase.ps1 <TaskId>'

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

if ((-not $TaskId) -or ($null -ne $Rest -and $Rest.Count -gt 0)) { Fail $Usage }
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$') { Fail "Invalid TaskId: '$TaskId'" }

Set-Location $PSScriptRoot\..\..\..
$statePath = '.agents/workflow/state.json'
$runsDir = '.agents/workflow/runs'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Fail "state.json not found: $statePath" }

$state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$task = $state.tasks | Where-Object { $_.id -ceq $TaskId } | Select-Object -First 1
if (-not $task) { Fail "Task '$TaskId' not found in state.json" }

$status = $task.status

# N = runs/<ID>-<n>/guard.sha256 がある最大の n(無ければ 0)
$n = 0
if (Test-Path -LiteralPath $runsDir -PathType Container) {
    $pattern = '^' + [regex]::Escape($TaskId) + '-(\d+)$'
    foreach ($dir in Get-ChildItem -LiteralPath $runsDir -Directory) {
        if ($dir.Name -cmatch $pattern -and (Test-Path -LiteralPath (Join-Path $dir.FullName 'guard.sha256') -PathType Leaf)) {
            $num = [int]$Matches[1]
            if ($num -gt $n) { $n = $num }
        }
    }
}

$run = Join-Path $runsDir "$TaskId-$n"
$review = Join-Path $runsDir "review-$TaskId-$n"

function Test-Has {
    param([string]$Path, [string]$Name)
    return Test-Path -LiteralPath (Join-Path $Path $Name)
}

$verdict = ''
$verdictPath = Join-Path $review 'verdict'
if (Test-Path -LiteralPath $verdictPath -PathType Leaf) {
    $first = Get-Content -LiteralPath $verdictPath -TotalCount 1
    if ($null -ne $first) { $verdict = "$first".TrimEnd("`r", "`n") }
}

if ($status -cnotin @('in_progress', 'in_review')) {
    $phase = "$status"
} elseif ($status -ceq 'in_progress') {
    if ($n -eq 0) {
        $phase = 'start'
        $n = 1
    } elseif ((Test-Has $run 'superseded') -or (Test-Has $run 'collected')) {
        $phase = 'start'
        $n += 1
    } elseif (-not (Test-Has $run 'checked')) {
        $phase = 'running'
    } elseif (-not (Test-Has $review 'guard.sha256')) {
        $phase = 'review-start'
    } elseif ($verdict -ceq '') {
        $phase = 'reviewing'
    } elseif ($verdict -ceq 'pass') {
        $phase = 'collect'
    } elseif ($verdict -ceq 'fail') {
        $phase = 'retry'
    } else {
        $phase = 'unknown'
    }
} else {  # in_review
    if ($verdict -ceq 'pass' -and (Test-Has $run 'collected')) {
        $phase = 'gate'
    } elseif ($verdict -ceq 'fail' -and -not (Test-Has $run 'collected')) {
        $phase = 'retry'
    } else {
        $phase = 'manual'
    }
}

Write-Output "Phase: $phase $n"
exit 0
