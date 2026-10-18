# 子エージェントの起動までの事前チェックを順に行い、デタッチ起動する。失敗した段階で止める
# (止めたときは state.json を変えず、子も起動しない)。
# Usage: dispatch-start.ps1 -TaskId <TaskId> [-Attempt <N>] | dispatch-start.ps1 -Pr
#   -Pr: PR 作成の run(pr-<N>-1)を起動する(タスクの状態確認・task-state は行わず、ウォームアップもしない)
# exit:
#   0=起動した / 1=使い方不備
#   11〜15=branch-check -State の 1〜5(stdout の Next: 行はそのまま流す)
#   20=作業ツリーが汚れている(試行回数 2 以上で fix-notes.md がある場合は確認しない) / 21=タスクの状態が不正(pending / in_progress 以外、タスク無しを含む)
#   30=疎通確認(healthcheck_command)の失敗 / 31=ウォームアップ(warmup_command)の失敗
#   41〜43=dispatch-prompt-gen の 1〜3(依存未完了・report.md の欠落は 42)
#   50=task-state の失敗
#   60=dispatch-run の起動を確認できない(guard.sha256 が上限秒数内に現れない)
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / escalate reason=<理由> 等。
# 使い方不備の exit 1 では出さない)
param(
    [string]$TaskId = '',
    [int]$Attempt = 1,
    [switch]$Pr
)
if ($Pr) {
    $TaskId = 'pr'
    $Attempt = 1
} elseif (-not $TaskId) {
    [Console]::Error.WriteLine("Usage: dispatch-start.ps1 -TaskId <TaskId> [-Attempt <N>] | dispatch-start.ps1 -Pr")
    exit 1
}
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt: '$TaskId' '$Attempt'")
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$runDir = ".agents/workflow/runs/$TaskId-$Attempt"

# 1. ブランチ
$out = @(& pwsh -NoProfile -File "$PSScriptRoot/branch-check.ps1" -State)
$code = $LASTEXITCODE
if ($code -ne 0) {
    $out | ForEach-Object { Write-Output $_ }
    exit (10 + $code)
}

# 2. 作業ツリー
if (-not $Pr -and $Attempt -ge 2 -and (Test-Path -LiteralPath "$runDir/fix-notes.md" -PathType Leaf)) {
    [Console]::Error.WriteLine("Retry (attempt $Attempt, fix-notes.md found): keeping the working tree changes from the previous attempt")
} else {
    $dirty = @(& git status --porcelain)
    if ($dirty.Count -gt 0) {
        [Console]::Error.WriteLine("Working tree is not clean:")
        $dirty | ForEach-Object { [Console]::Error.WriteLine($_) }
        if (-not $Pr -and $Attempt -ge 2 -and -not (Test-Path -LiteralPath "$runDir/fix-notes.md" -PathType Leaf)) {
            [Console]::Error.WriteLine("fix-notes.md not found: $runDir/fix-notes.md (a retry with attempt >= 2 needs fix-notes.md)")
        }
        Write-Output "Next: escalate reason=dirty-tree"
        exit 20
    }
}

# 3. タスクの状態
$status = ''
if (-not $Pr) {
    try {
        $state = Get-Content '.agents/workflow/state.json' -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
        $task = @($state.tasks | Where-Object { $_.id -ceq $TaskId }) | Select-Object -First 1
        if ($task) { $status = "$($task.status)" }
    } catch {
        $status = ''
    }
}
if (-not $Pr -and $status -ne 'pending' -and $status -ne 'in_progress') {
    $shown = if ($status) { $status } else { '<absent>' }
    [Console]::Error.WriteLine("Task $TaskId cannot be started (status: $shown)")
    Write-Output "Next: escalate reason=task-status"
    exit 21
}

# config.json の child_agent.<キー> を読む(読めなければ空文字)。bool は true のとき 'true' を返す
function Get-ChildCfg { param([string]$Key)
    try {
        $cfg = Get-Content '.agents/workflow/config.json' -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
        $v = $cfg.child_agent.$Key
    } catch {
        return ''
    }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return '' } }
    if ($v -is [string]) { return $v }
    return ''
}

