# 要件ごとの充足状況(対応タスクの状態)の一覧を tasks.md と state.json から機械生成する(読み取り専用)。
# 引数は取らない。
# stdout: 要件ごとに "Requirement R1 [done|partial|pending]: T1(done abc1234), T2(pending) | <要件の本文>"、
#       要件欄が 'なし' のタスクがあれば "Requirement なし: ..."、最後に "Summary: done=<n> partial=<n> pending=<n>"。
#       要件の節も欄も無ければ "No requirements section"
# exit: 0=出力あり / 1=使い方・tasks.md/state.json 不備
if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('Usage: req-status.ps1')
    exit 1
}
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
$tasks = @(Read-TaskList $lines)
$state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
try {
    $out = @(Get-RequirementStatusLines $tasks $lines @($state.tasks))
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
if ($out.Count -eq 0) { Write-Output 'No requirements section' }
foreach ($l in $out) { Write-Output $l }
exit 0
