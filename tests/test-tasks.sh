#!/bin/bash
# #13 / #14: 依存欄の検証・タスク挿入・次タスク選択(POSIX版)
source "$(dirname "$0")/lib.sh"

basic_tasks() {
    write_tasks <<'EOF'
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
EOF
}

# ---------- dispatch-prompt-gen: 依存欄の検証 (#14) ----------

t_gen_annotation_rejected() {
    write_tasks <<'EOF'
## T30: 基盤
- **依存**: なし

## T31: 利用側
- **依存**: T30(Prometheus 基盤。完了済み)
EOF
    write_state "T30:done" "T31:pending"
    write_report T30 1
    run_script dispatch-prompt-gen.sh T31
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "T30(Prometheus 基盤。完了済み)" "stderr shows invalid token"
    assert_file_absent "$PROJ/.agents/workflow/runs/T31-1/prompt.md" "prompt not generated"
}

t_gen_valid_forms_pass() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    write_report T1 1; write_report T2 1
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "なし passes: $ERR"
    run_script dispatch-prompt-gen.sh T2
    assert_eq 0 "$CODE" "single dep passes: $ERR"
    run_script dispatch-prompt-gen.sh T3
    assert_eq 0 "$CODE" "multiple deps pass: $ERR"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T3-1/prompt.md")" "### T2:" "handoff includes T2"
}

t_gen_unknown_id_rejected() {
    write_tasks <<'EOF'
## T1: a
- **依存**: T99
EOF
    write_state "T1:pending"
    run_script dispatch-prompt-gen.sh T1
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "T99" "stderr names unknown id"
}

t_gen_self_dep_rejected() {
    write_tasks <<'EOF'
## T1: a
- **依存**: T1
EOF
    write_state "T1:pending"
    run_script dispatch-prompt-gen.sh T1
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "T1" "stderr names self dependency"
}

t_gen_missing_dep_line_rejected() {
    write_tasks <<'EOF'
## T1: a
- **目的**: x
EOF
    write_state "T1:pending"
    run_script dispatch-prompt-gen.sh T1
    assert_eq 1 "$CODE" "exit code"
}

t_gen_handoff_guard_still_exit2() {
    basic_tasks
    write_state "T1:done" "T2:pending" "T3:pending" "T4:pending"
    run_script dispatch-prompt-gen.sh T2
    assert_eq 2 "$CODE" "missing report -> exit 2"
}

# ---------- state-sync: 依存欄の検証 (#14) ----------

t_sync_init_valid() {
    basic_tasks
    run_script state-sync.sh --init --source test
    assert_eq 0 "$CODE" "init succeeds: $ERR"
    assert_eq "T1,T2,T3,T4" "$(state_ids)" "ids"
}

t_sync_init_annotation_rejected() {
    write_tasks <<'EOF'
## T1: a
- **依存**: なし

## T2: b
- **依存**: T1(完了済み)
EOF
    run_script state-sync.sh --init --source test
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "T1(完了済み)" "stderr shows token"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json not created"
}

t_sync_init_missing_line_rejected() {
    write_tasks <<'EOF'
## T1: a
- **目的**: x
EOF
    run_script state-sync.sh --init --source test
    assert_eq 1 "$CODE" "exit code"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json not created"
}

t_sync_init_cycle_rejected() {
    write_tasks <<'EOF'
## T1: a
- **依存**: T3

## T2: b
- **依存**: T1

## T3: c
- **依存**: T2
EOF
    run_script state-sync.sh --init --source test
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "ycl" "stderr mentions cycle"
}

t_sync_append_invalid_keeps_state() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 追加
- **依存**: T4 (あとで)
EOF
    local before
    before="$(cat "$PROJ/.agents/workflow/state.json")"
    run_script state-sync.sh
    assert_eq 1 "$CODE" "exit code"
    assert_eq "$before" "$(cat "$PROJ/.agents/workflow/state.json")" "state.json unchanged"
}

t_sync_append_valid() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 追加
- **依存**: T4
EOF
    run_script state-sync.sh
    assert_eq 0 "$CODE" "append succeeds: $ERR"
    assert_eq "T1,T2,T3,T4,T5" "$(state_ids)" "ids"
    assert_eq done "$(state_get T1 status)" "existing status kept"
}

# ---------- state-sync: 挿入 (#13) ----------

append_t8() { # $1 = T8 の依存
    cat >> "$PROJ/.agents/workflow/tasks.md" <<EOF

## T8: 挿入タスク
- **目的**: inserted
- **依存**: $1
EOF
}

