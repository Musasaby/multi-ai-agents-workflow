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

# ---------- グループ解析とグループ間依存の検証 (#30) ----------

# 解析結果のグループ一覧: 標準出力に "T1=,T2=P,..." 形式
# -B で tasklib 直読み込み時の __pycache__ 生成も抑止する
task_groups() {
    python3 -B - "$(py_path "$TEMPLATE_SCRIPTS")" "$(py_path "$PROJ/.agents/workflow/tasks.md")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import tasklib
with open(sys.argv[2], encoding='utf-8') as f:
    tasks = tasklib.parse_tasks(f.read())
print(','.join(t['id'] + '=' + t['group'] for t in tasks))
PY
}

# group_order() の戻り値: 標準出力に ",P,A" 形式
task_group_order() {
    python3 -B - "$(py_path "$TEMPLATE_SCRIPTS")" "$(py_path "$PROJ/.agents/workflow/tasks.md")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import tasklib
with open(sys.argv[2], encoding='utf-8') as f:
    print(','.join(tasklib.group_order(f.read())))
PY
}

# 区切りつき基本タスク: T1=既定、T2/T3=グループ P、T4=グループ A(前のグループへの依存のみ)
grouped_tasks() {
    write_tasks <<'EOF'
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
EOF
}

t_sync_group_parse() {
    grouped_tasks
    run_script state-sync.sh --init --source test
    assert_eq 0 "$CODE" "init succeeds: $ERR"
    assert_eq "T1=,T2=P,T3=P,T4=A" "$(task_groups)" "groups parsed"
    assert_eq ",P,A" "$(task_group_order)" "group order (default first)"
    run_script next-task.sh
    assert_eq 0 "$CODE" "next-task with groups: $ERR"
    assert_eq "T1 pending" "$OUT" "default group task chosen"
}

t_sync_group_field_overrides() {
    grouped_tasks
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 末尾に追記したつもり
- **グループ**: P
- **依存**: T1, T3
EOF
    run_script state-sync.sh --init --source test
    assert_eq 0 "$CODE" "init succeeds: $ERR"
    assert_eq "T1=,T2=P,T3=P,T4=A,T5=P" "$(task_groups)" "group field overrides position"
}

t_sync_group_unknown_rejected() {
    grouped_tasks
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 末尾に追記したつもり
- **グループ**: ZZZ
- **依存**: T1
EOF
    run_script state-sync.sh --init --source test
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "unknown group 'ZZZ'" "stderr names the unknown group"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json not created"
}

t_sync_group_dep_later_rejected() {
    write_tasks <<'EOF'
<!-- グループ A -->

## T1: Aの処理
- **目的**: a
- **依存**: T2

<!-- グループ B -->

## T2: Bの処理
- **目的**: b
- **依存**: なし
EOF
    run_script state-sync.sh --init --source test
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "Later-group dependency: T1 (group 'A') depends on T2 (group 'B')" "stderr names task ids and both groups"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json not created"
}

t_next_group_dep_later_rejected() {
    write_tasks <<'EOF'
<!-- グループ A -->

## T1: Aの処理
- **目的**: a
- **依存**: T2

<!-- グループ B -->

## T2: Bの処理
- **目的**: b
- **依存**: なし
EOF
    write_state "T1:pending" "T2:pending"
    run_script next-task.sh
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "Later-group dependency: T1 (group 'A') depends on T2 (group 'B')" "stderr names task ids and both groups"
}

t_sync_append_group_field_keeps_backward_dep() {
    grouped_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 追加(Pに戻す)
- **グループ**: P
- **依存**: T3
EOF
    run_script state-sync.sh
    assert_eq 0 "$CODE" "append succeeds: $ERR"
    assert_eq "T1,T2,T3,T4,T5" "$(state_ids)" "T5 appended"
    assert_eq "T1=,T2=P,T3=P,T4=A,T5=P" "$(task_groups)" "T5 belongs to P via field"
}

t_sync_append_group_field_later_dep_rejected() {
    grouped_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 追加(Pに戻すつもり)
- **グループ**: P
- **依存**: T4
EOF
    local before
    before="$(cat "$PROJ/.agents/workflow/state.json")"
    run_script state-sync.sh
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "Later-group dependency: T5 (group 'P') depends on T4 (group 'A')" "stderr names task ids and both groups"
    assert_eq "$before" "$(cat "$PROJ/.agents/workflow/state.json")" "state.json unchanged"
}

t_sync_group_invalid_name_rejected() {
    grouped_tasks
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T5: 末尾に追記したつもり
- **グループ**: 
- **依存**: T1
EOF
    run_script state-sync.sh --init --source test
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "T5" "stderr names the task"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json not created"
}

