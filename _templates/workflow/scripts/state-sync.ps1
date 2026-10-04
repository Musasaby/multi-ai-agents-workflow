param(
    [switch]$Init,
    [string]$Source,
    [string]$Insert,
    [string[]]$Before
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot/tasklib.ps1"

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

if (-not (Test-Path $TasksPath)) { Fail "tasks.md not found: $TasksPath" }

# -Before T4,T5 / -Before "T4,T5" / pwsh -File 経由の "T4 T5" をすべて受け付ける
$beforeIds = @($Before | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Insert -or $beforeIds.Count -gt 0) {
    if ($Init) { Fail "-Insert cannot be combined with -Init" }
    if (-not $Insert -or $beforeIds.Count -eq 0) {
        Fail "-Insert and -Before must be given together (e.g. -Insert T8 -Before T4)"
    }
}

if ($Init) {
    if (-not $Source) { Fail "--Source is required with --Init" }
    if (Test-Path $StatePath) {
        Fail "state.json already exists: $StatePath (use normal sync mode to append, not --Init)"
    }
} elseif (-not (Test-Path $StatePath)) {
    Fail "state.json not found: $StatePath (run with --Init first)"
}

$content = [System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8)
$lines = @(Split-TaskLines $content)
$tasks = @(Read-TaskList $lines)
if ($tasks.Count -eq 0) { Fail "No task headings found in $TasksPath" }
$byId = @{}
foreach ($t in $tasks) { $byId[$t.id] = $t }

$existing = $null
$existingStatus = [ordered]@{}
if (-not $Init) {
    $existing = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in $existing.tasks) { $existingStatus[$t.id] = $t.status }
}

# --- 挿入: 後続タスクの依存欄に新タスクを追加する(書き込みは検証後) ---
$tasksChanged = $false
if ($Insert) {
    if (-not $byId.ContainsKey($Insert)) {
        Fail "Task to insert '$Insert' not found in tasks.md (append its section first)"
    }
    if ($existingStatus.Contains($Insert) -and $existingStatus[$Insert] -ne 'pending') {
        Fail "Task to insert '$Insert' already exists in state.json with status '$($existingStatus[$Insert])'"
    }
    $errors = @()
    foreach ($b in $beforeIds) {
        if ($b -eq $Insert) {
            $errors += "-Before must not include the inserted task itself ('$b')"
        } elseif (-not $existingStatus.Contains($b)) {
            $errors += "-Before task '$b' not found in state.json"
        } elseif ($existingStatus[$b] -ne 'pending') {
            $errors += "-Before task '$b' is '$($existingStatus[$b])' (only pending tasks can be rewritten)"
        } elseif (-not $byId.ContainsKey($b)) {
            $errors += "-Before task '$b' not found in tasks.md"
        }
    }
    if ($errors.Count -gt 0) { Fail ($errors -join "`n") }
    foreach ($b in $beforeIds) {
        try { $deps = @(Get-TaskDeps $byId[$b]) } catch { Fail $_.Exception.Message }
        if ($deps -notcontains $Insert) { $deps += $Insert }
        Set-TaskDepLine $lines $byId[$b] $deps
    }
    $content = $lines -join ''
    $tasks = @(Read-TaskList $lines)
    $tasksChanged = $true
}

# --- 依存欄の検証(全モード共通。state.json を書く前に失敗させる) ---
try {
    [void](Resolve-TaskDeps $tasks -CheckCycles)
} catch {
    Fail $_.Exception.Message
}

$nowIso = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

function New-TaskEntry {
    param($Task)
    return [ordered]@{ id = $Task.id; title = $Task.title; status = 'pending'; retries = 0; commit = $null }
}

if ($Init) {
    $branch = (git branch --show-current).Trim()
    $state = [ordered]@{
        source     = $Source
        branch     = $branch
        updated_at = $nowIso
        tasks      = @($tasks | ForEach-Object { New-TaskEntry $_ })
    }
} else {
    $out = @()
    foreach ($t in $existing.tasks) {
        $out += [ordered]@{ id = $t.id; title = $t.title; status = $t.status; retries = $t.retries; commit = $t.commit }
    }
    foreach ($t in $tasks) {
        if (-not $existingStatus.Contains($t.id)) { $out += New-TaskEntry $t }
    }
    foreach ($id in $existingStatus.Keys) {
        if (-not $byId.ContainsKey($id)) {
            Write-Warning "state.json has task '$id' not present in tasks.md (not removed)"
        }
    }
    $state = [ordered]@{
        source     = $existing.source
        branch     = $existing.branch
        updated_at = $nowIso
        tasks      = $out
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
if ($tasksChanged) {
    [System.IO.File]::WriteAllText($TasksPath, $content, $utf8NoBom)
    Write-Output "Inserted $Insert before $($beforeIds -join ',') (dependency lines updated in tasks.md)"
}

$json = $state | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($StatePath, $json + "`n", $utf8NoBom)
Write-Output "Synced: $StatePath"
exit 0
