# 子エージェントの起動までの事前チェックを順に行い、デタッチ起動する。失敗した段階で止める
# (止めたときは state.json を変えず、子も起動しない)。
# Usage: dispatch-start.ps1 -TaskId <TaskId> [-Attempt <N>] [-SubagentCapable] | dispatch-start.ps1 -Pr [-SubagentCapable]
#   -SubagentCapable: 親がサブエージェントを起動できるとき付ける。起動方法(launcher)を次で決め、
#     プロンプト生成の前に runs/<ID>-<N>/launcher へ cli か subagent を1行で書く
#     (-Pr は値を dispatch-prompt-gen -Pr -Launcher に渡し、prompt-gen が runs/pr-<N>-1/launcher を書く)。
#     config.json の child_agent.subagent(auto / always / never。無い・他の値は auto)が never か、
#     このオプションが無ければ cli。always なら subagent。auto は childprofile の出力形式が
#     claude-stream-json のとき subagent、それ以外は cli
#   launcher が subagent のときは、デタッチ起動の代わりに dispatch-run -PrepareOnly を同期で実行し(失敗は exit 60・
#     Next: escalate reason=launch)、Run:・Launcher: subagent・Prompt:・Workdir:・Output:・Model:
#     (child_agent.subagent_model。無い・空なら default)を出して `Next: subagent <ID> <N>` で exit 0 する
#     (疎通確認・ウォームアップは行わない)。cli のときは出力に `Launcher: cli` 行が加わるだけ
#   -Pr: PR 作成の run(pr-<N>-1)を起動する(タスクの状態確認・task-state は行わず、ウォームアップもしない)
# config.json の max_parallel が 2 以上で -Pr でないときは、作業ツリーの確認を飛ばし、
# タスクの状態の確認の後に dispatch-worktree create で worktree の run にする(Carried: 行と Worktree: 行を出す)
# exit:
#   0=起動した / 1=使い方不備
#   11〜15=branch-check -State の 1〜5(stdout の Next: 行はそのまま流す)
#   20=作業ツリーが汚れている(試行回数 2 以上で fix-notes.md がある場合は確認しない) / 21=タスクの状態が不正(pending / in_progress 以外、タスク無しを含む)
#   30=疎通確認(healthcheck_command)の失敗 / 31=ウォームアップ(warmup_command)の失敗
#   41〜43=dispatch-prompt-gen の 1〜3(依存未完了・report.md の欠落は 42)
#   22=max_parallel が 2 以上で、worktree の作成が dirty-tree(dispatch-worktree の exit 20)
#   50=task-state の失敗
#   61=max_parallel が 2 以上で、worktree の作成に失敗(dispatch-worktree の exit 20 以外)
#   60=dispatch-run の起動を確認できない(guard.sha256 が上限秒数内に現れない)
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / escalate reason=<理由> 等。
# 使い方不備の exit 1 では出さない)
param(
    [string]$TaskId = '',
    [int]$Attempt = 1,
    [switch]$Pr,
    [switch]$SubagentCapable
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

# max_parallel(config.json。整数で 2 以上のときだけ並列。それ以外は 1)
$maxParallel = 1
try {
    $cfgAll = Get-Content '.agents/workflow/config.json' -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    if ($cfgAll.PSObject.Properties['max_parallel']) {
        $mp = $cfgAll.max_parallel
        if (($mp -is [int] -or $mp -is [long]) -and $mp -ge 1) { $maxParallel = [int]$mp }
    }
} catch {
    $maxParallel = 1
}
$parallel = (-not $Pr) -and $maxParallel -ge 2

# 2. 作業ツリー(並列のときは本体に別タスクの変更があってよいので確認しない)
if ($parallel) {
    # 確認しない
} elseif (-not $Pr -and $Attempt -ge 2 -and (Test-Path -LiteralPath "$runDir/fix-notes.md" -PathType Leaf)) {
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

# 3'. worktree の作成(並列のとき。task-state の前に置き、失敗しても state.json を変えない)
if ($parallel) {
    $wtOut = @(& pwsh -NoProfile -File "$PSScriptRoot/dispatch-worktree.ps1" create $TaskId $Attempt)
    $wtCode = $LASTEXITCODE
    if ($wtCode -ne 0) {
        $wtOut | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Next:' } | ForEach-Object { Write-Output $_ }
        if ($wtCode -eq 20) {
            Write-Output "Next: escalate reason=dirty-tree"
            exit 22
        }
        Write-Output "Next: escalate reason=worktree"
        exit 61
    }
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

# 並列のとき、子の起動前の失敗で作った worktree を片付ける(出力は stderr へ)
function Stop-RunWorktree {
    if ($parallel) {
        & pwsh -NoProfile -File "$PSScriptRoot/dispatch-worktree.ps1" abort $TaskId $Attempt | ForEach-Object { [Console]::Error.WriteLine("$_") }
    }
}

# 起動方法(launcher)の決定
$launcher = 'cli'
if ($SubagentCapable) {
    $subMode = Get-ChildCfg 'subagent'
    if ($subMode -eq 'always') {
        $launcher = 'subagent'
    } elseif ($subMode -ne 'never') {
        . "$PSScriptRoot/childprofile.ps1"
        try {
            if ((Get-ChildProfile -Root '.').OutputFormat -eq 'claude-stream-json') { $launcher = 'subagent' }
        } catch {
            $launcher = 'cli'
        }
    }
}
if (-not $Pr) {
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "$runDir/launcher"), "$launcher`n", (New-Object System.Text.UTF8Encoding($false)))
}

# 3a. 疎通確認
$healthcheck = Get-ChildCfg 'healthcheck_command'
if ($launcher -eq 'subagent') { $healthcheck = '' }
if ($healthcheck) {
    if (-not (Invoke-CheckCommand $healthcheck)) {
        Stop-RunWorktree
        Write-Output "Next: escalate reason=healthcheck"
        exit 30
    }
}

# 3b. ウォームアップ(このサイクルの最初の CLI の dispatch のときだけ)
# CLI の run = guard.sha256 があり、launcher が無いか subagent でない run
function Test-CliRun {
    foreach ($d in @(Get-ChildItem -Path '.agents/workflow/runs' -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'guard.sha256') -PathType Leaf)) { continue }
        $launcherFile = Join-Path $d.FullName 'launcher'
        if ((Test-Path -LiteralPath $launcherFile -PathType Leaf) -and ([System.IO.File]::ReadAllText($launcherFile).Trim() -eq 'subagent')) { continue }
        return $true
    }
    return $false
}
$warmup = Get-ChildCfg 'warmup_command'
if (-not $Pr -and $launcher -eq 'cli' -and $warmup -and -not (Test-CliRun)) {
    if (-not (Invoke-CheckCommand $warmup)) {
        Stop-RunWorktree
        Write-Output "Next: escalate reason=warmup"
        exit 31
    }
}

