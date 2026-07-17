param(
    [switch]$Init,
    [string]$Source
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"

if (-not (Test-Path $TasksPath)) {
    Write-Error "tasks.md not found: $TasksPath"
    exit 1
}

$tasksInFile = [ordered]@{}
foreach ($line in (Get-Content $TasksPath -Raw -Encoding UTF8 -ErrorAction Stop) -split "`n") {
    if ($line -match '^## (T\d+):\s*(.+)') {
        $id = $Matches[1]
        $title = $Matches[2].Trim()
        $tasksInFile[$id] = $title
    }
}

if ($tasksInFile.Count -eq 0) {
    Write-Error "No task headings found in $TasksPath"
    exit 1
}

$nowIso = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

if ($Init) {
    if (-not $Source) {
        Write-Error "--Source is required with --Init"
        exit 1
    }
    if (Test-Path $StatePath) {
        Write-Error "state.json already exists: $StatePath (use normal sync mode to append, not --Init)"
        exit 1
    }
    $branch = (git branch --show-current).Trim()

    $tasks = @()
    foreach ($id in $tasksInFile.Keys) {
        $tasks += [ordered]@{
            id      = $id
            title   = $tasksInFile[$id]
            status  = 'pending'
            retries = 0
            commit  = $null
        }
    }

    $state = [ordered]@{
        source     = $Source
        branch     = $branch
        updated_at = $nowIso
        tasks      = $tasks
    }
} else {
    if (-not (Test-Path $StatePath)) {
        Write-Error "state.json not found: $StatePath (run with --Init first)"
        exit 1
    }
    $existing = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $existingIds = @{}
    foreach ($t in $existing.tasks) { $existingIds[$t.id] = $true }

    $tasks = @()
    foreach ($t in $existing.tasks) {
        $tasks += [ordered]@{
            id      = $t.id
            title   = $t.title
            status  = $t.status
            retries = $t.retries
            commit  = $t.commit
        }
    }

    foreach ($id in $tasksInFile.Keys) {
        if (-not $existingIds.ContainsKey($id)) {
            $tasks += [ordered]@{
                id      = $id
                title   = $tasksInFile[$id]
                status  = 'pending'
                retries = 0
                commit  = $null
            }
        }
    }

    foreach ($id in $existingIds.Keys) {
        if (-not $tasksInFile.Contains($id)) {
            Write-Warning "state.json has task '$id' not present in tasks.md (not removed)"
        }
    }

    $state = [ordered]@{
        source     = $existing.source
        branch     = $existing.branch
        updated_at = $nowIso
        tasks      = $tasks
    }
}

$json = $state | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($StatePath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output "Synced: $StatePath"