t_insert_before_pending() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:done" "T4:pending"
    append_t8 "T3"
    run_script state-sync.sh --insert T8 --before T4
    assert_eq 0 "$CODE" "insert succeeds: $ERR"
    assert_contains "$(cat "$PROJ/.agents/workflow/tasks.md")" "- **依存**: T3, T8" "T4 deps updated"
    assert_eq "T1,T2,T3,T4,T8" "$(state_ids)" "T8 appended to state"
    assert_eq pending "$(state_get T8 status)" "T8 pending"
    assert_eq done "$(state_get T3 status)" "T3 kept"
    assert_eq pending "$(state_get T4 status)" "T4 kept"
}

t_insert_before_none_dep() {
    write_tasks <<'EOF'
## T1: a
- **依存**: なし

## T2: b
- **依存**: なし
EOF
    write_state "T1:pending" "T2:pending"
    append_t8 "なし"
    run_script state-sync.sh --insert T8 --before T1,T2
    assert_eq 0 "$CODE" "insert succeeds: $ERR"
    local tasks
    tasks="$(cat "$PROJ/.agents/workflow/tasks.md")"
    assert_eq 2 "$(printf '%s\n' "$tasks" | grep -c '^- \*\*依存\*\*: T8$')" "both deps become T8"
}

t_insert_before_non_pending_rejected() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:in_progress" "T4:pending"
    append_t8 "T2"
    local before_tasks before_state
    before_tasks="$(cat "$PROJ/.agents/workflow/tasks.md")"
    before_state="$(cat "$PROJ/.agents/workflow/state.json")"
    run_script state-sync.sh --insert T8 --before T3
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "T3" "stderr names T3"
    assert_eq "$before_tasks" "$(cat "$PROJ/.agents/workflow/tasks.md")" "tasks.md unchanged"
    assert_eq "$before_state" "$(cat "$PROJ/.agents/workflow/state.json")" "state.json unchanged"
}

t_insert_cycle_rejected() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:done" "T4:pending"
    append_t8 "T4"
    local before_tasks
    before_tasks="$(cat "$PROJ/.agents/workflow/tasks.md")"
    run_script state-sync.sh --insert T8 --before T4
    assert_eq 1 "$CODE" "exit code"
    assert_eq "$before_tasks" "$(cat "$PROJ/.agents/workflow/tasks.md")" "tasks.md unchanged"
}

t_insert_requires_before() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:done" "T4:pending"
    append_t8 "T3"
    run_script state-sync.sh --insert T8
    assert_eq 1 "$CODE" "--insert without --before"
}

t_insert_preserves_crlf() {
    printf '## T1: a\r\n- **依存**: なし\r\n\r\n## T2: b\r\n- **依存**: T1\r\n\r\n## T8: c\r\n- **依存**: T1\r\n' \
        > "$PROJ/.agents/workflow/tasks.md"
    write_state "T1:done" "T2:pending"
    run_script state-sync.sh --insert T8 --before T2
    assert_eq 0 "$CODE" "insert succeeds: $ERR"
    assert_contains "$(cat "$PROJ/.agents/workflow/tasks.md")" $'- **依存**: T1, T8\r' "CRLF kept"
}

# ---------- next-task (#13) ----------

t_next_first_ready_pending() {
    basic_tasks
    append_t8 "T2"
    sed -i 's/^- \*\*依存\*\*: T3$/- **依存**: T3, T8/' "$PROJ/.agents/workflow/tasks.md"
    write_state "T1:done" "T2:done" "T3:done" "T4:pending" "T8:pending"
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "T8 pending" "$OUT" "T8 chosen before T4"
}

t_next_resume_first() {
    basic_tasks
    write_state "T1:done" "T2:in_review" "T3:pending" "T4:pending"
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code"
    assert_eq "T2 in_review" "$OUT" "resume target"
}

t_next_all_done() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:done" "T4:done"
    run_script next-task.sh
    assert_eq 3 "$CODE" "exit code"
}

t_next_blocked() {
    basic_tasks
    write_state "T1:failed" "T2:pending" "T3:pending" "T4:pending"
    run_script next-task.sh
    assert_eq 4 "$CODE" "exit code"
    assert_contains "$ERR" "T1" "blocker listed"
}

t_next_invalid_deps() {
    write_tasks <<'EOF'
## T1: a
- **依存**: T0(なし)
EOF
    write_state "T1:pending"
    run_script next-task.sh
    assert_eq 1 "$CODE" "exit code"
}

t_no_pycache() {
    basic_tasks
    run_script state-sync.sh --init --source test
    run_script next-task.sh
    run_script dispatch-prompt-gen.sh T1
    assert_file_absent "$PROJ/.agents/workflow/scripts/__pycache__" "no __pycache__ in scripts/"
}

t_insert_before_space_separated() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    append_t8 "T2"
    run_script state-sync.sh --insert T8 --before "T3 T4"
    assert_eq 0 "$CODE" "space separated --before: $ERR"
}

