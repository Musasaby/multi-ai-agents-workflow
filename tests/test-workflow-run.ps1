# T16: workflow-run.ps1(前提の確認・ロック・記録・タスクの起動と完了待ち, PowerShell版)
. "$PSScriptRoot/lib.ps1"
. "$PSScriptRoot/workflow-run-lib.ps1"

Write-Host "test-workflow-run.ps1"

Invoke-TestCase "run: 使える条件を満たさなければ runner-unsupported(exit 4)" {
    Initialize-Runner
    Set-BreakPrecondition 0
    Invoke-Script workflow-run.ps1
    Assert-Eq 4 $script:Code "review.mode が無ければ exit 4: $($script:Err)"
    Assert-Contains $script:Err "review.mode" "stderr に理由"
    Assert-Eq "Next: escalate reason=runner-unsupported" (Get-LastLine $script:Out) "最後の行"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/workflow-run/lock" "ロックを取らない"

    Set-BreakPrecondition 1
    Invoke-Script workflow-run.ps1
    Assert-Eq 4 $script:Code "max_parallel が 1 なら exit 4: $($script:Err)"
    Assert-Contains $script:Err "max_parallel" "stderr に理由"
    Assert-Eq "Next: escalate reason=runner-unsupported" (Get-LastLine $script:Out) "最後の行"
}

Invoke-TestCase "run: 生きているロックは already-running、死んでいれば引き継ぐ" {
    Initialize-Runner
    $lock = "$script:Proj/.agents/workflow/runs/workflow-run/lock"
    $null = New-Item -ItemType Directory -Force $lock
    Write-Utf8File "$lock/pid" "$PID`n"

    Invoke-Script workflow-run.ps1
    Assert-Eq 5 $script:Code "生きているロックは exit 5: $($script:Err)"
    Assert-Contains $script:Err "already running" "stderr に理由"
    Assert-Eq "Next: escalate reason=already-running" (Get-LastLine $script:Out) "最後の行"

    Write-Utf8File "$lock/pid" "999999`n"
    Set-State 'T1:done' 'T2:done'
    Set-StateBranch develop/t
    Invoke-Script workflow-run.ps1
    Assert-Eq 0 $script:Code "死んだロックは引き継ぐ: $($script:Err)"
    Assert-Eq "Next: finish" (Get-LastLine $script:Out) "最後の行"
    Assert-FileAbsent $lock "終了後にロックが消える"
}

Invoke-TestCase "run: 並列に起動し、max-wait で Next: wait を返す" {
    Initialize-Runner
    Set-SlowChild
    Invoke-Script workflow-run.ps1 -MaxWait 1 -Interval 1
    Assert-Eq 2 $script:Code "exit 2: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/done" "子の完了を待たずに max-wait で返る"
    Assert-Contains $script:Out "Started: T1-1" "T1 を起動した"
    Assert-Contains $script:Out "Started: T2-1" "T2 を起動した"
    Assert-Contains $script:Out "In flight: T1-1 running" "実行中を出す"
    Assert-Eq "Next: wait" (Get-LastLine $script:Out) "最後の行"
    $progress = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/workflow-run/progress.log")
    Assert-Contains $progress "Started: T1-1" "progress.log に記録"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/workflow-run/lock" "終了後にロックが消える"

    Write-Utf8File "$script:Proj/.agents/release-child" ''
    # 子(release-child で解放)が終わってから一時ディレクトリを片付ける
    Wait-Done T1-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/done" "T1 の done"
    Wait-Done T2-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T2-1/done" "T2 の done"
}

Invoke-TestCase "run: 実装の run が異常終了したら、その理由で止まる" {
    Initialize-Runner
    Set-ChildBody 'exit 1'
    Invoke-Script workflow-run.ps1 -MaxWait 60 -Interval 1
    Assert-Eq 3 $script:Code "exit 3: $($script:Err)"
    Assert-Contains $script:Out "Stopped: T1 reason=abnormal-exit" "異常終了で止まる"
    Assert-Contains $script:Out "Detail: " "詳細のパスを出す"
    Assert-Eq "Next: escalate reason=abnormal-exit" (Get-LastLine $script:Out) "最後の行"
    $first = Get-Content -LiteralPath "$script:Proj/.agents/workflow/runs/T1-1/done" -TotalCount 1
    Assert-Eq "EXIT:1" "$first" "子が実際に異常終了した"
    Wait-Done T2-1
}