t_sync_group_malformed_line_ignored() {
    write_tasks <<'EOF'
<!-- グループ: P -->

## T1: a
- **依存**: なし

<!-- グループ P B -->

## T2: b
- **依存**: T1
EOF
    run_script state-sync.sh --init --source test
    assert_eq 0 "$CODE" "malformed lines are not separators: $ERR"
    assert_eq "T1=,T2=" "$(task_groups)" "all tasks in the default group"
    assert_eq "" "$(task_group_order)" "no separator names in order"
}

# ---------- next-task: グループ限定と exit 6 (#30) ----------

# グループ P(T1)・A(T2, T3)。既定グループにタスクは無い
p_a_tasks() {
    write_tasks <<'EOF'
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
EOF
}

t_next_group_done_exit6() {
    p_a_tasks
    write_state "T1:done" "T2:pending" "T3:pending"
    set_state_group P
    run_script next-task.sh
    assert_eq 6 "$CODE" "exit code: $ERR"
    assert_eq "P" "$OUT" "stdout shows the completed group name"
}

t_next_group_advanced_to_next_group() {
    p_a_tasks
    write_state "T1:done" "T2:pending" "T3:pending"
    set_state_group A
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "T2 pending" "$OUT" "task in the current group is chosen"
}

t_next_group_missing_field_falls_back() {
    p_a_tasks
    write_state "T1:done" "T2:pending" "T3:pending"   # group フィールド無し
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "T2 pending" "$OUT" "first group with unfinished tasks is the work group"
}

t_next_group_unknown_name_falls_back() {
    p_a_tasks
    write_state "T1:pending" "T2:pending" "T3:pending"
    set_state_group ZZZ   # tasks.md に存在しないグループ名
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "T1 pending" "$OUT" "first group with unfinished tasks (P) is the work group"
}

t_next_default_group_done_exit6() {
    grouped_tasks
    write_state "T1:done" "T2:pending" "T3:pending" "T4:pending"
    set_state_group ""   # 既定グループ(空文字列)
    run_script next-task.sh
    assert_eq 6 "$CODE" "exit code: $ERR"
    assert_eq "" "$OUT" "stdout shows the default group (empty name)"
}

t_next_branch_per_group_false_chooses_all() {
    p_a_tasks
    write_state "T1:done" "T2:pending" "T3:pending"
    set_state_group P
    set_branch_per_group false
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "T2 pending" "$OUT" "task chosen from all tasks"
}

t_next_no_separator_all_done_exit3() {
    basic_tasks
    write_state "T1:done" "T2:done" "T3:done" "T4:done"
    run_script next-task.sh
    assert_eq 3 "$CODE" "all done is exit 3 even with the default group"
}

t_sync_init_group_field() {
    p_a_tasks
    run_script state-sync.sh --init --source test
    assert_eq 0 "$CODE" "init succeeds: $ERR"
    assert_eq "P" "$(state_group)" "group initialized with the first group having tasks"
    grouped_tasks
    rm "$PROJ/.agents/workflow/state.json"
    run_script state-sync.sh --init --source test
    assert_eq "" "$(state_group)" "first group is the default group when it has tasks"
}

t_sync_insert_preserves_group() {
    grouped_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"
    set_state_group P
    append_t8 "T3"
    run_script state-sync.sh --insert T8 --before T4
    assert_eq 0 "$CODE" "insert succeeds: $ERR"
    assert_eq "T1,T2,T3,T4,T8" "$(state_ids)" "T8 appended"
    assert_eq "P" "$(state_group)" "group preserved by --insert"
    cat >> "$PROJ/.agents/workflow/tasks.md" <<'EOF'

## T9: 追加
- **依存**: T4
EOF
    run_script state-sync.sh
    assert_eq 0 "$CODE" "append succeeds: $ERR"
    assert_eq "P" "$(state_group)" "group preserved by append"
}

