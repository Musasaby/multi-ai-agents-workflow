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

# commit 付きの state.json を書く: write_state_commit "T1:done:abcdef1234567" ...
write_state_commit() {
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$@" <<'PY'
import json, sys
path = sys.argv[1]
tasks = []
for item in sys.argv[2:]:
    parts = item.split(':')
    tasks.append({'id': parts[0], 'title': parts[0] + ' title', 'status': parts[1], 'retries': 0,
                  'commit': parts[2] if len(parts) > 2 else None})
state = {'source': 'test', 'branch': 'main', 'updated_at': 'x', 'tasks': tasks}
with open(path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(state, f, ensure_ascii=False)
PY
}

# summary 用の入力(要件 R1 と T1・T2 が done、PR は MERGED)を用意する
setup_summary_input() {
    write_tasks <<'EOT'
## 要件
- R1: 一つ目

## T1: T1 title
- **要件**: R1
- **依存**: なし

## T2: T2 title
- **要件**: R1
- **依存**: T1
EOT
    write_state_commit "T1:done:abcdef1234567" "T2:done:1234567abcdef"
    gh_stub_set 0 '{"state":"MERGED","url":"https://example.com/pr/1"}' ''
}

# 出力中の最初に一致する行の行番号
line_no() { printf '%s\n' "$1" | tr -d '\r' | grep -n -m1 -F -- "$2" | cut -d: -f1; }

t_summary() {
    setup_summary_input
    run_script workflow-status.sh --summary
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Task T1 done abcdef1 retries=0 | T1 title" "Task 行"
    assert_contains "$OUT" "Requirement R1 [done]:" "Requirement 行"
    assert_contains "$OUT" "Summary: done=1 partial=0 pending=0" "Summary 行"
    assert_contains "$OUT" "PR: MERGED https://example.com/pr/1" "PR の状態"
    assert_contains "$OUT" "Worktree: clean" "作業ツリー"
    assert_eq "Next: finish" "$(last_line "$OUT")" "最後の行"
    local task_n prog_n wt_n next_n
    task_n="$(line_no "$OUT" "Task T1")"; prog_n="$(line_no "$OUT" "Progress:")"
    wt_n="$(line_no "$OUT" "Worktree:")"; next_n="$(line_no "$OUT" "Next:")"
    [ "$task_n" -lt "$prog_n" ]; assert_eq 0 "$?" "Task 行が Progress 行より前"
    [ "$((wt_n + 1))" -eq "$next_n" ]; assert_eq 0 "$?" "Worktree 行が Next 行の直前"
}

t_no_summary() {
    setup_summary_input
    run_script workflow-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_not_contains "$OUT" "Task T1" "Task 行を出さない"
    assert_not_contains "$OUT" "Worktree:" "Worktree 行を出さない"
}

echo "test-workflow-status.sh"
test_case "workflow-status: 進捗・作業グループ・次のタスクを出す" t_progress_group_next
test_case "workflow-status: 実行中の子の経過を出し Next: wait にする" t_running_child
test_case "workflow-status: 全タスク完了時に PR の状態から次の操作を出す" t_all_done_pr
test_case "workflow-status: 未回答の理解確認ファイルを数える" t_unanswered_comprehension
test_case "workflow-status: --summary でタスクごとの結果・要件・作業ツリーを出す" t_summary
test_case "workflow-status: --summary を付けないと Task 行と Worktree 行を出さない" t_no_summary
summary
