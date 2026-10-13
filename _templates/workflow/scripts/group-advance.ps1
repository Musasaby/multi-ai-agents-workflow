# グループ完了後の PR 状態を gh で機械的に判定し、マージ済みなら次グループのブランチへ
# 切り替える(Issue #30 改善提案 3)。state.json の branch / group を更新する。
# Usage: group-advance.ps1 [-Branch <新ブランチ名>]
# 前提チェック(満たさなければ exit 1。何も書き換えない):
#   - next-task 相当の判定で作業グループが完了していること
#   - git status --porcelain が空であること
# gh pr view <state.json の branch> --json state,url の結果で分岐する:
#   - PR なし(gh が「no pull requests found」で失敗)→ stdout "NO_PR"、exit 7(親は PR 作成へ)
#   - OPEN   → stdout "OPEN <PR URL>"、exit 8(マージ待ち。親は報告して停止)
#   - CLOSED → PR がマージされずに閉じている。stderr に説明、exit 9(エスカレーション)
#   - MERGED → main を最新化(git switch main + git pull --ff-only)し、-Branch で指定した
#              名前(develop/ 始まり。必須)のブランチを作成・切替。state.json の branch を
#              新ブランチ名、group を次のグループ(未完了タスクを含む最初のグループ)に更新
#              して exit 0。stdout に "ADVANCED <新ブランチ名> <新グループ名>"
# exit: 0=切替完了 / 1=使い方・前提不備 / 7=PR 未作成 / 8=マージ待ち / 9=PR 閉鎖(未マージ)
#       git / gh の失敗時は何も書き換えず、その exit code を返す
param([string]$Branch)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$usage = 'Usage: group-advance.ps1 [-Branch <new-branch-name>]'

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Set-StateField {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

if ($Branch -and $Branch -cnotmatch '^develop/') {
    Fail "Invalid -Branch: '$Branch' (must start with 'develop/')"
}

Set-Location $PSScriptRoot\..\..\..
$tasksPath = '.agents/workflow/tasks.md'
$statePath = '.agents/workflow/state.json'
$configPath = '.agents/workflow/config.json'
foreach ($p in @($tasksPath, $statePath)) {
    if (-not (Test-Path $p)) { Fail "not found: $p" }
}
. "$PSScriptRoot/tasklib.ps1"

# --- 前提チェック: 作業グループの完了判定(next-task と同じグループ判定) ---
$lines = @(Split-TaskLines ([System.IO.File]::ReadAllText($tasksPath, [System.Text.Encoding]::UTF8)))
$tasks = @(Read-TaskList $lines)
try {
    [void](Resolve-TaskDeps $tasks -CheckCycles)
    [void](Test-GroupDeps $tasks (Get-GroupOrder $lines))
} catch {
    Fail $_.Exception.Message
}

$state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stateTasks = @($state.tasks)
if ($stateTasks.Count -eq 0) { Fail 'state.json has no tasks' }
$status = @{}
foreach ($t in $stateTasks) { $status[$t.id] = $t.status }

# config.json が無い・読めない場合は branch_per_group の既定値(true)を使う
$branchPerGroup = $true
try {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.PSObject.Properties['branch_per_group'] -and $null -ne $config.branch_per_group) {
        $branchPerGroup = [bool]$config.branch_per_group
    }
} catch {
    $branchPerGroup = $true
}

$groupOf = @{}
foreach ($t in $tasks) { $groupOf[$t.id] = $t.group }
$groupNames = @(Get-GroupOrder $lines)
# branch_per_group が false、またはグループ区切りが無い場合は全タスクを1グループとして扱う
$groupMode = $branchPerGroup -and @($groupNames | Where-Object { $_ -cne '' }).Count -gt 0

# 未完了タスクを含む最初のグループ(groupNames 順)。なければ $null。
# グループ名は大文字小文字を区別するため -ceq で比較する
function Get-UnfinishedGroup {
    foreach ($name in $groupNames) {
        foreach ($id in $groupOf.Keys) {
            if ($groupOf[$id] -cne $name) { continue }
            if ($status[$id] -cne 'done') { return $name }
        }
    }
    return $null
}

if ($groupMode) {
    $workGroup = $null
    if ($state.PSObject.Properties['group'] -and $null -ne $state.group) { $workGroup = $state.group }
    if ($null -eq $workGroup -or $groupNames -cnotcontains $workGroup) {
        Fail "state.json 'group' is missing or unknown: '$workGroup' (group-advance is only for the group boundary reported by next-task, exit 6)"
    }
    $candidates = @($stateTasks | Where-Object { $groupOf.ContainsKey($_.id) -and $groupOf[$_.id] -ceq $workGroup })
} else {
    $workGroup = ''
    $candidates = $stateTasks
}

