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

Invoke-TestCase "sync: 追記 既存タスクのタイトルを更新" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Set-Tasks ((Get-TasksText) -replace '## T1: 一番目', '## T1: 改題済み')
    Invoke-Script state-sync.ps1
    Assert-Eq 0 $script:Code "title update succeeds: $($script:Err)"
    Assert-Eq "改題済み" (Get-StateTask T1).title "title updated"
    Assert-Eq done (Get-StateTask T1).status "existing status kept"
    Assert-Contains $script:Out "Updated title: T1" "stdout mentions Updated title"
}

Invoke-TestCase "sync: 追記 タイトル不変なら Updated を出さない" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Invoke-Script state-sync.ps1 # 初回: タイトルを tasks.md の見出しに合わせる
    Assert-Eq 0 $script:Code "first sync succeeds: $($script:Err)"
    Invoke-Script state-sync.ps1
    Assert-Eq 0 $script:Code "second sync succeeds: $($script:Err)"
    Assert-NotContains $script:Out "Updated title" "no Updated title when unchanged"
}

# ---------- グループ解析とグループ間依存の検証 (#30) ----------

# tasklib のグループ解析(Read-TaskList / Get-GroupOrder)を直接検証する
. "$script:TemplateScripts/tasklib.ps1"
function Get-TaskGroups {
    return ((@(Read-TaskList @(Split-TaskLines (Get-TasksText))) | ForEach-Object { $_.id + '=' + $_.group }) -join ',')
}
function Get-TaskGroupOrder { return (((Get-GroupOrder @(Split-TaskLines (Get-TasksText)))) -join ',') }

$groupedTasks = @'
## T1: 既定の基盤
- **目的**: p
- **依存**: なし

<!-- グループ P: 既存成果の取り込み -->

## T2: Pの処理A
- **目的**: a
- **依存**: T1

## T3: Pの処理B
- **目的**: b
- **依存**: T1, T2

<!-- グループ A -->

## T4: Aの処理
- **目的**: c
- **依存**: T2, T3
'@

Invoke-TestCase "sync: グループ区切りの解析" {
    Set-Tasks $groupedTasks
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 0 $script:Code "init succeeds: $($script:Err)"
    Assert-Eq "T1=,T2=P,T3=P,T4=A" (Get-TaskGroups) "groups parsed"
    Assert-Eq ",P,A" (Get-TaskGroupOrder) "group order (default first)"
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "next-task with groups: $($script:Err)"
    Assert-Eq "T1 pending" $script:Out "default group task chosen"
}

Invoke-TestCase "sync: グループ欄は位置より優先" {
    Set-Tasks $groupedTasks
    Add-Tasks "`n`n## T5: 末尾に追記したつもり`n- **グループ**: P`n- **依存**: T1, T3`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 0 $script:Code "init succeeds: $($script:Err)"
    Assert-Eq "T1=,T2=P,T3=P,T4=A,T5=P" (Get-TaskGroups) "group field overrides position"
}

Invoke-TestCase "sync: 存在しないグループ名はexit 1" {
    Set-Tasks $groupedTasks
    Add-Tasks "`n`n## T5: 末尾に追記したつもり`n- **グループ**: ZZZ`n- **依存**: T1`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "unknown group 'ZZZ'" "stderr names the unknown group"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json not created"
}

$crossGroupTasks = @'
<!-- グループ A -->

## T1: Aの処理
- **目的**: a
- **依存**: T2

<!-- グループ B -->

## T2: Bの処理
- **目的**: b
- **依存**: なし
'@

Invoke-TestCase "sync: 後のグループへの依存はexit 1" {
    Set-Tasks $crossGroupTasks
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "Later-group dependency: T1 (group 'A') depends on T2 (group 'B')" "stderr names task ids and both groups"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json not created"
}

Invoke-TestCase "next: 後のグループへの依存はexit 1" {
    Set-Tasks $crossGroupTasks
    Set-State 'T1:pending' 'T2:pending'
    Invoke-Script next-task.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "Later-group dependency: T1 (group 'A') depends on T2 (group 'B')" "stderr names task ids and both groups"
}

