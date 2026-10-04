# #27: task-state(state.json の状態遷移, PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Assert-Ok {
    param([string]$Want, [string[]]$ScriptArgs)
    Invoke-Script task-state.ps1 @ScriptArgs
    Assert-Eq 0 $script:Code "task-state $ScriptArgs exit: $($script:Err)"
    Assert-Eq $Want (Get-StateTask T1).status "task-state $ScriptArgs status"
}

function Assert-Reject {
    param([int]$Want, [string[]]$ScriptArgs)
    $before = Get-StateText
    Invoke-Script task-state.ps1 @ScriptArgs
    Assert-Eq $Want $script:Code "task-state $ScriptArgs rejected"
    Assert-Eq $before (Get-StateText) "task-state $ScriptArgs leaves state.json unchanged"
}

Write-Host "test-task-state.ps1"

Invoke-TestCase "start" {
    Set-State 'T1:pending'
    Assert-Ok in_progress @('T1', 'start')
    Assert-NotContains (Get-StateText) '2026-01-01T00:00:00+09:00' "updated_at refreshed"
    Assert-Ok in_progress @('T1', 'start')
}

Invoke-TestCase "start: done からは拒否" {
    Set-State 'T1:done'
    Assert-Reject 1 @('T1', 'start')
}

Invoke-TestCase "review" {
    Set-State 'T1:in_progress'
    Assert-Ok in_review @('T1', 'review')
    Set-State 'T1:pending'
    Assert-Reject 1 @('T1', 'review')
}

Invoke-TestCase "done: -Commit 必須" {
    Set-State 'T1:in_review'
    Assert-Reject 1 @('T1', 'done')
    Assert-Reject 1 @('T1', 'done', '-Commit', 'not-a-hash')
    Assert-Ok done @('T1', 'done', '-Commit', 'abc1234')
    Assert-Eq abc1234 (Get-StateTask T1).commit "commit recorded"
    Set-State 'T1:in_progress'
    Assert-Reject 1 @('T1', 'done', '-Commit', 'abc1234')
}

Invoke-TestCase "retry" {
    Set-State 'T1:in_review:1'
    Assert-Ok in_progress @('T1', 'retry')
    Assert-Eq 2 (Get-StateTask T1).retries "retries incremented"
}

Invoke-TestCase "retry: 上限超過は exit 4" {
    Set-State 'T1:in_review:2'
    Assert-Reject 4 @('T1', 'retry')
}

Invoke-TestCase "fail / reset" {
    Set-State 'T1:pending'
    Assert-Reject 1 @('T1', 'fail')
    Set-State 'T1:in_progress:2'
    Assert-Ok failed @('T1', 'fail')
    Assert-Ok pending @('T1', 'reset')
    Assert-Eq 0 (Get-StateTask T1).retries "reset clears retries"
    Set-State 'T1:in_progress'
    Assert-Reject 1 @('T1', 'reset')
}

Invoke-TestCase "不正な引数" {
    Set-State 'T1:pending'
    Assert-Reject 1 @('T9', 'start')
    Assert-Reject 1 @('T1', 'explode')
    Assert-Reject 1 @('../x', 'start')
}

Invoke-TestCase "他のタスクは変えない" {
    Set-State 'T1:pending' 'T2:in_review:1'
    Invoke-Script task-state.ps1 T1 start
    Assert-Eq in_review (Get-StateTask T2).status "T2 status kept"
    Assert-Eq 1 (Get-StateTask T2).retries "T2 retries kept"
}

Invoke-TestCase "未知のフィールドを保持" {
    Write-Utf8File "$script:Proj/.agents/workflow/state.json" '{"source":"s","branch":"b","updated_at":"x","extra":1,"tasks":[{"id":"T1","title":"t","status":"pending","retries":0,"commit":null,"note":"keep"}]}'
    Invoke-Script task-state.ps1 T1 start
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq 'keep' (Get-StateTask T1).note "unknown task field kept"
    Assert-Eq 1 (ConvertFrom-Json (Get-StateText)).extra "unknown top-level field kept"
    Assert-Eq 'in_progress' (Get-StateTask T1).status "status updated"
}

Invoke-TestCase "コミットハッシュを小文字に正規化" {
    Set-State 'T1:in_review'
    Invoke-Script task-state.ps1 T1 done -Commit ABC1234
    Assert-Eq abc1234 (Get-StateTask T1).commit "commit hash normalized to lowercase"
}

Invoke-TestCase "動作名は大文字小文字を区別" {
    Set-State 'T1:pending'
    Assert-Reject 1 @('T1', 'START')
}

Show-Summary