# 4. プロンプト生成
if ($Pr) {
    $genOut = @(& pwsh -NoProfile -File "$PSScriptRoot/dispatch-prompt-gen.ps1" -Pr -Launcher $launcher)
} else {
    $genOut = @(& pwsh -NoProfile -File "$PSScriptRoot/dispatch-prompt-gen.ps1" -TaskId $TaskId -Attempt $Attempt)
}
$code = $LASTEXITCODE
if ($code -ne 0) {
    Stop-RunWorktree
    Write-Output "Next: escalate reason=prompt-gen"
    exit (40 + $code)
}

if ($Pr) {
    $runIdLine = $genOut | ForEach-Object { "$_" } | Where-Object { $_ -match '^RunId: ' } | Select-Object -First 1
    $TaskId = if ($runIdLine) { ($runIdLine -replace '^RunId: ', '').Trim() } else { '' }
    if (-not $TaskId) {
        [Console]::Error.WriteLine("dispatch-prompt-gen -Pr did not report a RunId")
        Stop-RunWorktree
        Write-Output "Next: escalate reason=prompt-gen"
        exit 41
    }
    $runDir = ".agents/workflow/runs/$TaskId-$Attempt"
} else {
    # 5. 状態を in_progress にする
    & pwsh -NoProfile -File "$PSScriptRoot/task-state.ps1" $TaskId start
    if ($LASTEXITCODE -ne 0) {
        Stop-RunWorktree
        Write-Output "Next: escalate reason=task-state"
        exit 50
    }
}

# 6'. サブエージェントでの起動(子は起動せず、guard と git-state の記録だけ同期で行う)
if ($launcher -eq 'subagent') {
    Remove-Item -LiteralPath "$runDir/guard.sha256" -Force -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File "$PSScriptRoot/dispatch-run.ps1" -TaskId $TaskId -Attempt $Attempt -PrepareOnly *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("dispatch-run -PrepareOnly failed: $runDir")
        Write-Output "Next: escalate reason=launch"
        exit 60
    }
    $rootAbs = (Get-Location).Path.Replace('\', '/')
    $workdir = if ($parallel) { "$rootAbs/$runDir/worktree" } else { $rootAbs }
    $subModel = Get-ChildCfg 'subagent_model'
    if (-not $subModel) { $subModel = 'default' }
    Write-Output "Run: $TaskId-$Attempt"
    Write-Output "Launcher: subagent"
    Write-Output "Prompt: $rootAbs/$runDir/prompt.md"
    Write-Output "Workdir: $workdir"
    Write-Output "Output: $rootAbs/$runDir/output.log"
    Write-Output "Model: $subModel"
    Write-Output "Next: subagent $TaskId $Attempt"
    exit 0
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
Write-Output "Launcher: cli"
Write-Output "Log: $runDir/output.log"
Write-Output "Watch: Get-Content $runDir/output.log -Wait -Tail 20"
Write-Output "Watch all: pwsh -NoProfile -File .agents/workflow/scripts/workflow-logs.ps1"
if ($parallel) {
    $wtOut | ForEach-Object { "$_" } | Where-Object { $_ -match '^Carried:' } | ForEach-Object { Write-Output $_ }
    Write-Output "Worktree: $runDir/worktree"
}
Write-Output "Next: wait"
exit 0
