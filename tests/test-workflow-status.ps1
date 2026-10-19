# workflow-status(進捗と次の操作の表示, 通常モード, PowerShell版)
# gh は lib.ps1 が PATH 先頭に置くスタブで差し替える
. "$PSScriptRoot/lib.ps1"

function Get-LastLine { param([string]$Text) return (($Text -split "`n") | ForEach-Object { $_.TrimEnd("`r") } | Select-Object -Last 1) }

Write-Host "test-workflow-status.ps1"

Invoke-TestCase "workflow-status: 進捗・作業グループ・次のタスクを出す" {
    Set-Tasks @'
<!-- グループ G1 -->

## T1: T1 title
- **目的**: a
- **依存**: なし

<!-- グループ G2 -->

## T2: T2 title
- **目的**: b
- **依存**: T1

## T3: T3 title
- **目的**: c
- **依存**: T2
'@
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Set-StateGroup 'G2'
    Invoke-Script workflow-status.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Out "Progress: 1/3 done" "進捗"
    Assert-Contains $script:Out "Group: G2 0/2" "作業グループ"
    Assert-Contains $script:Out "Current: none" "実行中なし"
    Assert-Contains $script:Out "Comprehension: unanswered=0" "理解確認"
    Assert-Eq "Next: dispatch T2" (Get-LastLine $script:Out) "最後の行"
}

Invoke-TestCase "workflow-status: 実行中の子の経過を出し Next: wait にする" {
    Set-Tasks @'
## T1: T1 title
- **目的**: a
- **依存**: なし
'@
    Set-State 'T1:in_progress'
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" "x`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" "log`n"
    Invoke-Script workflow-status.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Out "Current: T1 in_progress | T1 title" "実行中のタスク"
    Assert-Contains $script:Out "Run: T1-1 running elapsed=" "経過時間"
    Assert-Contains $script:Out "log_idle=" "ログの無更新時間"
    Assert-Eq "Next: wait" (Get-LastLine $script:Out) "最後の行"
}

Invoke-TestCase "workflow-status: 全タスク完了時に PR の状態から次の操作を出す" {
    Set-Tasks @'
## T1: T1 title
- **目的**: a
- **依存**: なし
'@
    Set-State 'T1:done'
    Set-GhStubResult -Code 0 -Stdout '{"state":"OPEN","url":"https://example.com/pr/1"}'
    Invoke-Script workflow-status.ps1
    Assert-Eq 0 $script:Code "exit(OPEN): $($script:Err)"
    Assert-Contains $script:Out "PR: OPEN https://example.com/pr/1" "PR の状態"
    Assert-Eq "Next: wait-merge" (Get-LastLine $script:Out) "OPEN の Next"
    Set-GhStubResult -Code 1 -Stderr 'no pull requests found for branch "main"'
    Invoke-Script workflow-status.ps1
    Assert-Eq 0 $script:Code "exit(none): $($script:Err)"
    Assert-Contains $script:Out "PR: none" "PR なし"
    Assert-Eq "Next: create-pr" (Get-LastLine $script:Out) "PR なしの Next"
}

Invoke-TestCase "workflow-status: 未回答の理解確認ファイルを数える" {
    Set-Tasks @'
## T1: T1 title
- **目的**: a
- **依存**: なし
'@
    Set-State 'T1:pending'
    Write-Utf8File "$script:Proj/.agents/workflow/comprehension/T1.md" "**あなたの回答**: <!-- ここに記入 -->`n"
    Write-Utf8File "$script:Proj/.agents/workflow/comprehension/T2.md" "**あなたの回答**: B`n"
    Invoke-Script workflow-status.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Out "Comprehension: unanswered=1 T1.md" "未回答の数とファイル名"
}

Show-Summary
