param(
    [Parameter(Position = 0)]
    [string]$Slug
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $Slug) {
    Write-Error "使い方: workflow-archive.ps1 <スラッグ>"
    exit 1
}

if ($Slug -match '[\\/]' -or $Slug -match '\.\.') {
    Write-Error "スラッグにパス区切りや '..' を含めることはできません: $Slug"
    exit 1
}

$Root = Get-Location
$WorkflowDir = "$Root/.agents/workflow"

if (-not (Test-Path $WorkflowDir)) {
    Write-Error "workflow ディレクトリが見つかりません: $WorkflowDir"
    exit 1
}

$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$ArchiveDir = "$WorkflowDir/archive/$Timestamp-$Slug"

$Targets = @('tasks.md', 'state.json', 'runs', 'comprehension')
$Existing = @()
foreach ($name in $Targets) {
    $path = "$WorkflowDir/$name"
    if (Test-Path $path) {
        $Existing += $name
    }
}

if ($Existing.Count -eq 0) {
    Write-Error "移動対象がありません(tasks.md / state.json / runs/ / comprehension/ のいずれも存在しません)"
    exit 1
}

New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null

foreach ($name in $Existing) {
    Move-Item -Path "$WorkflowDir/$name" -Destination "$ArchiveDir/$name"
}

Write-Output "Archived: $ArchiveDir ($($Existing -join ', '))"