t_sync_group_absent_kept_absent() {
    grouped_tasks
    write_state "T1:done" "T2:done" "T3:pending" "T4:pending"   # group フィールド無し
    run_script state-sync.sh
    assert_eq 0 "$CODE" "append succeeds: $ERR"
    assert_eq "<absent>" "$(state_group)" "group key not added to legacy state.json"
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

set_branch_per_group() { # $1 = true / false
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, bpg = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['branch_per_group'] = (bpg == 'true')
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

# #36: test_command と child_dispatch_command が同じなら1回だけ載せる
t_gen_dedup_verify_command() {
    basic_tasks
    write_state "T1:pending"
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['quality_gate']['child_dispatch_command'] = 'pwsh -File tests/check.ps1'
cfg['test_command'] = 'pwsh -File tests/check.ps1'
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq 1 "$(grep -c 'tests/check.ps1' "$PROJ/.agents/workflow/runs/T1-1/prompt.md")" "same command listed once"
}

ref_tasks() { # $1 = 参照ファイル欄(行全体。複数行可)
    write_tasks <<EOF
## T1: a
- **目的**: x
$1
- **依存**: なし
EOF
    write_state "T1:pending"
}

t_gen_ref_files_ok() {
    printf 'x\n' > "$PROJ/a.txt"
    mkdir -p "$PROJ/src" && printf 'y\n' > "$PROJ/src/b.sh"
    ref_tasks $'- **参照ファイル**:\n  - `a.txt`(全体)\n  - `src/b.sh:10-40`(関数 foo)'
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_not_contains "$ERR" "WARN" "no warning"
}

t_gen_ref_files_missing() {
    ref_tasks $'- **参照ファイル**:\n  - `nope.txt`'
    run_script dispatch-prompt-gen.sh T1
    assert_eq 1 "$CODE" "missing reference file -> exit 1"
    assert_contains "$ERR" "nope.txt" "missing path reported"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/prompt.md" "no prompt written"
}

t_gen_ref_files_absent_warns() {
    ref_tasks ""
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "absent field is not an error: $ERR"
    assert_contains "$ERR" "WARN: T1: no '- **参照ファイル**:' field" "warning"
}

t_gen_ref_files_none() {
    ref_tasks '- **参照ファイル**: なし'
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_not_contains "$ERR" "WARN" "no warning"
}

t_gen_agents_md_at_only_warns() {
    basic_tasks
    write_state "T1:pending"
    printf '@.agents/skills/_templates/AGENTS.md\n' > "$PROJ/AGENTS.md"
    run_script dispatch-prompt-gen.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "AGENTS.md only contains '@' references" "warning"
    printf '# AGENTS.md\n@other.md\n' > "$PROJ/AGENTS.md"
    run_script dispatch-prompt-gen.sh T1
    assert_not_contains "$ERR" "AGENTS.md only contains" "no warning when AGENTS.md has content"
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
test_case "sync: グループ区切りの解析" t_sync_group_parse
test_case "sync: グループ欄は位置より優先" t_sync_group_field_overrides
test_case "sync: 存在しないグループ名はexit 1" t_sync_group_unknown_rejected
test_case "sync: 後のグループへの依存はexit 1" t_sync_group_dep_later_rejected
test_case "next: 後のグループへの依存はexit 1" t_next_group_dep_later_rejected
test_case "sync: 追記 グループ欄で前のグループに戻す" t_sync_append_group_field_keeps_backward_dep
test_case "sync: 追記 後のグループへの依存は拒否" t_sync_append_group_field_later_dep_rejected
test_case "sync: グループ欄が空はexit 1" t_sync_group_invalid_name_rejected
test_case "sync: 不正形式の区切り行は無視" t_sync_group_malformed_line_ignored
test_case "next: 作業グループ完了はexit 6" t_next_group_done_exit6
test_case "next: 次グループを現在グループにしたら選ぶ" t_next_group_advanced_to_next_group
test_case "next: group欄なしは未完了最初のグループ" t_next_group_missing_field_falls_back
test_case "next: 未知のグループ名は未完了最初のグループ" t_next_group_unknown_name_falls_back
test_case "next: 既定グループ完了は空のグループ名でexit 6" t_next_default_group_done_exit6
test_case "next: branch_per_group false は全タスクから選ぶ" t_next_branch_per_group_false_chooses_all
test_case "next: 区切り無しで全完了はexit 3" t_next_no_separator_all_done_exit3
test_case "sync: init で group を初期化" t_sync_init_group_field
test_case "sync: insert・追記で group を保持" t_sync_insert_preserves_group
test_case "sync: group欄の無い旧stateには足さない" t_sync_group_absent_kept_absent
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
test_case "gen: 同じ検証コマンドは1回だけ載せる" t_gen_dedup_verify_command
test_case "gen: 参照ファイルが存在すれば通る" t_gen_ref_files_ok
test_case "gen: 存在しない参照ファイルはexit 1" t_gen_ref_files_missing
test_case "gen: 参照ファイル欄が無ければ警告" t_gen_ref_files_absent_warns
test_case "gen: 参照ファイル なし は検証しない" t_gen_ref_files_none
test_case "gen: @参照だけのAGENTS.mdは警告" t_gen_agents_md_at_only_warns
summary