if ($candidates.Count -eq 0) { Fail "No tasks belong to the work group '$workGroup'" }
$notDone = @($candidates | Where-Object { $_.status -ne 'done' } | ForEach-Object { $_.id })
if ($notDone.Count -gt 0) {
    Fail ('Work group is not complete: ' + ($notDone -join ', ') + ' (group-advance is only for the group boundary reported by next-task, exit 6)')
}
$nextGroup = Get-UnfinishedGroup

$stateBranch = ''
if ($state.PSObject.Properties['branch'] -and $null -ne $state.branch) { $stateBranch = [string]$state.branch }
if (-not $stateBranch) { Fail 'state.json has no branch (run next-task / state-sync first)' }

# --- 前提チェック: 作業ツリーが clean であること ---
$gitStatus = @(& git status --porcelain 2>&1 | ForEach-Object { "$_" })
$gitCode = $LASTEXITCODE
if ($gitCode -ne 0) { Fail "git status failed (exit $gitCode): $($gitStatus -join "`n")" $gitCode }
if (@($gitStatus | Where-Object { $_ -ne '' }).Count -gt 0) {
    Fail "Working tree is not clean (commit or stash before advancing the group):`n$($gitStatus -join "`n")"
}

# --- PR 状態の判定(gh の失敗は「PR なし」のメッセージだけ例外的に NO_PR 扱い) ---
$errFile = [System.IO.Path]::GetTempFileName()
try {
    try {
        $ghOut = & gh pr view $stateBranch --json state,url 2> $errFile
        $ghCode = $LASTEXITCODE
    } catch {
        Fail "gh could not be executed: $($_.Exception.Message)" 127
    }
    if ($ghCode -ne 0) {
        $ghErr = [System.IO.File]::ReadAllText($errFile)
        if ($ghErr -match '(?i)no pull request') {
            Write-Output 'NO_PR'
            exit 7
        }
        Fail "gh pr view failed (exit $ghCode): $ghErr" $ghCode
    }
    $ghJson = (@($ghOut) -join "`n").Trim()
    try {
        $pr = $ghJson | ConvertFrom-Json
    } catch {
        Fail "Failed to parse gh pr view output (expected JSON with 'state'): $ghJson"
    }
    $prState = "$($pr.state)"
    $prUrl = "$($pr.url)"

    if ($prState -ceq 'OPEN') {
        Write-Output "OPEN $prUrl"
        exit 8
    }
    if ($prState -ceq 'CLOSED') {
        Fail "PR for '$stateBranch' is CLOSED without merging (escalate: check why it was closed, then reopen or recreate the PR)" 9
    }
    if ($prState -cne 'MERGED') {
        Fail "Unexpected PR state: '$prState' (expected OPEN, MERGED or CLOSED)"
    }

    # --- MERGED: 次グループのブランチを作成して切替し、state.json を更新する ---
    if (-not $Branch) {
        Fail "$usage`n-Branch <new-branch-name> is required when the PR is merged (the next group works on a new branch)"
    }
    if ($null -eq $nextGroup) {
        Fail 'No group with unfinished tasks remains; nothing to advance to'
    }

    & git switch main 1> $null 2> $errFile
    $gitCode = $LASTEXITCODE
    if ($gitCode -ne 0) { Fail "git switch main failed (exit $gitCode): $([System.IO.File]::ReadAllText($errFile))" $gitCode }

    & git pull --ff-only 1> $null 2> $errFile
    $gitCode = $LASTEXITCODE
    if ($gitCode -ne 0) { Fail "git pull --ff-only failed (exit $gitCode): $([System.IO.File]::ReadAllText($errFile))" $gitCode }

    & git switch -c $Branch 1> $null 2> $errFile
    $gitCode = $LASTEXITCODE
    if ($gitCode -ne 0) { Fail "git switch -c '$Branch' failed (exit $gitCode): $([System.IO.File]::ReadAllText($errFile))" $gitCode }

    Set-StateField $state 'branch' $Branch
    Set-StateField $state 'group' $nextGroup
    Set-StateField $state 'updated_at' (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) $statePath), ($state | ConvertTo-Json -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))

    Write-Output "ADVANCED $Branch $nextGroup"
    exit 0
} finally {
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}
