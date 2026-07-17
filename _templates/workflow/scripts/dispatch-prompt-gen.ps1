param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"
$ConfigPath = "$Root/.agents/workflow/config.json"
$RunsBase = "$Root/.agents/workflow/runs"
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

$deps = @()
foreach ($line in $sectionLines) {
    if ($line -match '^\s*-\s+\*\*依存\*\*:\s*(.+)') {
        $depStr = $Matches[1].Trim()
        if ($depStr -ne 'なし') {
            $deps = $depStr -split '\s*,\s*' | Where-Object { $_ -match '^T\d+$' }
        }
        break
    }
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
