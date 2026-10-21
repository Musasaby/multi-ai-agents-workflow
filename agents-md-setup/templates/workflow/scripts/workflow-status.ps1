# 進捗と次の操作を短く出す(読み取り専用)。
# 引数: [-Summary](省略時は通常モード)
# stdout: "Progress: <done>/<全タスク> done"、"Group: <名前> <done>/<数>"(グループ区切りがあるときだけ)、
#       "Current: <ID> <status> | <title>" / "Current: none"、
#       "Run: <ID>-<N> running elapsed=<秒>s log_idle=<秒>s" / "Run: <ID>-<N> finished"(in_progress で run があるときだけ)、
#       "Failed: T3, T5"(failed があるときだけ)、"PR: <state> <url>" / "PR: none" / "PR: unknown"(finish / group-advance のときだけ)、
#       "Comprehension: unanswered=<n>[ <ファイル名> ...]"、最後に "Next: ..."
#       -Summary のときは、先頭に "Task <ID> <status> <commit 先頭7文字 | -> retries=<n> | <title>"(全タスク)と
#       要件の行("Requirement ..."・"Summary: ...")を足し、Next の直前に "Worktree: clean" / "Worktree: dirty <n>" を足す
# exit: 0=出力あり / 1=使い方・tasks.md/state.json 不備・next-task.ps1 の失敗
param([switch]$Summary)

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: workflow-status.ps1 [-Summary]')
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot/tasklib.ps1"

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"
$RunsDir = "$Root/.agents/workflow/runs"
$ComprehensionDir = "$Root/.agents/workflow/comprehension"

foreach ($p in @($TasksPath, $StatePath)) {
    if (-not (Test-Path $p)) {
        [Console]::Error.WriteLine("not found: $p")
        exit 1
    }
}

# --- 次の操作(next-task.ps1) ---
$nextErrFile = [System.IO.Path]::GetTempFileName()
try {
    $nextOut = @(& pwsh -NoProfile -File "$PSScriptRoot/next-task.ps1" 2> $nextErrFile)
    $nextCode = $LASTEXITCODE
    if ($nextCode -eq 1) {
        [Console]::Error.Write([System.IO.File]::ReadAllText($nextErrFile))
        exit 1
    }
} finally {
    Remove-Item $nextErrFile -ErrorAction SilentlyContinue
}
$nextLine = ''
foreach ($l in $nextOut) {
    $s = "$l".TrimEnd("`r")
    if ($s.StartsWith('Next:')) { $nextLine = $s }
}

$lines = @(Split-TaskLines ([System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8)))
$tasks = @(Read-TaskList $lines)
$state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stTasks = @($state.tasks)

# --- PR の状態(finish / group-advance のときだけ) ---
$prState = ''
$prUrl = ''
if ($nextLine -ceq 'Next: finish' -or $nextLine -ceq 'Next: group-advance') {
    $prState = 'unknown'
    $branch = ''
    if ($state.PSObject.Properties['branch'] -and $null -ne $state.branch) { $branch = [string]$state.branch }
    if ($branch -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $ghOut = $null
            $ghCode = 1
            try {
                $ghOut = & gh pr view $branch --json state,url 2> $errFile
                $ghCode = $LASTEXITCODE
            } catch {
                $ghCode = 127
            }
            if ($ghCode -eq 0) {
                try {
                    $pr = (@($ghOut) -join "`n").Trim() | ConvertFrom-Json
                    $s = "$($pr.state)"
                    if ($s) {
                        $prState = $s
                        $prUrl = "$($pr.url)"
                    }
                } catch {
                    $prState = 'unknown'
                }
            } elseif ([System.IO.File]::ReadAllText($errFile) -match '(?i)no pull requests found') {
                $prState = 'none'
            }
        } finally {
            Remove-Item $errFile -ErrorAction SilentlyContinue
        }
    }
}

$statusOf = @{}
foreach ($t in $stTasks) { $statusOf["$($t.id)"] = "$($t.status)" }
$titleOf = @{}
foreach ($t in $tasks) { $titleOf[$t.id] = $t.title }
$done = @($stTasks | Where-Object { "$($_.status)" -eq 'done' }).Count
$out = [System.Collections.Generic.List[string]]::new()

