# 全テスト(tests/test-*.ps1)を名前順に直列実行する。
# 各ファイルの結果(PASS / FAIL と所要秒数)を 1 行ずつ出し、最後に失敗したファイルの一覧を出す。
# 1 本でも失敗すれば exit 1、すべて成功なら exit 0。
# (syntax-check.ps1 は品質ゲートとして別に実行するため、ここには含めない)
$ErrorActionPreference = "Continue"
Set-Location (Resolve-Path "$PSScriptRoot/..")
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$total = 0
$failed = 0
$failedFiles = @()
foreach ($f in Get-ChildItem "tests/test-*.ps1" | Sort-Object Name) {
    $total++
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & pwsh -NoProfile -File $f.FullName
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, [MidpointRounding]::AwayFromZero)
    if ($LASTEXITCODE -eq 0) {
        Write-Host "PASS: tests/$($f.Name) (${secs}s)"
    } else {
        $failed++
        $failedFiles += "tests/$($f.Name)"
        Write-Host "FAIL: tests/$($f.Name) (${secs}s)"
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "FAILED: $failed/$total"
    foreach ($file in $failedFiles) {
        Write-Host "  $file"
    }
    exit 1
}
Write-Host "ALL PASSED: $total files"
exit 0