Invoke-TestCase "sync: 追記 グループ欄で前のグループに戻す" {
    Set-Tasks $groupedTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Add-Tasks "`n`n## T5: 追加(Pに戻す)`n- **グループ**: P`n- **依存**: T3`n"
    Invoke-Script state-sync.ps1
    Assert-Eq 0 $script:Code "append succeeds: $($script:Err)"
    Assert-Eq "T1,T2,T3,T4,T5" (Get-StateIds) "T5 appended"
    Assert-Eq "T1=,T2=P,T3=P,T4=A,T5=P" (Get-TaskGroups) "T5 belongs to P via field"
}

Invoke-TestCase "sync: 追記 後のグループへの依存は拒否" {
    Set-Tasks $groupedTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Add-Tasks "`n`n## T5: 追加(Pに戻すつもり)`n- **グループ**: P`n- **依存**: T4`n"
    $before = Get-StateText
    Invoke-Script state-sync.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "Later-group dependency: T5 (group 'P') depends on T4 (group 'A')" "stderr names task ids and both groups"
    Assert-Eq $before (Get-StateText) "state.json unchanged"
}

Invoke-TestCase "sync: グループ欄が空はexit 1" {
    Set-Tasks $groupedTasks
    Add-Tasks "`n`n## T5: 末尾に追記したつもり`n- **グループ**: `n- **依存**: T1`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "T5" "stderr names the task"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json not created"
}

Invoke-TestCase "sync: 不正形式の区切り行は無視" {
    Set-Tasks "<!-- グループ: P -->`n`n## T1: a`n- **依存**: なし`n`n<!-- グループ P B -->`n`n## T2: b`n- **依存**: T1`n"
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 0 $script:Code "malformed lines are not separators: $($script:Err)"
    Assert-Eq "T1=,T2=" (Get-TaskGroups) "all tasks in the default group"
    Assert-Eq "" (Get-TaskGroupOrder) "no separator names in order"
}

# ---------- next-task: グループ限定と exit 6 (#30) ----------

# グループ P(T1)・A(T2, T3)。既定グループにタスクは無い
$paTasks = @'
<!-- グループ P -->

## T1: Pの処理
- **目的**: p
- **依存**: なし

<!-- グループ A -->

## T2: Aの処理
- **目的**: a
- **依存**: T1

## T3: Aの処理2
- **目的**: b
- **依存**: T2
'@

