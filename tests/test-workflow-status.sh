#!/bin/bash
# workflow-status(進捗と次の操作の表示, 通常モード, POSIX版)。
# gh は lib.sh が PATH 先頭に置くスタブで差し替える
source "$(dirname "$0")/lib.sh"

last_line() { printf '%s\n' "$1" | tr -d '\r' | tail -n 1; }

t_progress_group_next() {
    write_tasks <<'EOT'
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
EOT
    write_state "T1:done" "T2:pending" "T3:pending"
    set_state_group G2
    run_script workflow-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Progress: 1/3 done" "進捗"
    assert_contains "$OUT" "Group: G2 0/2" "作業グループ"
    assert_contains "$OUT" "Current: none" "実行中なし"
    assert_contains "$OUT" "Comprehension: unanswered=0" "理解確認"
    assert_eq "Next: dispatch T2" "$(last_line "$OUT")" "最後の行"
}

t_running_child() {
    write_tasks <<'EOT'
## T1: T1 title
- **目的**: a
- **依存**: なし
EOT
    write_state "T1:in_progress"
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    printf 'x\n' > "$PROJ/.agents/workflow/runs/T1-1/guard.sha256"
    printf 'log\n' > "$PROJ/.agents/workflow/runs/T1-1/output.log"
    run_script workflow-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Current: T1 in_progress | T1 title" "実行中のタスク"
    assert_contains "$OUT" "Run: T1-1 running elapsed=" "経過時間"
    assert_contains "$OUT" "log_idle=" "ログの無更新時間"
    assert_eq "Next: wait" "$(last_line "$OUT")" "最後の行"
}

t_all_done_pr() {
    write_tasks <<'EOT'
## T1: T1 title
- **目的**: a
- **依存**: なし
EOT
    write_state "T1:done"
    gh_stub_set 0 '{"state":"OPEN","url":"https://example.com/pr/1"}' ''
    run_script workflow-status.sh
    assert_eq 0 "$CODE" "exit(OPEN): $ERR"
    assert_contains "$OUT" "PR: OPEN https://example.com/pr/1" "PR の状態"
    assert_eq "Next: wait-merge" "$(last_line "$OUT")" "OPEN の Next"
    gh_stub_set 1 '' 'no pull requests found for branch "main"'
    run_script workflow-status.sh
    assert_eq 0 "$CODE" "exit(none): $ERR"
    assert_contains "$OUT" "PR: none" "PR なし"
    assert_eq "Next: create-pr" "$(last_line "$OUT")" "PR なしの Next"
}

t_unanswered_comprehension() {
    write_tasks <<'EOT'
## T1: T1 title
- **目的**: a
- **依存**: なし
EOT
    write_state "T1:pending"
    mkdir -p "$PROJ/.agents/workflow/comprehension"
    printf '**あなたの回答**: <!-- ここに記入 -->\n' > "$PROJ/.agents/workflow/comprehension/T1.md"
    printf '**あなたの回答**: B\n' > "$PROJ/.agents/workflow/comprehension/T2.md"
    run_script workflow-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Comprehension: unanswered=1 T1.md" "未回答の数とファイル名"
}

echo "test-workflow-status.sh"
test_case "workflow-status: 進捗・作業グループ・次のタスクを出す" t_progress_group_next
test_case "workflow-status: 実行中の子の経過を出し Next: wait にする" t_running_child
test_case "workflow-status: 全タスク完了時に PR の状態から次の操作を出す" t_all_done_pr
test_case "workflow-status: 未回答の理解確認ファイルを数える" t_unanswered_comprehension
summary
