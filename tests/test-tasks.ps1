# #13 / #14: 依存欄の検証・タスク挿入・次タスク選択(PowerShell版)
. "$PSScriptRoot/lib.ps1"

$basicTasks = @'
# タスク一覧: test

## T1: 一番目
- **目的**: a
- **依存**: なし

## T2: 二番目
- **目的**: b
- **依存**: T1

## T3: 三番目
- **目的**: c
- **依存**: T1, T2

## T4: 四番目
- **目的**: d
- **依存**: T3
'@

function Add-T8 { param([string]$Dep) Add-Tasks "`n`n## T8: 挿入タスク`n- **目的**: inserted`n- **依存**: $Dep`n" }

Write-Host "test-tasks.ps1"

# ---------- dispatch-prompt-gen: 依存欄の検証 (#14) ----------

Invoke-TestCase "gen: 注記付き依存はexit 1" {
    Set-Tasks "## T30: 基盤`n- **依存**: なし`n`n## T31: 利用側`n- **依存**: T30(Prometheus 基盤。完了済み)`n"
    Set-State 'T30:done' 'T31:pending'
    Set-Report T30 1
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T31
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "T30(Prometheus 基盤。完了済み)" "stderr shows invalid token"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T31-1/prompt.md" "prompt not generated"
}

Invoke-TestCase "gen: 正しい形式は通る" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Set-Report T1 1; Set-Report T2 1
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "なし passes: $($script:Err)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T2
    Assert-Eq 0 $script:Code "single dep passes: $($script:Err)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T3
    Assert-Eq 0 $script:Code "multiple deps pass: $($script:Err)"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T3-1/prompt.md")) "### T2:" "handoff includes T2"
}

Invoke-TestCase "gen: 存在しないIDはexit 1" {
    Set-Tasks "## T1: a`n- **依存**: T99`n"
    Set-State 'T1:pending'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "T99" "stderr names unknown id"
}

Invoke-TestCase "gen: 自己依存はexit 1" {
    Set-Tasks "## T1: a`n- **依存**: T1`n"
    Set-State 'T1:pending'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "gen: 依存行なしはexit 1" {
    Set-Tasks "## T1: a`n- **目的**: x`n"
    Set-State 'T1:pending'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "gen: 引き継ぎガードはexit 2のまま" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending' 'T4:pending'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T2
    Assert-Eq 2 $script:Code "missing report -> exit 2"
}

# ---------- state-sync: 依存欄の検証 (#14) ----------

Invoke-TestCase "sync: init 正常" {
    Set-Tasks $basicTasks
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 0 $script:Code "init succeeds: $($script:Err)"
    Assert-Eq "T1,T2,T3,T4" (Get-StateIds) "ids"
}

Invoke-TestCase "sync: init 注記はexit 1" {
    Set-Tasks "## T1: a`n- **依存**: なし`n`n## T2: b`n- **依存**: T1(完了済み)`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "T1(完了済み)" "stderr shows token"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json not created"
}

Invoke-TestCase "sync: init 依存行なしはexit 1" {
    Set-Tasks "## T1: a`n- **目的**: x`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 1 $script:Code "exit code"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json not created"
}

Invoke-TestCase "sync: init 循環はexit 1" {
    Set-Tasks "## T1: a`n- **依存**: T3`n`n## T2: b`n- **依存**: T1`n`n## T3: c`n- **依存**: T2`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "ycl" "stderr mentions cycle"
}

Invoke-TestCase "sync: 追記 不正ならstate不変" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Add-Tasks "`n## T5: 追加`n- **依存**: T4 (あとで)`n"
    $before = Get-StateText
    Invoke-Script state-sync.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Eq $before (Get-StateText) "state.json unchanged"
}

Invoke-TestCase "sync: 追記 正常" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Add-Tasks "`n## T5: 追加`n- **依存**: T4`n"
    Invoke-Script state-sync.ps1
    Assert-Eq 0 $script:Code "append succeeds: $($script:Err)"
    Assert-Eq "T1,T2,T3,T4,T5" (Get-StateIds) "ids"
    Assert-Eq done (Get-StateTask T1).status "existing status kept"
}

# ---------- state-sync: 挿入 (#13) ----------

Invoke-TestCase "insert: pendingの前に挿入" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:done' 'T4:pending'
    Add-T8 'T3'
    Invoke-Script state-sync.ps1 -Insert T8 -Before T4
    Assert-Eq 0 $script:Code "insert succeeds: $($script:Err)"
    Assert-Contains (Get-TasksText) "- **依存**: T3, T8" "T4 deps updated"
    Assert-Eq "T1,T2,T3,T4,T8" (Get-StateIds) "T8 appended to state"
    Assert-Eq pending (Get-StateTask T8).status "T8 pending"
    Assert-Eq done (Get-StateTask T3).status "T3 kept"
}