function Set-BranchPerGroup { param([bool]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.branch_per_group = $Value
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

Invoke-TestCase "next: 作業グループ完了はexit 6" {
    Set-Tasks $paTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Set-StateGroup P
    Invoke-Script next-task.ps1
    Assert-Eq 6 $script:Code "exit code: $($script:Err)"
    Assert-Eq P $script:Out "stdout shows the completed group name"
}

Invoke-TestCase "next: 次グループを現在グループにしたら選ぶ" {
    Set-Tasks $paTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Set-StateGroup A
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "T2 pending" $script:Out "task in the current group is chosen"
}

Invoke-TestCase "next: group欄なしは未完了最初のグループ" {
    Set-Tasks $paTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "T2 pending" $script:Out "first group with unfinished tasks is the work group"
}

Invoke-TestCase "next: 未知のグループ名は未完了最初のグループ" {
    Set-Tasks $paTasks
    Set-State 'T1:pending' 'T2:pending' 'T3:pending'
    Set-StateGroup ZZZ
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "T1 pending" $script:Out "first group with unfinished tasks (P) is the work group"
}

Invoke-TestCase "next: 既定グループ完了は空のグループ名でexit 6" {
    Set-Tasks $groupedTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending' 'T4:pending'
    Set-StateGroup ''
    Invoke-Script next-task.ps1
    Assert-Eq 6 $script:Code "exit code: $($script:Err)"
    Assert-Eq "" $script:Out "stdout shows the default group (empty name)"
}

Invoke-TestCase "next: branch_per_group false は全タスクから選ぶ" {
    Set-Tasks $paTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Set-StateGroup P
    Set-BranchPerGroup $false
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "T2 pending" $script:Out "task chosen from all tasks"
}

Invoke-TestCase "next: 区切り無しで全完了はexit 3" {
    Set-Tasks $basicTasks
    Set-State 'T1:done' 'T2:done' 'T3:done' 'T4:done'
    Invoke-Script next-task.ps1
    Assert-Eq 3 $script:Code "all done is exit 3 even with the default group"
}

Invoke-TestCase "sync: init で group を初期化" {
    Set-Tasks $paTasks
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq 0 $script:Code "init succeeds: $($script:Err)"
    Assert-Eq P (Get-StateGroup) "group initialized with the first group having tasks"
    Set-Tasks $groupedTasks
    Remove-Item "$script:Proj/.agents/workflow/state.json" -Force
    Invoke-Script state-sync.ps1 -Init -Source test
    Assert-Eq "" (Get-StateGroup) "first group is the default group when it has tasks"
}

Invoke-TestCase "sync: insert・追記で group を保持" {
    Set-Tasks $groupedTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Set-StateGroup P
    Add-T8 'T3'
    Invoke-Script state-sync.ps1 -Insert T8 -Before T4
    Assert-Eq 0 $script:Code "insert succeeds: $($script:Err)"
    Assert-Eq "T1,T2,T3,T4,T8" (Get-StateIds) "T8 appended"
    Assert-Eq P (Get-StateGroup) "group preserved by -Insert"
    Add-Tasks "`n`n## T9: 追加`n- **依存**: T4`n"
    Invoke-Script state-sync.ps1
    Assert-Eq 0 $script:Code "append succeeds: $($script:Err)"
    Assert-Eq P (Get-StateGroup) "group preserved by append"
}

Invoke-TestCase "sync: group欄の無い旧stateには足さない" {
    Set-Tasks $groupedTasks
    Set-State 'T1:done' 'T2:done' 'T3:pending' 'T4:pending'
    Invoke-Script state-sync.ps1
    Assert-Eq 0 $script:Code "append succeeds: $($script:Err)"
    Assert-Eq "<absent>" (Get-StateGroup) "group key not added to legacy state.json"
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

function Set-VerifyConfig {
    param([string]$StepsJson, [string]$TestCommand)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.quality_gate.steps = @($StepsJson | ConvertFrom-Json)
    $cfg.test_command = $TestCommand
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}
function Get-PromptT1 { return [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/prompt.md") }

Invoke-TestCase "gen: 空のquality_gateステップは載せない" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    Set-VerifyConfig '[{"name":"typecheck","command":"","blocking":true},{"name":"test","command":"npm test","blocking":true},{"name":"lint","command":"","blocking":false}]' ''
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains (Get-PromptT1) "- test: npm test" "non-empty step listed"
    Assert-NotContains (Get-PromptT1) "typecheck" "empty step skipped"
    Assert-Contains (Get-PromptT1) "受け入れ基準に書かれた確認手順" "acceptance criteria always included"
}

Invoke-TestCase "gen: 検証コマンド未設定は受け入れ基準を指示" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    Set-VerifyConfig '[{"name":"typecheck","command":"","blocking":true}]' ''
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains (Get-PromptT1) "受け入れ基準に書かれた確認手順" "falls back to acceptance criteria"
    Assert-NotContains (Get-PromptT1) "設定ファイルの" "no human-facing config message"
}

Invoke-TestCase "gen: プロジェクト固有の指示を含まない" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-NotContains (Get-PromptT1) "kotlin" "no Kotlin-specific instruction"
    Assert-NotContains (Get-PromptT1) "Gradle" "no Gradle-specific instruction"
    Assert-Contains (Get-PromptT1) "AGENTS.md" "points to AGENTS.md for project-specific rules"
}

Invoke-TestCase "gen: config.json が壊れていればexit 1" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    Write-Utf8File "$script:Proj/.agents/workflow/config.json" '{ broken'
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 1 $script:Code "broken config.json -> exit 1"
}

# #36: test_command と child_dispatch_command が同じなら1回だけ載せる
Invoke-TestCase "gen: 同じ検証コマンドは1回だけ載せる" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.quality_gate.child_dispatch_command = 'pwsh -File tests/check.ps1'
    $cfg.test_command = 'pwsh -File tests/check.ps1'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq 1 ([regex]::Matches((Get-PromptT1), [regex]::Escape('tests/check.ps1')).Count) "same command listed once"
}