t_next_empty_state() {
    basic_tasks
    write_state
    run_script next-task.sh
    assert_eq 1 "$CODE" "empty state.json tasks -> exit 1"
}

t_gen_invalid_task_id() {
    basic_tasks
    write_state "T1:pending"
    run_script dispatch-prompt-gen.sh "../x"
    assert_eq 1 "$CODE" "path-like task id rejected"
}

set_verify_config() { # $1 = quality_gate.steps の JSON, $2 = test_command
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" "$2" <<'PY'
import json, sys
p, steps, tc = sys.argv[1:4]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['quality_gate']['steps'] = json.loads(steps)
cfg['test_command'] = tc
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

prompt_t1() { cat "$PROJ/.agents/workflow/runs/T1-1/prompt.md"; }

t_gen_skips_empty_steps() {
    basic_tasks
    write_state "T1:pending"
    set_verify_config '[{"name":"typecheck","command":"","blocking":true},{"name":"test","command":"npm test","blocking":true},{"name":"lint","command":"","blocking":false}]' ""
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$(prompt_t1)" "- test: npm test" "non-empty step listed"
    assert_not_contains "$(prompt_t1)" "typecheck" "empty step skipped"
    assert_contains "$(prompt_t1)" "受け入れ基準に書かれた確認手順" "acceptance criteria always included"
}

t_gen_no_verify_command() {
    basic_tasks
    write_state "T1:pending"
    set_verify_config '[{"name":"typecheck","command":"","blocking":true}]' ""
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$(prompt_t1)" "受け入れ基準に書かれた確認手順" "falls back to acceptance criteria"
    assert_not_contains "$(prompt_t1)" "設定ファイルの" "no human-facing config message"
}

t_gen_no_project_specific_text() {
    basic_tasks
    write_state "T1:pending"
    run_script dispatch-prompt-gen.sh T1
    assert_not_contains "$(prompt_t1)" "kotlin" "no Kotlin-specific instruction"
    assert_not_contains "$(prompt_t1)" "Gradle" "no Gradle-specific instruction"
    assert_contains "$(prompt_t1)" "AGENTS.md" "points to AGENTS.md for project-specific rules"
}

t_gen_broken_config() {
    basic_tasks
    write_state "T1:pending"
    printf '{ broken' > "$PROJ/.agents/workflow/config.json"
    run_script dispatch-prompt-gen.sh T1
    assert_eq 1 "$CODE" "broken config.json -> exit 1"
}

echo "test-tasks.sh"
test_case "gen: 注記付き依存はexit 1" t_gen_annotation_rejected
test_case "gen: 正しい形式は通る" t_gen_valid_forms_pass
test_case "gen: 存在しないIDはexit 1" t_gen_unknown_id_rejected
test_case "gen: 自己依存はexit 1" t_gen_self_dep_rejected
test_case "gen: 依存行なしはexit 1" t_gen_missing_dep_line_rejected
test_case "gen: 引き継ぎガードはexit 2のまま" t_gen_handoff_guard_still_exit2
test_case "sync: init 正常" t_sync_init_valid
test_case "sync: init 注記はexit 1" t_sync_init_annotation_rejected
test_case "sync: init 依存行なしはexit 1" t_sync_init_missing_line_rejected
test_case "sync: init 循環はexit 1" t_sync_init_cycle_rejected
test_case "sync: 追記 不正ならstate不変" t_sync_append_invalid_keeps_state
test_case "sync: 追記 正常" t_sync_append_valid
test_case "insert: pendingの前に挿入" t_insert_before_pending
test_case "insert: なし→T8、複数指定" t_insert_before_none_dep
test_case "insert: pending以外は拒否" t_insert_before_non_pending_rejected
test_case "insert: 循環は拒否" t_insert_cycle_rejected
test_case "insert: --before必須" t_insert_requires_before
test_case "insert: CRLF保持" t_insert_preserves_crlf
test_case "next: 依存充足の最初のpending" t_next_first_ready_pending
test_case "next: 再開対象を優先" t_next_resume_first
test_case "next: 全完了はexit 3" t_next_all_done
test_case "next: ブロックはexit 4" t_next_blocked
test_case "next: 依存欄不正はexit 1" t_next_invalid_deps
test_case "__pycache__ を作らない" t_no_pycache
test_case "insert: 空白区切りの--before" t_insert_before_space_separated
test_case "next: tasks空はexit 1" t_next_empty_state
test_case "gen: 不正なTaskIdはexit 1" t_gen_invalid_task_id
test_case "gen: 空のquality_gateステップは載せない" t_gen_skips_empty_steps
test_case "gen: 検証コマンド未設定は受け入れ基準を指示" t_gen_no_verify_command
test_case "gen: プロジェクト固有の指示を含まない" t_gen_no_project_specific_text
test_case "gen: config.json が壊れていればexit 1" t_gen_broken_config
summary