# コマンドを実行し、失敗したら出力の末尾20行を stderr に出す。成功なら $true
function Invoke-CheckCommand { param([string]$Command)
    $xdgNames = 'XDG_CONFIG_HOME', 'XDG_DATA_HOME'
    $saved = @{}
    $isolate = (Get-ChildCfg 'isolate_xdg') -eq 'true'
    if ($isolate) {
        foreach ($n in $xdgNames) {
            $saved[$n] = [Environment]::GetEnvironmentVariable($n)
            [Environment]::SetEnvironmentVariable($n, '.agents/workflow/.config')
        }
    }
    try {
        $o = @(& pwsh -NoProfile -Command $Command 2>&1)
        $c = $LASTEXITCODE
    } finally {
        if ($isolate) {
            foreach ($n in $xdgNames) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
    }
    if ($c -ne 0) {
        $o | ForEach-Object { "$_" } | Select-Object -Last 20 | ForEach-Object { [Console]::Error.WriteLine($_) }
        return $false
    }
    return $true
}

# 3a. 疎通確認
$healthcheck = Get-ChildCfg 'healthcheck_command'
if ($healthcheck) {
    if (-not (Invoke-CheckCommand $healthcheck)) {
        Write-Output "Next: escalate reason=healthcheck"
        exit 30
    }
}

# 3b. ウォームアップ(このサイクルの最初の dispatch のときだけ)
$warmup = Get-ChildCfg 'warmup_command'
if (-not $Pr -and $warmup -and -not (Test-Path '.agents/workflow/runs/*/guard.sha256')) {
    if (-not (Invoke-CheckCommand $warmup)) {
        Write-Output "Next: escalate reason=warmup"
        exit 31
    }
}

# 4. プロンプト生成
if ($Pr) {
    $genOut = @(& pwsh -NoProfile -File "$PSScriptRoot/dispatch-prompt-gen.ps1" -Pr)
} else {
    $genOut = @(& pwsh -NoProfile -File "$PSScriptRoot/dispatch-prompt-gen.ps1" -TaskId $TaskId -Attempt $Attempt)
}
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Output "Next: escalate reason=prompt-gen"
    exit (40 + $code)
}

if ($Pr) {
    $runIdLine = $genOut | ForEach-Object { "$_" } | Where-Object { $_ -match '^RunId: ' } | Select-Object -First 1
    $TaskId = if ($runIdLine) { ($runIdLine -replace '^RunId: ', '').Trim() } else { '' }
    if (-not $TaskId) {
        [Console]::Error.WriteLine("dispatch-prompt-gen -Pr did not report a RunId")
        Write-Output "Next: escalate reason=prompt-gen"
        exit 41
    }
    $runDir = ".agents/workflow/runs/$TaskId-$Attempt"
} else {
    # 5. 状態を in_progress にする
    & pwsh -NoProfile -File "$PSScriptRoot/task-state.ps1" $TaskId start
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Next: escalate reason=task-state"
        exit 50
    }
}

# 6. デタッチ起動
Remove-Item -LiteralPath "$runDir/guard.sha256" -Force -ErrorAction SilentlyContinue
Start-Process pwsh -ArgumentList @('-NoProfile', '-File', "$PSScriptRoot/dispatch-run.ps1", '-TaskId', $TaskId, '-Attempt', "$Attempt")

# dispatch-run が guard.sha256 を作る(起動した)まで待つ
$launchTimeout = 30
if ($env:DISPATCH_START_LAUNCH_TIMEOUT -match '^[0-9]+$') { $launchTimeout = [int]$env:DISPATCH_START_LAUNCH_TIMEOUT }
$deadline = [DateTime]::UtcNow.AddSeconds($launchTimeout)
while (-not (Test-Path -LiteralPath "$runDir/guard.sha256" -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) {
        [Console]::Error.WriteLine("dispatch-run did not start: $runDir/guard.sha256 not found after ${launchTimeout}s")
        Write-Output "Next: escalate reason=launch"
        exit 60
    }
    Start-Sleep -Milliseconds 500
}

Write-Output "Run: $TaskId-$Attempt"
Write-Output "Log: $runDir/output.log"
Write-Output "Watch: Get-Content $runDir/output.log -Wait -Tail 20"
Write-Output "Next: wait"
exit 0
