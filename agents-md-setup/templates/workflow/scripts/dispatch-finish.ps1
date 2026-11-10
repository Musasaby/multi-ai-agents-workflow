# サブエージェントの run(runs/<ID>-<N>/launcher が subagent)を完了させる。
# 親がサブエージェントの最終応答を output.log に書いた後に呼ぶ。done が無ければ dispatch-run と
# 同じ形式(EXIT:<値> / END:<ISO 8601>)で書き、dispatch-check の結果をそのまま返す。
# done が既にあれば上書きしない。
# Usage: dispatch-finish.ps1 -TaskId <ID> -Attempt <N> [-Exit <値>]
#   -Exit の既定は 0
# exit: 1 = 使い方不備・launcher が subagent でない・output.log が無い
#       それ以外 = dispatch-check.ps1 の exit code をそのまま(stdout・stderr もそのまま)
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [int]$Exit = 0
)
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1 -or $Exit -lt 0) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt/-Exit: '$TaskId' '$Attempt' '$Exit'")
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$runDir = ".agents/workflow/runs/$TaskId-$Attempt"
$donePath = "$runDir/done"
$logPath = "$runDir/output.log"
$launcherPath = "$runDir/launcher"

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or
    ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $launcherPath)).Trim() -ne 'subagent')) {
    [Console]::Error.WriteLine("not a subagent run: $runDir (launcher is not subagent)")
    exit 1
}
if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    [Console]::Error.WriteLine("output.log not found: $logPath (write the subagent's final response to it)")
    exit 1
}

if (-not (Test-Path -LiteralPath $donePath -PathType Leaf)) {
    $endTime = (Get-Date).ToString("o")
    "EXIT:$Exit`nEND:$endTime" | Out-File -Encoding utf8 $donePath
}

& pwsh -NoProfile -File "$PSScriptRoot/dispatch-check.ps1" -TaskId $TaskId -Attempt $Attempt
exit $LASTEXITCODE
