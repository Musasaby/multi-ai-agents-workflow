# in_review のタスクの本体をコミットし、state.json を done にして、状態ファイルもコミットする。
# Usage: task-commit.ps1 -TaskId <ID> -Type <type> -Description <説明>
#   1. 検証: TaskId の形式・type(feat|fix|refactor|docs|test|chore|perf|ci)・説明(空でなく改行なし)・
#      state.json の対象タスクが in_review
#   2. branch-check.ps1 -State が非0なら、その出力を流して exit 10 + その code
#   3. .agents/workflow を除く変更をステージする。ステージが空なら exit 20
#   4. "<type>: <説明>" + 空行 + "Task: <TaskId> (<state.json の source>)" でコミットする
#   5. task-state.ps1 <TaskId> done -Commit <本体のハッシュ>
#   6. state.json・tasks.md・comprehension のうち git に無視されていないものを
#      "chore: <TaskId> の進捗状態を更新" でコミットする(追跡しないリポジトリでは何もしない)
# exit: 0=コミットした / 1=使い方不備・検証失敗 / 11〜15=branch-check の exit 1〜5 /
#       20=コミットする変更が無い / 30=git commit 失敗 / 31=task-state の done 失敗
# stdout の最後の行に "Next: <行動>" を出す: 0=continue / 20=escalate reason=no-changes
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$Type,
    [Parameter(Mandatory = $true)][string]$Description
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

$usage = 'Usage: task-commit.ps1 -TaskId <ID> -Type <feat|fix|refactor|docs|test|chore|perf|ci> -Description <説明>'
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$') { Fail "Invalid TaskId: '$TaskId'" }
if (@('feat', 'fix', 'refactor', 'docs', 'test', 'chore', 'perf', 'ci') -cnotcontains $Type) {
    Fail "Invalid type: '$Type'`n$usage"
}
if ([string]::IsNullOrEmpty($Description)) { Fail 'Description must not be empty' }
if ($Description -match "[\r\n]") { Fail 'Description must not contain a newline' }

Set-Location $PSScriptRoot\..\..\..
$statePath = '.agents/workflow/state.json'
if (-not (Test-Path $statePath)) { Fail "state.json not found: $statePath" }

# --- 1. state.json の検証(対象タスクが in_review)と source の取得 ---
$state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$task = $state.tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
if (-not $task) { Fail "Task '$TaskId' not found in state.json" }
if ($task.status -ne 'in_review') { Fail "${TaskId}: status is '$($task.status)' (expected in_review)" }
$source = if ($state.source) { "$($state.source)" } else { '' }

# --- 2. ブランチの判定 ---
& pwsh -NoProfile -File "$PSScriptRoot/branch-check.ps1" -State
$bcCode = $LASTEXITCODE
if ($bcCode -ne 0) { exit (10 + $bcCode) }

# --- 3. 本体のステージ ---
git add -A -- . ':(exclude).agents/workflow'
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    [Console]::Error.WriteLine("No changes to commit for $TaskId")
    Write-Output 'Next: escalate reason=no-changes'
    exit 20
}

# --- 4. 本体のコミット ---
$msgFile = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($msgFile, "${Type}: $Description`n`nTask: $TaskId ($source)`n", [System.Text.UTF8Encoding]::new($false))
    git commit -q -F $msgFile
    if ($LASTEXITCODE -ne 0) { Fail 'git commit failed' 30 }
} finally {
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
}
$hash = (git rev-parse HEAD).Trim()

# --- 5. 状態を done にする ---
& pwsh -NoProfile -File "$PSScriptRoot/task-state.ps1" $TaskId done -Commit $hash > $null
if ($LASTEXITCODE -ne 0) {
    Fail "task-state.ps1 done failed (the body commit $hash was already created)" 31
}

# --- 6. 状態ファイルのコミット(無視されていないものだけ) ---
foreach ($p in @('.agents/workflow/state.json', '.agents/workflow/tasks.md', '.agents/workflow/comprehension')) {
    if (Test-Path $p) {
        git check-ignore -q $p
        if ($LASTEXITCODE -ne 0) { git add -- $p }
    }
}
$stateCommit = 'none'
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git commit -q -m "chore: $TaskId の進捗状態を更新"
    if ($LASTEXITCODE -ne 0) { Fail 'git commit (state files) failed' 30 }
    $stateCommit = (git rev-parse HEAD).Trim().Substring(0, 7)
}

Write-Output "Committed: $($hash.Substring(0, 7)) ${Type}: $Description"
Write-Output "State commit: $stateCommit"
Write-Output 'Next: continue'
exit 0
