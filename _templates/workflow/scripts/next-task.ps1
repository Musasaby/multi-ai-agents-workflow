# 次に処理するタスクを state.json と tasks.md の依存関係から機械的に選ぶ。
#   1. in_progress / in_review のタスク(再開対象)があれば、state.json 上で最初のもの
#   2. なければ、依存タスクがすべて done の最初の pending タスク
# stdout: "<タスクID> <status>"
# exit: 0=該当あり / 1=使い方・tasks.md/state.json 不備 / 3=全タスク done / 4=実行可能なタスクなし
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot/tasklib.ps1"

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"

foreach ($p in @($TasksPath, $StatePath)) {
    if (-not (Test-Path $p)) {
        [Console]::Error.WriteLine("not found: $p")
        exit 1
    }
}

$lines = @(Split-TaskLines ([System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8)))
try {
    $graph = Resolve-TaskDeps @(Read-TaskList $lines) -CheckCycles
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$stateTasks = @((Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).tasks)
$status = @{}
foreach ($t in $stateTasks) { $status[$t.id] = $t.status }
if ($stateTasks.Count -eq 0) {
    [Console]::Error.WriteLine('state.json has no tasks')
    exit 1
}

foreach ($t in $stateTasks) {
    if ($t.status -in @('in_progress', 'in_review')) {
        Write-Output "$($t.id) $($t.status)"
        exit 0
    }
}

if (@($stateTasks | Where-Object { $_.status -ne 'done' }).Count -eq 0) {
    [Console]::Error.WriteLine('All tasks are done')
    exit 3
}

$blocked = @()
foreach ($t in $stateTasks) {
    if ($t.status -ne 'pending') { continue }
    if (-not $graph.Contains($t.id)) {
        [Console]::Error.WriteLine("Task '$($t.id)' is in state.json but not in tasks.md")
        exit 1
    }
    $waiting = @($graph[$t.id] | Where-Object { $status[$_] -ne 'done' })
    if ($waiting.Count -eq 0) {
        Write-Output "$($t.id) pending"
        exit 0
    }
    $desc = ($waiting | ForEach-Object { $s = if ($status.ContainsKey($_)) { $status[$_] } else { 'missing' }; "$_($s)" }) -join ', '
    $blocked += "$($t.id): waiting for $desc"
}

[Console]::Error.WriteLine('No runnable task. Blocked:')
foreach ($b in $blocked) { [Console]::Error.WriteLine("  $b") }
foreach ($t in $stateTasks) {
    if ($t.status -eq 'failed') { [Console]::Error.WriteLine("  $($t.id): failed") }
}
exit 4
