param(
    [string]$TaskId,
    [int]$Attempt = 1,
    [switch]$Pr
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"
$ConfigPath = "$Root/.agents/workflow/config.json"
$RunsBase = "$Root/.agents/workflow/runs"

# --- PR mode: PR作成を子に単発依頼するプロンプトを生成する ---
# 対象タスク = state.json で done かつ commit が git log <base>..HEAD に含まれるもの。
# 出力先は runs/pr-<連番>-1/prompt.md。stdout に "RunId: pr-<連番>" を出す。
if ($Pr) {
    $baseBranch = 'main'
    $branch = "$(git branch --show-current)".Trim()
    if (-not $branch -or $branch -eq $baseBranch) {
        [Console]::Error.WriteLine("PR mode must be run on a work branch (current: '$branch')")
        exit 1
    }
    git rev-parse --verify --quiet $baseBranch *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Base branch '$baseBranch' not found")
        exit 1
    }
    if (-not (Test-Path $StatePath)) {
        [Console]::Error.WriteLine("state.json not found: $StatePath")
        exit 1
    }
    $commits = @(git log "$baseBranch..HEAD" --format=%H)
    $selected = @()
    foreach ($t in (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).tasks) {
        $c = $t.commit
        if ($t.status -eq 'done' -and $c -and @($commits | Where-Object { $_.StartsWith($c) }).Count -gt 0) {
            $selected += "- $($t.id): $($t.title) (commit $c)"
        }
    }
    if ($selected.Count -eq 0) {
        [Console]::Error.WriteLine("No done tasks whose commit is in $baseBranch..HEAD (nothing to include in the PR)")
        exit 1
    }
    $prN = 1
    if (Test-Path $RunsBase) {
        Get-ChildItem -Path $RunsBase -Directory | Where-Object { $_.Name -match '^pr-(\d+)-1$' } | ForEach-Object {
            $n = [int]$Matches[1]
            if ($n -ge $prN) { $prN = $n + 1 }
        }
    }
    $prRunDir = "$RunsBase/pr-$prN-1"
    $null = New-Item -ItemType Directory -Force $prRunDir
    $text = Get-Content "$PSScriptRoot/dispatch-pr-prompt-template.md" -Raw -Encoding UTF8
    $text = $text.Replace('{task_list}', ($selected -join "`n"))
    $text = $text.Replace('{branch}', $branch)
    $text = $text.Replace('{base_branch}', $baseBranch)
    $text = $text.Replace('{run_dir}', ".agents/workflow/runs/pr-$prN-1")
    [System.IO.File]::WriteAllText("$prRunDir/prompt.md", $text, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Generated: $prRunDir/prompt.md"
    Write-Output "RunId: pr-$prN"
    exit 0
}

if (-not $TaskId) {
    [Console]::Error.WriteLine("Usage: dispatch-prompt-gen.ps1 -TaskId <TaskId> [-Attempt <n>] | dispatch-prompt-gen.ps1 -Pr")
    exit 1
}
# パスや埋め込みに使うため、タスクIDと試行回数の形式を検証する
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt: '$TaskId' '$Attempt'")
    exit 1
}
$RunDir = "$RunsBase/$TaskId-$Attempt"
$PromptPath = "$RunDir/prompt.md"
$TemplatePath = "$PSScriptRoot/dispatch-prompt-template.md"

if (-not (Test-Path $TasksPath)) {
    Write-Error "tasks.md not found: $TasksPath"
    exit 1
}

$taskSection = $null
$inSection = $false
$sectionLines = @()

foreach ($line in (Get-Content $TasksPath -Raw -Encoding UTF8 -ErrorAction Stop) -split "`n") {
    if ($line -match '^## ') {
        if ($inSection) { break }
        if ($line -match "^## ${TaskId}:") {
            $inSection = $true
        }
    }
    if ($inSection) { $sectionLines += $line }
}

if (-not $inSection -or $sectionLines.Count -eq 0) {
    Write-Error "Task '$TaskId' not found in $TasksPath"
    exit 1
}

$taskSection = ($sectionLines -join "`n").TrimEnd()

$title = $null
foreach ($line in $sectionLines) {
    if ($line -match "^## ${TaskId}:\s*(.+)") {
        $title = $Matches[1].Trim()
        break
    }
}