# --- Task / Requirement(-Summary のときだけ) ---
if ($Summary) {
    foreach ($t in $stTasks) {
        $commit = if ($t.commit) { ([string]$t.commit).Substring(0, [Math]::Min(7, ([string]$t.commit).Length)) } else { '-' }
        $retries = if ($null -ne $t.retries) { [string]$t.retries } else { '0' }
        $out.Add("Task $($t.id) $($t.status) $commit retries=$retries | $($titleOf["$($t.id)"])")
    }
    try {
        foreach ($l in @(Get-RequirementStatusLines $tasks $lines $stTasks)) { $out.Add($l) }
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

$out.Add("Progress: $done/$($stTasks.Count) done")

# --- Group ---
$order = @(Get-GroupOrder $lines)
if ($order.Count -ge 2) {
    $group = $null
    if ($state.PSObject.Properties['group'] -and $null -ne $state.group) { $group = [string]$state.group }
    if ($null -eq $group -or $order -cnotcontains $group) {
        $group = $null
        foreach ($t in $tasks) {
            if ($statusOf[$t.id] -ne 'done') { $group = $t.group; break }
        }
    }
    if ($null -ne $group) {
        $members = @($tasks | Where-Object { $_.group -ceq $group })
        $nDone = @($members | Where-Object { $statusOf[$_.id] -eq 'done' }).Count
        $gname = if ($group -eq '') { '(default)' } else { $group }
        $out.Add("Group: $gname $nDone/$($members.Count)")
    }
}

# --- Current / Run ---
$current = $stTasks | Where-Object { "$($_.status)" -in @('in_progress', 'in_review') } | Select-Object -First 1
$runShown = $false
if ($null -eq $current) {
    $out.Add('Current: none')
} else {
    $cid = "$($current.id)"
    $out.Add("Current: $cid $($current.status) | $($titleOf[$cid])")
    if ("$($current.status)" -eq 'in_progress' -and (Test-Path $RunsDir -PathType Container)) {
        $nums = @()
        foreach ($d in Get-ChildItem $RunsDir -Directory) {
            if ($d.Name -match ('^' + [regex]::Escape($cid) + '-(\d+)$')) { $nums += [int]$Matches[1] }
        }
        if ($nums.Count -gt 0) {
            $runId = "$cid-$(($nums | Measure-Object -Maximum).Maximum)"
            $runDir = "$RunsDir/$runId"
            $guard = "$runDir/guard.sha256"
            if (Test-Path $guard -PathType Leaf) {
                $runShown = $true
                if (Test-Path "$runDir/done") {
                    $out.Add("Run: $runId finished")
                } else {
                    $now = Get-Date
                    $log = "$runDir/output.log"
                    $idle = if (Test-Path $log -PathType Leaf) { [string][int]($now - (Get-Item $log).LastWriteTime).TotalSeconds } else { '-' }
                    $elapsed = [int]($now - (Get-Item $guard).LastWriteTime).TotalSeconds
                    $out.Add("Run: $runId running elapsed=${elapsed}s log_idle=${idle}s")
                }
            }
        }
    }
}

# --- Failed ---
$failed = @($stTasks | Where-Object { "$($_.status)" -eq 'failed' } | ForEach-Object { "$($_.id)" })
if ($failed.Count -gt 0) { $out.Add('Failed: ' + ($failed -join ', ')) }

# --- PR ---
if ($prState) {
    if ($prState -eq 'none' -or $prState -eq 'unknown') {
        $out.Add("PR: $prState")
    } else {
        $out.Add("PR: $prState" + $(if ($prUrl) { " $prUrl" } else { '' }))
    }
}

# --- Comprehension ---
$unanswered = @()
if (Test-Path $ComprehensionDir -PathType Container) {
    $names = @(Get-ChildItem $ComprehensionDir -File -Filter '*.md' | ForEach-Object { $_.Name } | Where-Object { $_.EndsWith('.md') })
    [array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) {
        $text = [System.IO.File]::ReadAllText("$ComprehensionDir/$name", [System.Text.Encoding]::UTF8)
        foreach ($l in ($text -split "`n")) {
            if ($l.Trim() -ceq '**あなたの回答**: <!-- ここに記入 -->') { $unanswered += $name; break }
        }
    }
}
$out.Add("Comprehension: unanswered=$($unanswered.Count)" + (($unanswered | ForEach-Object { " $_" }) -join ''))

# --- Worktree(-Summary のときだけ git を呼ぶ) ---
if ($Summary) {
    $nDirty = 0
    try {
        $porcelain = @(& git status --porcelain 2> $null)
        if ($LASTEXITCODE -eq 0) {
            $nDirty = @($porcelain | Where-Object { "$_".TrimEnd("`r").Length -gt 0 }).Count
        }
    } catch {
        $nDirty = 0
    }
    $out.Add($(if ($nDirty -eq 0) { 'Worktree: clean' } else { "Worktree: dirty $nDirty" }))
}

# --- Next ---
if ($runShown) {
    $out.Add('Next: wait')
} elseif ($prState -eq 'none') {
    $out.Add('Next: create-pr')
} elseif ($prState -ceq 'OPEN') {
    $out.Add('Next: wait-merge')
} elseif ($prState -ceq 'CLOSED') {
    $out.Add('Next: escalate reason=pr-closed')
} else {
    $out.Add($nextLine)
}

foreach ($l in $out) { Write-Output $l }
exit 0