Invoke-TestCase "run: 子が終わると worktree の中でレビューし、verdict を記録する" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:done'
    Set-StateBranch develop/t
    $runs = "$script:Proj/.agents/workflow/runs"
    $implWt = ''
    for ($i = 0; $i -lt 60; $i++) {
        Invoke-Script workflow-run.ps1 -MaxWait 2 -Interval 1
        if (Test-Path "$runs/T1-1/worktree.txt") { $implWt = Get-WorktreePath "$runs/T1-1/worktree.txt" }
        if (Test-Path "$runs/review-T1-1/verdict") { break }
    }
    Assert-FileExists "$runs/T1-1/checked" "実装の run が checked"
    Assert-FileExists "$runs/review-T1-1/worktree.txt" "レビューの worktree.txt"
    Assert-Eq "pass" (Get-FileLine "$runs/review-T1-1/verdict" 1) "verdict の1行目"
    Assert-Eq "feat" (Get-FileLine "$runs/review-T1-1/verdict" 2) "verdict の2行目"
    Assert-Eq "T1 を変える" (Get-FileLine "$runs/review-T1-1/verdict" 3) "verdict の3行目"
    Assert-Eq $true ($implWt -ne '') "実装の worktree のパスを取れた"
    Assert-Eq $implWt (Get-WorktreePath "$runs/review-T1-1/worktree.txt") `
        "レビューは実装と同じ worktree の中で行う"
    $progress = [System.IO.File]::ReadAllText("$runs/workflow-run/progress.log")
    Assert-Contains $progress "Review: T1-1 pass" "progress.log に記録"
}

Invoke-TestCase "run: レビューの完了報告が無効なら review-invalid で止まる" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:done'
    Set-StateBranch develop/t
    Set-ReviewBody ':'        # 何も出力しないレビュー役
    $runs = "$script:Proj/.agents/workflow/runs"
    for ($i = 0; $i -lt 60; $i++) {
        Invoke-Script workflow-run.ps1 -MaxWait 2 -Interval 1
        if ($script:Code -eq 3) { break }
    }
    Assert-Eq 3 $script:Code "exit 3: $($script:Err)"
    Assert-Contains $script:Out "Stopped: T1 reason=review-invalid" "無効な完了報告で止まる"
    Assert-Eq "Next: escalate reason=review-invalid" (Get-LastLine $script:Out) "最後の行"
    Assert-Eq "in_progress" (Get-StateTask T1).status "T1 の状態は in_progress のまま"
}

Invoke-TestCase "run: 全タスク done なら Next: finish" {
    Initialize-Runner
    Set-State 'T1:done' 'T2:done'
    Set-StateBranch develop/t
    Invoke-Script workflow-run.ps1
    Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
    Assert-Eq "Next: finish" (Get-LastLine $script:Out) "最後の行"
}

Invoke-TestCase "run: 合格した run を collect してコミットし、Done 行を出す" {
    Initialize-Runner
    Set-State 'T1:pending' 'T2:pending'
    Set-StateBranch develop/t
    Invoke-UntilNotWait
    $runs = "$script:Proj/.agents/workflow/runs"
    Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
    Assert-Eq "Next: finish" (Get-LastLine $script:Out) "最後の行"
    Assert-Eq "done" (Get-StateTask T1).status "T1 の状態"
    Assert-Eq "done" (Get-StateTask T2).status "T2 の状態"
    $subjects = (Invoke-Git log --format=%s) -join "`n"
    Assert-Contains $subjects "feat: T1 を変える" "レビュー役の type と要約で T1 をコミット"
    Assert-Contains $subjects "feat: T2 を変える" "レビュー役の type と要約で T2 をコミット"
    $progress = [System.IO.File]::ReadAllText("$runs/workflow-run/progress.log")
    Assert-Contains $progress "Done: T1 " "progress.log に Done を記録"
    Assert-Contains $progress "retries=0" "progress.log に retries を記録"
    Assert-FileAbsent "$runs/T1-1/worktree" "collect 後に T1 の worktree が消える"
}

Invoke-TestCase "run: グループの最後で Next: group-advance を返す" {
    Initialize-Runner
    Set-Tasks @'
# タスク一覧: test

<!-- グループ g1 -->

## T1: 一番目
- **目的**: a
- **対象**: T1.txt を直す
- **参照ファイル**:
  - `T1.txt`(変更対象)
- **依存**: なし

<!-- グループ g2 -->

## T2: 二番目
- **目的**: b
- **対象**: T2.txt を直す
- **参照ファイル**:
  - `T2.txt`(変更対象)
- **依存**: なし
'@
    Set-State 'T1:pending' 'T2:pending'
    Set-StateBranch develop/t
    Set-StateGroup g1
    Invoke-UntilNotWait
    Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
    Assert-Eq "Next: group-advance" (Get-LastLine $script:Out) "最後の行"
    Assert-Eq "done" (Get-StateTask T1).status "T1 の状態"
    Assert-Eq "pending" (Get-StateTask T2).status "T2 の状態"
}

Show-Summary