Invoke-TestCase "insert: なし→T8、複数指定" {
    Set-Tasks "## T1: a`n- **依存**: なし`n`n## T2: b`n- **依存**: なし`n"
    Set-State 'T1:pending' 'T2:pending'
    Add-T8 'なし'
    Invoke-Script state-sync.ps1 -Insert T8 -Before T1,T2
    Assert-Eq 0 $script:Code "insert succeeds: $($script:Err)"
    Assert-Eq 2 ([regex]::Matches((Get-TasksText), '(?m)^- \*\*依存\*\*: T8$').Count) "both deps become T8"
}

Invoke-TestCase "insert: pending以外は拒否" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:in_progress' 'T4:pending'
    Add-T8 'T2'
    $beforeTasks = Get-TasksText; $beforeState = Get-StateText
    Invoke-Script state-sync.ps1 -Insert T8 -Before T3
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "T3" "stderr names T3"
    Assert-Eq $beforeTasks (Get-TasksText) "tasks.md unchanged"
    Assert-Eq $beforeState (Get-StateText) "state.json unchanged"
}

Invoke-TestCase "insert: 循環は拒否" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:done' 'T4:pending'
    Add-T8 'T4'
    $beforeTasks = Get-TasksText
    Invoke-Script state-sync.ps1 -Insert T8 -Before T4
    Assert-Eq 1 $script:Code "exit code"
    Assert-Eq $beforeTasks (Get-TasksText) "tasks.md unchanged"
}

Invoke-TestCase "insert: -Before必須" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:done' 'T4:pending'
    Add-T8 'T3'
    Invoke-Script state-sync.ps1 -Insert T8
    Assert-Eq 1 $script:Code "-Insert without -Before"
}

Invoke-TestCase "insert: CRLF保持" {
    Write-Utf8File "$script:Proj/.agents/workflow/tasks.md" "## T1: a`r`n- **依存**: なし`r`n`r`n## T2: b`r`n- **依存**: T1`r`n`r`n## T8: c`r`n- **依存**: T1`r`n"
    Set-State 'T1:done' 'T2:pending'
    Invoke-Script state-sync.ps1 -Insert T8 -Before T2
    Assert-Eq 0 $script:Code "insert succeeds: $($script:Err)"
    Assert-Contains (Get-TasksText) "- **依存**: T1, T8`r`n" "CRLF kept"
}

# ---------- next-task (#13) ----------

Invoke-TestCase "next: 依存充足の最初のpending" {
    Set-Tasks ($basicTasks -replace '(?m)^- \*\*依存\*\*: T3$', '- **依存**: T3, T8')
    Add-T8 'T2'
    Set-State 'T1:done' 'T2:done' 'T3:done' 'T4:pending' 'T8:pending'
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "T8 pending" $script:Out "T8 chosen before T4"
}

Invoke-TestCase "next: 再開対象を優先" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:in_review' 'T3:pending' 'T4:pending'
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code"
    Assert-Eq "T2 in_review" $script:Out "resume target"
}

Invoke-TestCase "next: 全完了はexit 3" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:done' 'T4:done'
    Invoke-Script next-task.ps1
    Assert-Eq 3 $script:Code "exit code"
}

Invoke-TestCase "next: ブロックはexit 4" {
    Set-Tasks $basicTasks
    Set-State 'T1:failed' 'T2:pending' 'T3:pending' 'T4:pending'
    Invoke-Script next-task.ps1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Err "T1" "blocker listed"
}

Invoke-TestCase "next: 依存欄不正はexit 1" {
    Set-Tasks "## T1: a`n- **依存**: T0(なし)`n"
    Set-State 'T1:pending'
    Invoke-Script next-task.ps1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "insert: 空白区切りの-Before" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Add-T8 'T2'
    Invoke-Script state-sync.ps1 -Insert T8 -Before "T3 T4"
    Assert-Eq 0 $script:Code "space separated -Before: $($script:Err)"
}

Invoke-TestCase "見出しは大文字小文字を区別" {
    Set-Tasks "## T1: a`n- **依存**: なし`n`n## t2: lower`n- **依存**: T1`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "T1" (Get-StateIds) "lowercase heading ignored (same as sh)"
}

Invoke-TestCase "next: tasks空はexit 1" {
    Set-Tasks $basicTasks
    Set-State
    Invoke-Script next-task.ps1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "gen: 不正なTaskIdはexit 1" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId "../x"
    Assert-Eq 1 $script:Code "exit code"
}

Show-Summary
