# 子エージェントの run(runs/<ID>-<N>/)の完了をポーリングで待つ(#56。親が書いていた
# 待ちループの置き換え)。1回の呼び出しで -MaxWait 秒まで待つ(親ツールのコマンド実行
# 上限に合わせて呼び出し側から渡す。exit 2 で返れば、再度このスクリプトを呼んで待ちを
# 続ける)。経過秒数の基準(= run の開始時刻)は dispatch-run が起動時に作る
# runs/<ID>-<N>/guard.sha256 の最終更新時刻(LastWriteTimeUtc)。done マーカーがあれば
# dispatch-check.ps1 に判定を任せ、その結果をそのまま返す。
# Usage: dispatch-wait.ps1 -TaskId <TaskId> [-Attempt <N>] [-MaxWait <秒>] [-Interval <秒>]
#   -Attempt の既定は 1 / -MaxWait の既定は 480(1回の呼び出しで待つ上限) /
#   -Interval の既定は 15(ポーリング間隔)
# exit: 0/4/5/6/7/8 = dispatch-check.ps1 の結果をそのまま(done があった場合)
#       1 = 使い方不備、または run が起動されていない(guard.sha256 が無い)
#       2 = まだ実行中(この呼び出しの待ち時間が -MaxWait に達した)
#       3 = 経過が config.json の child_agent.timeout_seconds を超えた
# exit 2/3 のとき、stdout に状況行(Run / Status: running / Elapsed / Log idle / Log)を
# 出し、最後の行に Next: wait / Next: escalate reason=timeout を出す
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1,
    [int]$MaxWait = 480,
    [int]$Interval = 15
)
# パスや埋め込みに使うため、タスクIDと試行回数・待ち時間の形式を検証する
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1 -or $MaxWait -lt 0 -or $Interval -lt 0) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt/-MaxWait/-Interval: '$TaskId' '$Attempt' '$MaxWait' '$Interval'")
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$runDir = ".agents/workflow/runs/$TaskId-$Attempt"
$donePath = "$runDir/done"
$logPath = "$runDir/output.log"
$guardPath = "$runDir/guard.sha256"

# <ファイル> の最終更新(LastWriteTimeUtc)からの経過秒数(取れない・負の値なら 0)
function Get-SecondsSince {
    param([string]$Path)
    try {
        $seconds = [int][Math]::Floor(([DateTime]::UtcNow - (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds)
        if ($seconds -lt 0) { return 0 }
        return $seconds
    } catch {
        return 0
    }
}

# run が dispatch-run で起動されていなければ待てない(guard.sha256 は dispatch-run が
# 起動時に作る。done より先に確かめる = 開始時刻が無ければ経過秒数も出せないため)
if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
    [Console]::Error.WriteLine("guard.sha256 not found: $guardPath (the run was not started by dispatch-run)")
    exit 1
}

# config.json の child_agent.timeout_seconds(無い・読めなければ 1800。0 以下は無効 = 判定しない)
$timeoutSeconds = 1800
try {
    $cfg = Get-Content '.agents/workflow/config.json' -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    $v = $cfg.child_agent.timeout_seconds
    if ($null -ne $v -and $v -isnot [bool] -and ($v -is [int] -or $v -is [long] -or $v -is [double])) {
        $timeoutSeconds = [int][Math]::Floor($v)
    }
} catch {
    $timeoutSeconds = 1800
}
if ($timeoutSeconds -le 0) { $timeoutSeconds = 0 }

# 状況行(exit 2/3 のときに stdout へ出す。$Elapsed = 経過秒数)
function Write-Status {
    param([int]$Elapsed)
    $logIdle = if (Test-Path -LiteralPath $logPath -PathType Leaf) { "$(Get-SecondsSince $logPath)s" } else { '-' }
    Write-Output "Run: $TaskId-$Attempt"
    Write-Output "Status: running"
    Write-Output "Elapsed: ${Elapsed}s"
    Write-Output "Log idle: $logIdle"
    Write-Output "Log: $logPath"
}

# --- ポーリングループ((a) done → (b) timeout_seconds → (c) -MaxWait → (d) sleep) ---
$waitStart = [DateTime]::UtcNow
while ($true) {
    # (a) done があれば dispatch-check に判定させる。stdout は流して、exit code も
    # dispatch-check のものをそのまま返す
    if (Test-Path -LiteralPath $donePath -PathType Leaf) {
        $checkOut = & pwsh -NoProfile -File "$PSScriptRoot/dispatch-check.ps1" -TaskId $TaskId -Attempt $Attempt
        $checkOut | ForEach-Object { Write-Output $_ }
        exit $LASTEXITCODE
    }
    $elapsed = Get-SecondsSince $guardPath
    # (b) 経過が timeout_seconds(有効なときだけ)を超えていれば、時間超過として親に返す
    if ($timeoutSeconds -gt 0 -and $elapsed -ge $timeoutSeconds) {
        Write-Status $elapsed
        Write-Output "Next: escalate reason=timeout"
        exit 3
    }
    # (c) この呼び出しで待った秒数が -MaxWait に達していれば、まだ実行中として親に返す
    # (親は再度このスクリプトを呼んで待ちを続ける)
    if (([int][Math]::Floor(([DateTime]::UtcNow - $waitStart).TotalSeconds)) -ge $MaxWait) {
        Write-Status $elapsed
        Write-Output "Next: wait"
        exit 2
    }
    # (d) ポーリング間隔だけ待って (a) に戻る(最初の確認はこの sleep の前に行う)
    Start-Sleep -Seconds $Interval
}
# while ループはすべての出口が exit のためここには来ない(防御的なフォールバック)
exit 1
