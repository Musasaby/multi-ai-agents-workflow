# #59: quality-gate(config の quality_gate.steps の実行と判定, PowerShell版)。
. "$PSScriptRoot/lib.ps1"

# Set-Steps @(@('name','command',$true), ...) → config.json の quality_gate.steps を書き換える
function Set-Steps {
    param([object[]]$Specs)
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $steps = @(foreach ($s in $Specs) { [ordered]@{ name = $s[0]; command = $s[1]; blocking = [bool]$s[2] } })
    $cfg.quality_gate.steps = $steps
    Write-Utf8File $path (($cfg | ConvertTo-Json -Depth 10) + "`n")
}

Write-Host "test-quality-gate.ps1"

Invoke-TestCase "gate: blocking がすべて成功すれば PASS" {
    Set-Steps @(, @('a', 'echo ok', $true))
    Invoke-Script quality-gate.ps1 -OutDir out
    Assert-Eq 0 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "Result: PASS" "Result"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/out/a.log")) "ok" "a.log"
    Assert-Eq "Next: continue" ($script:Out -split "`n")[-1] "last line is the Next: line"
}

Invoke-TestCase "gate: blocking の失敗は FAIL(exit 2)で後続も実行する" {
    Set-Steps @(@('a', 'exit 1', $true), @('b', 'echo b', $true))
    Invoke-Script quality-gate.ps1 -OutDir out
    Assert-Eq 2 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "FAIL a" "a failed"
    Assert-Contains $script:Out "PASS b" "b still ran"
    Assert-Eq "Next: escalate reason=quality-gate" ($script:Out -split "`n")[-1] "last line is the Next: line"
}

Invoke-TestCase "gate: non-blocking の失敗は PASS" {
    Set-Steps @(@('a', 'echo ok', $true), @('b', 'exit 1', $false))
    Invoke-Script quality-gate.ps1 -OutDir out
    Assert-Eq 0 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "FAIL b" "b failed"
    Assert-Contains $script:Out "Result: PASS" "Result"
}

Invoke-TestCase "gate: 実行ステップが0件なら exit 3" {
    Invoke-Script quality-gate.ps1 -OutDir out
    Assert-Eq 3 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "Result: NO-STEPS" "Result"
    Assert-Eq "Next: escalate reason=no-steps" ($script:Out -split "`n")[-1] "last line is the Next: line"
}

Invoke-TestCase "gate: stdout には失敗ステップの末尾だけを出す" {
    Set-Steps @(, @('a', '1..100 | ForEach-Object { $_ }; exit 1', $true))
    Invoke-Script quality-gate.ps1 -OutDir out
    Assert-Eq 2 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "100" "last line shown"
    $after = $script:Out.Substring($script:Out.IndexOf('--- a'))
    Assert-NotContains ("`n" + $after + "`n") "`n1`n" "first line not shown"
    Assert-Eq 100 (@([System.IO.File]::ReadAllLines("$script:Proj/out/a.log")).Count) "a.log has 100 lines"
}

Invoke-TestCase "gate: ステップが stdin を読んでも後続のステップを実行する" {
    Set-Steps @(@('a', '[Console]::In.ReadToEnd() | Out-Null', $true), @('b', 'echo b', $true))
    Invoke-Script quality-gate.ps1 -OutDir out
    Assert-Eq 0 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "PASS a" "a passed"
    Assert-Contains $script:Out "PASS b" "b still ran"
}

Show-Summary