# 依存欄の検証(不正なトークンは黙って捨てずにエラーにする)
. "$PSScriptRoot/tasklib.ps1"
$allTasks = @(Read-TaskList @(Split-TaskLines ([System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8))))
$targetTask = $allTasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
try {
    $deps = @(Get-TaskDeps $targetTask)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$unknownDeps = @($deps | Where-Object { $_ -notin $allTasks.id })
if ($unknownDeps.Count -gt 0) {
    [Console]::Error.WriteLine("${TaskId}: depends on unknown task(s) $($unknownDeps -join ', ') (not found in tasks.md)")
    exit 1
}

if ($deps.Count -gt 0) {
    if (-not (Test-Path $StatePath)) {
        Write-Error "state.json not found: $StatePath"
        exit 1
    }
    $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $missing = @()
    foreach ($depId in $deps) {
        $depTask = $state.tasks | Where-Object { $_.id -eq $depId }
        if (-not $depTask -or $depTask.status -ne 'done') {
            $missing += "${depId}: status is not done"
        }
    }

    foreach ($depId in $deps) {
        if ($depId -notin ($missing | ForEach-Object { $_ -replace ':.*', '' })) {
            $maxAttempt = 0
            $depRunBase = "$RunsBase/$depId-*"
            if (Test-Path $RunsBase) {
                Get-ChildItem -Path $RunsBase -Directory -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match "^${depId}-(\d+)$"
                } | ForEach-Object {
                    $n = [int]$Matches[1]
                    if ($n -gt $maxAttempt) { $maxAttempt = $n }
                }
            }
            $reportPath = "$RunsBase/$depId-$maxAttempt/report.md"
            if (-not (Test-Path $reportPath)) {
                $missing += "${depId}: report.md not found at runs/${depId}-${maxAttempt}/report.md"
            }
        }
    }

    if ($missing.Count -gt 0) {
        Remove-Item -Force -ErrorAction SilentlyContinue $PromptPath
        Write-Error "Handoff guard failed:`n$($missing -join "`n")"
        exit 2
    }
}

$handoffReports = ''
if ($deps.Count -gt 0) {
    $handoffLines = @('## 前提タスクの成果(引き継ぎ)', '')
    foreach ($depId in $deps) {
        $depTitle = ''
        $stateData = $null
        if (Test-Path $StatePath) {
            $stateData = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $depEntry = $stateData.tasks | Where-Object { $_.id -eq $depId }
            if ($depEntry) { $depTitle = $depEntry.title }
        }
        $maxAttempt = 0
        if (Test-Path $RunsBase) {
            Get-ChildItem -Path $RunsBase -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match "^${depId}-(\d+)$"
            } | ForEach-Object {
                $n = [int]$Matches[1]
                if ($n -gt $maxAttempt) { $maxAttempt = $n }
            }
        }
        $reportPath = "$RunsBase/$depId-$maxAttempt/report.md"
        $reportContent = Get-Content $reportPath -Raw -Encoding UTF8
        $handoffLines += "### ${depId}: ${depTitle}"
        $handoffLines += $reportContent.TrimEnd()
        $handoffLines += ''
    }
    $handoffReports = $handoffLines -join "`n"
}

$fixNotes = ''
if ($Attempt -ge 2) {
    $fixNotesPath = "$RunDir/fix-notes.md"
    if (-not (Test-Path $fixNotesPath)) {
        Write-Error "fix-notes.md not found: $fixNotesPath"
        exit 3
    }
    $fixContent = Get-Content $fixNotesPath -Raw -Encoding UTF8
    $fixNotes = "## レビュー指摘事項(最優先で対応)`n$($fixContent.TrimEnd())"
}

$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$verifyLines = @()
$hasVerify = $false

if ($config.quality_gate) {
    if ($config.quality_gate.child_dispatch_command) {
        $verifyLines += "- $($config.quality_gate.child_dispatch_command)"
        $hasVerify = $true
    } elseif ($config.quality_gate.steps) {
        foreach ($step in $config.quality_gate.steps) {
            if ($step.blocking) {
                $verifyLines += "- $($step.name): $($step.command)"
                $hasVerify = $true
            }
        }
    }
}
if ($config.test_command) {
    $verifyLines += "- $($config.test_command)"
    $hasVerify = $true
}
if (-not $hasVerify) {
    $verifyLines += '(設定ファイルの test_command / quality_gate で検証コマンドを指定してください)'
}

$verifyInstruction = $verifyLines -join "`n"

if (-not (Test-Path $RunDir)) {
    $null = New-Item -ItemType Directory -Path $RunDir -Force
}

if (Test-Path $PromptPath) {
    Remove-Item -Force $PromptPath
}

$template = Get-Content $TemplatePath -Raw -Encoding UTF8
$generated = $template.Replace('{fix_notes}', $fixNotes)
$generated = $generated.Replace('{task_section}', $taskSection)
$generated = $generated.Replace('{handoff_reports}', $handoffReports)
$generated = $generated.Replace('{verify_instruction}', $verifyInstruction)

[System.IO.File]::WriteAllText($PromptPath, $generated, [System.Text.UTF8Encoding]::new($false))
Write-Output "Generated: $PromptPath"
exit 0
