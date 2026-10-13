# 次に処理するタスクを state.json と tasks.md の依存関係から機械的に選ぶ。
#   1. in_progress / in_review のタスク(再開対象)があれば、state.json 上で最初のもの
#   2. なければ、依存タスクがすべて done の最初の pending タスク
# branch_per_group が有効で tasks.md にグループ区切りがある場合は、state.json の
# group(現在の作業グループ。無い/未知のグループ名なら「未完了タスクを含む最初のグループ」)
# のタスクだけを候補にする。作業グループが全タスク done で他グループに未完了があれば
# stdout に作業グループ名を出して exit 6(グループ境界で停止する合図)。
# stdout: "<タスクID> <status>" / グループ完了時は "<作業グループ名>"
# exit: 0=該当あり / 1=使い方・tasks.md/state.json 不備 / 3=全タスク done /
#       4=実行可能なタスクなし / 6=作業グループ完了(他グループに未完了あり)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot/tasklib.ps1"

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"
$ConfigPath = "$Root/.agents/workflow/config.json"

foreach ($p in @($TasksPath, $StatePath)) {
    if (-not (Test-Path $p)) {
        [Console]::Error.WriteLine("not found: $p")
        exit 1
    }
}

$lines = @(Split-TaskLines ([System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8)))
$tasks = @(Read-TaskList $lines)
try {
    $graph = Resolve-TaskDeps $tasks -CheckCycles
    [void](Test-GroupDeps $tasks (Get-GroupOrder $lines))
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stateTasks = @($state.tasks)
$status = @{}
foreach ($t in $stateTasks) { $status[$t.id] = $t.status }
if ($stateTasks.Count -eq 0) {
    [Console]::Error.WriteLine('state.json has no tasks')
    exit 1
}

# config.json が無い・読めない場合は branch_per_group の既定値(true)を使う
$branchPerGroup = $true
try {
    $config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
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

if ($groupMode) {
    $workGroup = $null
    if ($state.PSObject.Properties['group'] -and $null -ne $state.group) { $workGroup = $state.group }
    if ($null -eq $workGroup -or $groupNames -cnotcontains $workGroup) {
        # group フィールドが無い(または未知の名前の)既存 state.json は後方互換として、
        # 未完了タスクを含む最初のグループを作業グループとみなす(next-task は書き換えない)
        $workGroup = Get-UnfinishedGroup
        if ($null -eq $workGroup) {
            # 到達しないはず(全タスク done なら上で exit 3)
            $workGroup = $groupNames[0]
        }
    }
    $candidates = @($stateTasks | Where-Object { $groupOf.ContainsKey($_.id) -and $groupOf[$_.id] -ceq $workGroup })
    $others = @($stateTasks | Where-Object { -not ($groupOf.ContainsKey($_.id) -and $groupOf[$_.id] -ceq $workGroup) })
    if ($candidates.Count -gt 0 -and @($candidates | Where-Object { $_.status -ne 'done' }).Count -eq 0 `
            -and @($others | Where-Object { $_.status -ne 'done' }).Count -gt 0) {
        Write-Output $workGroup
        exit 6
    }
} else {
    $candidates = $stateTasks
}

$blocked = @()
foreach ($t in $candidates) {
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
foreach ($t in $candidates) {
    if ($t.status -eq 'failed') { [Console]::Error.WriteLine("  $($t.id): failed") }
}
exit 4
