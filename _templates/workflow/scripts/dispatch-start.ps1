# 子エージェントの起動までの事前チェックを順に行い、デタッチ起動する。失敗した段階で止める
# (止めたときは state.json を変えず、子も起動しない)。
# Usage: dispatch-start.ps1 -TaskId <TaskId> [-Attempt <N>]
# exit:
#   0=起動した / 1=使い方不備
#   11〜15=branch-check -State の 1〜5(stdout の Next: 行はそのまま流す)
#   20=作業ツリーが汚れている / 21=タスクの状態が不正(pending / in_progress 以外、タスク無しを含む)
#   41〜43=dispatch-prompt-gen の 1〜3(依存未完了・report.md の欠落は 42)
#   50=task-state の失敗
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / escalate reason=<理由> 等。
# 使い方不備の exit 1 では出さない)
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
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
$dirty = @(& git status --porcelain)
if ($dirty.Count -gt 0) {
    [Console]::Error.WriteLine("Working tree is not clean:")
    $dirty | ForEach-Object { [Console]::Error.WriteLine($_) }
    Write-Output "Next: escalate reason=dirty-tree"
    exit 20
}

# 3. タスクの状態
$status = ''
try {
    $state = Get-Content '.agents/workflow/state.json' -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    $task = @($state.tasks | Where-Object { $_.id -ceq $TaskId }) | Select-Object -First 1
    if ($task) { $status = "$($task.status)" }
} catch {
    $status = ''
}
if ($status -ne 'pending' -and $status -ne 'in_progress') {
    $shown = if ($status) { $status } else { '<absent>' }
    [Console]::Error.WriteLine("Task $TaskId cannot be started (status: $shown)")
    Write-Output "Next: escalate reason=task-status"
    exit 21
}

# 4. プロンプト生成
$null = & pwsh -NoProfile -File "$PSScriptRoot/dispatch-prompt-gen.ps1" -TaskId $TaskId -Attempt $Attempt
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Output "Next: escalate reason=prompt-gen"
    exit (40 + $code)
}

# 5. 状態を in_progress にする
& pwsh -NoProfile -File "$PSScriptRoot/task-state.ps1" $TaskId start
if ($LASTEXITCODE -ne 0) {
    Write-Output "Next: escalate reason=task-state"
    exit 50
}

# 6. デタッチ起動
Start-Process pwsh -ArgumentList @('-NoProfile', '-File', "$PSScriptRoot/dispatch-run.ps1", '-TaskId', $TaskId, '-Attempt', "$Attempt")

Write-Output "Run: $TaskId-$Attempt"
Write-Output "Log: $runDir/output.log"
Write-Output "Watch: Get-Content $runDir/output.log -Wait -Tail 20"
Write-Output "Next: wait"
exit 0
