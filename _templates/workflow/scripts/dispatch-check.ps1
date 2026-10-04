# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# exit: 0=正常終了かつ完了報告あり / 1=done マーカーが無い・使い方不備
#       4=異常終了(非0・signal・crashed) / 5=EXIT:0 だが完了報告が無い
# Windows にはシグナルの仕組みが無いため、dispatch-run.ps1 は signal:* を書き出さない
# (強制終了は通常の非0終了として記録される)。POSIX 版が書き出した done も同じ規則で判定する。
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$tailLines = 30
$runDir = ".agents/workflow/runs/$TaskId-$Attempt"
$donePath = "$runDir/done"
$logPath = "$runDir/output.log"

if (-not (Test-Path $donePath)) {
    [Console]::Error.WriteLine("done marker not found: $donePath (child agent has not finished yet)")
    exit 1
}

# ReadAllText は BOM を除去する(Windows PowerShell 5.1 の Out-File は BOM を付ける)
$doneLines = [System.IO.File]::ReadAllText((Resolve-Path $donePath), [System.Text.Encoding]::UTF8) -split "`r?`n"
$exitValue = ''
$endValue = ''
foreach ($line in $doneLines) {
    if (-not $exitValue -and $line.StartsWith('EXIT:')) { $exitValue = $line.Substring(5) }
    if (-not $endValue -and $line.StartsWith('END:')) { $endValue = $line.Substring(4) }
}

$kind = switch -Regex ($exitValue) {
    '^0$' { 'ok'; break }
    '^signal:' { 'signal'; break }
    '^crashed:' { 'crashed'; break }
    '^$' { 'unknown'; break }
    default { 'nonzero' }
}

$report = 'missing'
if ((Test-Path $logPath) -and (Select-String -Path $logPath -Pattern '^## 完了報告' -Encoding utf8 -Quiet)) {
    $report = 'found'
}

if ($kind -ne 'ok') {
    $verdict = 'abnormal-exit'; $code = 4
} elseif ($report -ne 'found') {
    $verdict = 'no-report'; $code = 5
} else {
    $verdict = 'ok'; $code = 0
}

Write-Output "Run: $TaskId-$Attempt"
Write-Output "Exit: $exitValue (kind: $kind)"
Write-Output "End: $endValue"
Write-Output "Completion report: $report"
Write-Output "Verdict: $verdict"
Write-Output "--- git status --porcelain"
git status --porcelain
Write-Output "--- git diff --stat"
git diff --stat
Write-Output "--- output.log (last $tailLines lines)"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail $tailLines -Encoding utf8
} else {
    Write-Output "(output.log not found)"
}

exit $code
