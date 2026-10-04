# #16: dispatch-run の done マーカーと dispatch-check(PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Set-Child {
    param([string]$Body)
    Write-Utf8File "$script:Proj/child.ps1" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'pwsh -NoProfile -File ./child.ps1 "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt`n"
}

function Get-DoneExit { return (Get-Content "$script:Proj/.agents/workflow/runs/T1-1/done" -Encoding utf8)[0] }

function New-Run {
    param([string]$Exit, [string]$Log)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/done" "EXIT:$Exit`nEND:2026-01-01T00:00:00+09:00`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" "$Log`n"
}

$report = "作業しました`n## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス"

Write-Host "test-dispatch.ps1"

Invoke-TestCase "run: 正常終了はEXIT:0" {
    Set-Child 'Write-Output hello; exit 0'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:0" (Get-DoneExit) "done marker"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log")) "hello" "output.log"
}

Invoke-TestCase "run: 非0は数値のまま" {
    Set-Child 'exit 3'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:3" (Get-DoneExit) "done marker"
}

Invoke-TestCase "check: 正常" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "kind: ok" "kind"
    Assert-Contains $script:Out "a.txt" "git status shown"
    Assert-Contains $script:Out "Completion report: found" "report found"
}

Invoke-TestCase "check: signalはexit 4" {
    New-Run "signal:15" "step 67 ..."
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: signal" "kind"
    Assert-Contains $script:Out "step 67" "log tail shown"
}

Invoke-TestCase "check: 非0はexit 4" {
    New-Run 3 $report
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: nonzero" "kind"
}

Invoke-TestCase "check: crashedはexit 4" {
    New-Run "crashed:boom" ""
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: crashed" "kind"
}

Invoke-TestCase "check: 完了報告なしはexit 5" {
    New-Run 0 "did something but no report"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code"
    Assert-Contains $script:Out "Completion report: missing" "report missing"
}

Invoke-TestCase "check: doneなしはexit 1" {
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/runs/T1-1"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "check: BOM付きdone" {
    New-Run 0 $report
    [System.IO.File]::WriteAllText("$script:Proj/.agents/workflow/runs/T1-1/done", "EXIT:0`r`nEND:x`r`n", [System.Text.UTF8Encoding]::new($true))
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "BOM-prefixed done marker parsed: $($script:Out)"
}

Show-Summary