function Set-RefTasks {
    param([string]$Field)
    Set-Tasks "## T1: a`n- **目的**: x`n$Field`n- **依存**: なし`n"
    Set-State 'T1:pending'
}

Invoke-TestCase "gen: 参照ファイルが存在すれば通る" {
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Write-Utf8File "$script:Proj/src/b.sh" "y`n"
    Set-RefTasks "- **参照ファイル**:`n  - ``a.txt``(全体)`n  - ``src/b.sh:10-40``(関数 foo)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-NotContains $script:Err "WARN" "no warning"
}

Invoke-TestCase "gen: 存在しない参照ファイルはexit 1" {
    Set-RefTasks "- **参照ファイル**:`n  - ``nope.txt``"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 1 $script:Code "missing reference file -> exit 1"
    Assert-Contains $script:Err "nope.txt" "missing path reported"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "no prompt written"
}

Invoke-TestCase "gen: 参照ファイル欄が無ければ警告" {
    Set-RefTasks ""
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "absent field is not an error: $($script:Err)"
    Assert-Contains $script:Err "WARN: T1: no '- **参照ファイル**:' field" "warning"
}

Invoke-TestCase "gen: 参照ファイル なし は検証しない" {
    Set-RefTasks "- **参照ファイル**: なし"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-NotContains $script:Err "WARN" "no warning"
}

Invoke-TestCase "gen: @参照だけのAGENTS.mdは警告" {
    Set-Tasks $basicTasks
    Set-State 'T1:pending'
    Write-Utf8File "$script:Proj/AGENTS.md" "@.agents/skills/_templates/AGENTS.md`n"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "AGENTS.md only contains '@' references" "warning"
    Write-Utf8File "$script:Proj/AGENTS.md" "# AGENTS.md`n@other.md`n"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-NotContains $script:Err "AGENTS.md only contains" "no warning when AGENTS.md has content"
}

Invoke-TestCase "gen: 同じ行の参照ファイルも検証する" {
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Set-RefTasks "- **参照ファイル**: ``a.txt:1-5``(全体)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "inline reference accepted: $($script:Err)"
    Set-RefTasks "- **参照ファイル**: ``nope.txt``"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 1 $script:Code "inline missing reference -> exit 1"
}

Invoke-TestCase "gen: 受け入れ基準が6件以上なら警告" {
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Set-RefTasks "- **受け入れ基準**:`n  - [ ] c1`n  - [ ] c2`n  - [ ] c3`n  - [ ] c4`n  - [ ] c5`n  - [ ] c6`n- **参照ファイル**:`n  - ``a.txt``(全体)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "WARN: T1: 6 acceptance criteria (more than 5; consider splitting the task)" "warning"
}

Invoke-TestCase "gen: 変更対象の参照ファイルが4件以上なら警告" {
    foreach ($f in @('a', 'b', 'c', 'd')) { Write-Utf8File "$script:Proj/$f.txt" "x`n" }
    Set-RefTasks "- **参照ファイル**:`n  - ``a.txt``(変更対象)`n  - ``b.txt``(変更対象)`n  - ``c.txt``(変更対象)`n  - ``d.txt``(変更対象)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "WARN: T1: 4 reference files marked 変更対象 (more than 3; consider splitting the task)" "warning"
}

Invoke-TestCase "gen: 受け入れ基準5件・変更対象3件なら警告しない" {
    foreach ($f in @('a', 'b', 'c')) { Write-Utf8File "$script:Proj/$f.txt" "x`n" }
    Set-RefTasks "- **受け入れ基準**:`n  - [ ] c1`n  - [ ] c2`n  - [ ] c3`n  - [ ] c4`n  - [ ] c5`n- **参照ファイル**:`n  - ``a.txt``(変更対象)`n  - ``b.txt``(変更対象)`n  - ``c.txt``(全体)"
    Invoke-Script dispatch-prompt-gen.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-NotContains $script:Err "WARN" "no warning"
}

# ---------- テスト環境の切り離し(Issue F-1) ----------

Invoke-TestCase "テストの git はグローバル設定を読まない" {
    $globalOut = & git config --global --list 2>&1
    Assert-Eq "" ($globalOut -join "`n") "global config is empty"
}

Show-Summary
