# workflow-run.ps1 の collect 後に止まる場合と再 dispatch(PowerShell版)
. "$PSScriptRoot/lib.ps1"
. "$PSScriptRoot/workflow-run-lib.ps1"

Write-Host "test-workflow-run-retry.ps1"

Invoke-TestCase "run: type が無効なら commit-format で止まり、in_review のまま残る" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:done'
    Set-StateBranch develop/t
    Set-ReviewBody @'
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
id="${id#review-}"
echo "## 完了報告"
echo "- Verdict: pass"
echo "- 指摘: 0件(なし)"
echo "- 要約: $id を変える"
echo "- type: bogus"
echo "- fix-notes: なし"
echo "- 理解確認: なし"
'@
    Invoke-UntilNotWait
    $runs = "$script:Proj/.agents/workflow/runs"
    Assert-Eq 3 $script:Code "exit 3: $($script:Err)"
    Assert-Contains $script:Out "Stopped: T1 reason=commit-format" "commit-format で止まる"
    Assert-Eq "Next: escalate reason=commit-format" (Get-LastLine $script:Out) "最後の行"
    Assert-Eq "in_review" (Get-StateTask T1).status "T1 の状態は in_review のまま"
    Assert-FileExists "$runs/T1-1/collected" "collect 済み"
}

Invoke-TestCase "run: レビュー不合格なら変更を持ち越して再 dispatch する" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:done'
    Set-StateBranch develop/t
    Write-Utf8File "$script:Proj/.agents/review-fail-T1" ''
    Invoke-UntilNotWait
    $runs = "$script:Proj/.agents/workflow/runs"
    Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
    Assert-Eq "done" (Get-StateTask T1).status "T1 の状態"
    Assert-Eq "1" (Get-StateTask T1).retries "T1 の retries"
    Assert-FileExists "$runs/T1-1/carry" "前の試行の変更を持ち越す"
    Assert-FileExists "$runs/T1-1/superseded" "前の試行を superseded にする"
    $lines = @([System.IO.File]::ReadAllText("$script:Proj/T1.txt", [System.Text.Encoding]::UTF8) -split "`n" |
        Where-Object { $_ -eq 'line' })
    Assert-Eq 2 $lines.Count "試行1と試行2の変更が両方ある"
    $progress = [System.IO.File]::ReadAllText("$runs/workflow-run/progress.log")
    Assert-Contains $progress "Retry: T1 1/2 (review)" "progress.log に Retry"
}

Invoke-TestCase "run: 品質ゲートが FAIL なら fix-notes.md を機械的に書いて再 dispatch する" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:done'
    Set-StateBranch develop/t
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg.verify_before_commit = $true
    $cfg | Add-Member -NotePropertyName quality_gate -NotePropertyValue ([pscustomobject]@{
        steps = @([pscustomobject]@{
            name = 'check'
            command = 'if (Test-Path .agents/gate-fail-once) { Remove-Item .agents/gate-fail-once; exit 1 }'
            blocking = $true
        })
    }) -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/gate-fail-once" ''
    Invoke-UntilNotWait
    $runs = "$script:Proj/.agents/workflow/runs"
    Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
    Assert-Eq "done" (Get-StateTask T1).status "T1 の状態"
    Assert-Eq "1" (Get-StateTask T1).retries "T1 の retries"
    Assert-FileExists "$runs/T1-2/fix-notes.md" "次の試行の fix-notes.md"
    $notes = [System.IO.File]::ReadAllText("$runs/T1-2/fix-notes.md", [System.Text.Encoding]::UTF8)
    Assert-Contains $notes "品質ゲート FAIL" "原因種別"
    Assert-Contains $notes "FAIL check (blocking)" "品質ゲートの出力"
}

Invoke-TestCase "run: リトライの上限でレビュー不合格なら collect して retry-limit で止まる" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:done'
    Set-StateBranch develop/t
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName max_fix_retries -NotePropertyValue 0 -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/review-fail-T1" ''
    Invoke-UntilNotWait
    $runs = "$script:Proj/.agents/workflow/runs"
    Assert-Eq 3 $script:Code "exit 3: $($script:Err)"
    Assert-Eq "Next: escalate reason=retry-limit" (Get-LastLine $script:Out) "最後の行"
    Assert-Eq "in_review" (Get-StateTask T1).status "T1 の状態"
    Assert-FileExists "$runs/T1-1/collected" "collect 済み"
}

Invoke-TestCase "run: collect が衝突したら最新の HEAD からやり直す" {
    Initialize-Runner
    Set-State 'T1:in_progress' 'T2:done'
    Set-StateBranch develop/t
    Invoke-Script dispatch-worktree.ps1 create T1 1
    $runs = "$script:Proj/.agents/workflow/runs"
    $wt = Get-WorktreePath "$runs/T1-1/worktree.txt"
    Write-Utf8File "$wt/T1.txt" "worktree-change`n"
    Write-Utf8File "$script:Proj/T1.txt" "main-change`n"
    Invoke-Git add T1.txt
    Invoke-Git commit -q -m "main change"
    Write-Utf8File "$runs/T1-1/guard.sha256" ''
    Write-Utf8File "$runs/T1-1/checked" ''
    $null = New-Item -ItemType Directory -Force "$runs/review-T1-1"
    Write-Utf8File "$runs/review-T1-1/guard.sha256" ''
    Write-Utf8File "$runs/review-T1-1/verdict" "pass`nfeat`nT1 を変える`n"
    Invoke-Script workflow-run.ps1 -MaxWait 1 -Interval 1
    Assert-Contains $script:Out "Redo: T1-2 (conflict)" "Redo を出す"
    Assert-Contains $script:Out "Started: T1-2" "次の試行を起動した"
    Assert-FileExists "$runs/T1-2/fix-notes.md" "次の試行の fix-notes.md"
    $notes = [System.IO.File]::ReadAllText("$runs/T1-2/fix-notes.md", [System.Text.Encoding]::UTF8)
    Assert-Contains $notes "changes.patch" "changes.patch のパスを案内"
    Assert-FileExists "$runs/T1-1/superseded" "前の試行を superseded にする"
    Assert-FileAbsent "$runs/T1-1/carry" "衝突のやり直しでは carry を書かない"

    Wait-Done T1-2
    Assert-FileExists "$runs/T1-2/done" "T1-2 の done"
}

Show-Summary
