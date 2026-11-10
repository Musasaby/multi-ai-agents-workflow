#!/bin/bash
# サブエージェントの run(launcher が subagent): prompt.md の追加の節・dispatch-finish・dispatch-wait。
# run ディレクトリは dispatch-start --subagent-capable(config.json を subagent: always にして)で準備する。
source "$(dirname "$0")/lib.sh"

SECTION='## サブエージェントとして実行する場合の追加の指示'
REPORT=$'作業しました\n## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス'

set_cfg() { # $1=child_agent のキー $2=値
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" "$2" <<'PY'
import json, sys
p, k, v = sys.argv[1:4]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent'][k] = v
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

set_max_parallel() { # $1=値
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1], int(sys.argv[2])
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['max_parallel'] = v
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

set_state_branch() {
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$1" <<'PY'
import json, sys
p, branch = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
s['branch'] = branch
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# 作業ブランチ・tasks.md・state.json を用意し、subagent always で dispatch-start --subagent-capable を実行する
# $1 = max_parallel(省略時は設定しない)
prepare_run() {
    git -C "$PROJ" switch -q -c develop/t
    write_tasks <<'TASKS'
## T1: 一番目
- **目的**: a
- **依存**: なし
TASKS
    write_state "T1:pending"
    set_state_branch develop/t
    gh_stub_set 0 '[]' ''
    set_cfg subagent always
    [ -n "${1:-}" ] && set_max_parallel "$1"
    run_script dispatch-start.sh T1 --subagent-capable
}

RUN_DIR() { echo "$PROJ/.agents/workflow/runs/T1-1"; }

t_prompt_section() {
    prepare_run
    assert_eq 0 "$CODE" "start exit code: $ERR"
    local prompt tail_text
    prompt="$(cat "$(RUN_DIR)/prompt.md")"
    assert_contains "$prompt" "$SECTION" "節の見出し"
    # 末尾の節(見出し以降)に未置換のプレースホルダが残っていない
    tail_text="${prompt##*"$SECTION"}"
    assert_not_contains "$tail_text" "{workdir}" "workdir が置換済み"
    assert_not_contains "$tail_text" "{tmp_dir}" "tmp_dir が置換済み"
    assert_not_contains "$tail_text" "{output_log}" "output_log が置換済み"
    local root
    if command -v cygpath > /dev/null 2>&1; then root="$(cygpath -m "$PROJ")"; else root="$PROJ"; fi
    assert_contains "$tail_text" "\`$root\`" "workdir が利用先の絶対パス"
    assert_contains "$tail_text" "$root/.agents/workflow/runs/T1-1/tmp" "tmp_dir が絶対パス"
    assert_contains "$tail_text" "$root/.agents/workflow/runs/T1-1/output.log" "output_log が絶対パス"
    assert_contains "$tail_text" ".agents/workflow/runs/T1-1/tmp" "tmp_dir の値"
    assert_contains "$tail_text" ".agents/workflow/runs/T1-1/output.log" "output_log の値"
    assert_eq 0 "$(grep -c '\\' <<< "$tail_text")" "パスが / 区切り"
}

t_prompt_section_worktree() {
    prepare_run 2
    assert_eq 0 "$CODE" "start exit code: $ERR"
    local wt prompt tail_text
    wt="$(sed -n 's/^path //p' "$(RUN_DIR)/worktree.txt" | head -n 1 | tr -d '\r' | tr '\\' '/')"
    assert_file_exists "$(RUN_DIR)/worktree.txt" "worktree.txt"
    prompt="$(cat "$(RUN_DIR)/prompt.md")"
    tail_text="${prompt##*"$SECTION"}"
    assert_contains "$tail_text" "\`$wt\`" "workdir が worktree のパス"
    assert_contains "$tail_text" "$wt/.agents/workflow/runs/T1-1/tmp" "tmp_dir が worktree 配下"
    assert_not_contains "$tail_text" "{workdir}" "workdir が置換済み"
}

t_finish_ok() {
    prepare_run
    assert_eq 0 "$CODE" "start exit code: $ERR"
    printf '%s\n' "$REPORT" > "$(RUN_DIR)/output.log"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-finish.sh T1 1
    assert_eq 0 "$CODE" "finish exit code: $ERR"
    assert_contains "$OUT" "Profile: subagent" "Profile"
    assert_eq "Next: review T1" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    assert_file_exists "$(RUN_DIR)/report.md" "report.md"
    assert_file_exists "$(RUN_DIR)/done" "done"
}

t_finish_worktree() {
    prepare_run 2
    assert_eq 0 "$CODE" "start exit code: $ERR"
    local wt
    wt="$(sed -n 's/^path //p' "$(RUN_DIR)/worktree.txt" | head -n 1 | tr -d '\r')"
    printf '%s\n' "$REPORT" > "$(RUN_DIR)/output.log"
    printf 'x\n' > "$wt/a.txt"
    run_script dispatch-finish.sh T1 1
    assert_eq 0 "$CODE" "finish exit code: $ERR"
    assert_contains "$OUT" "Profile: subagent" "Profile"
    assert_eq "Next: collect T1" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    assert_file_exists "$(RUN_DIR)/report.md" "report.md"
}

t_finish_no_log() {
    prepare_run
    assert_eq 0 "$CODE" "start exit code: $ERR"
    run_script dispatch-finish.sh T1 1
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "output.log not found" "stderr"
    assert_file_absent "$(RUN_DIR)/done" "done は作られない"
}

t_wait_subagent() {
    prepare_run
    assert_eq 0 "$CODE" "start exit code: $ERR"
    run_script dispatch-wait.sh T1 1
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "subagent run" "stderr"
}

echo "test-dispatch-subagent.sh"
test_case "subagent: prompt.md の末尾に節があり、プレースホルダが絶対パスに置き換わる" t_prompt_section
test_case "subagent: max_parallel 2 では {workdir} が worktree のパスになる" t_prompt_section_worktree
test_case "subagent: dispatch-finish は Profile: subagent で Next: review になり report.md を作る" t_finish_ok
test_case "subagent: worktree の run の dispatch-finish は Next: collect になる" t_finish_worktree
test_case "subagent: output.log が無いと dispatch-finish は exit 1" t_finish_no_log
test_case "subagent: dispatch-wait はサブエージェントの run で exit 1" t_wait_subagent
summary
