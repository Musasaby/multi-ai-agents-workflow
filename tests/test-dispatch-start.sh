#!/bin/bash
# #57: dispatch-start(事前チェック〜デタッチ起動, POSIX版)。
# gh は lib.sh のスタブ、子は .agents/child.sh(ダミープロジェクトで gitignore 済み)で差し替える。
source "$(dirname "$0")/lib.sh"

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

# 作業ブランチ・tasks.md・state.json・子スタブを用意する
setup() { # $1... = write_state の引数
    git -C "$PROJ" switch -q -c develop/t
    write_tasks <<'TASKS'
## T1: 一番目
- **目的**: a
- **依存**: なし

## T2: 二番目
- **目的**: b
- **依存**: T1
TASKS
    write_state "$@"
    set_state_branch develop/t
    gh_stub_set 0 '[]' ''
    printf '#!/bin/bash\necho child\n' > "$PROJ/.agents/child.sh"
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['command_template'] = 'bash ./.agents/child.sh "{prompt}"'
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# runs/T1-1/done が現れるまで最大30秒待つ(0.5秒ごと)
wait_done() {
    local i
    for i in $(seq 1 60); do
        [ -f "$PROJ/.agents/workflow/runs/$1/done" ] && return 0
        sleep 0.5
    done
    return 1
}

t_start_ok() {
    setup "T1:pending" "T2:pending"
    run_script dispatch-start.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: wait" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_contains "$OUT" "Run: T1-1" "Run line"
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/prompt.md" "prompt.md"
    assert_eq in_progress "$(state_get T1 status)" "T1 status"
    wait_done T1-1
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/done" "done within 30s"
}

t_dirty_tree() {
    setup "T1:pending" "T2:pending"
    printf 'x\n' > "$PROJ/x.txt"
    run_script dispatch-start.sh T1
    assert_eq 20 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "Working tree is not clean:" "stderr"
    assert_eq "Next: escalate reason=dirty-tree" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_eq pending "$(state_get T1 status)" "T1 status"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/prompt.md" "no prompt"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/done" "child not started"
}

t_dep_incomplete() {
    setup "T1:pending" "T2:pending"
    run_script dispatch-start.sh T2
    assert_eq 42 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=prompt-gen" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_eq pending "$(state_get T2 status)" "T2 status"
    assert_file_absent "$PROJ/.agents/workflow/runs/T2-1/done" "child not started"
}

t_on_main() {
    setup "T1:pending" "T2:pending"
    git -C "$PROJ" switch -q main
    run_script dispatch-start.sh T1
    assert_eq 12 "$CODE" "exit code: $ERR"
    assert_eq "Next: switch-branch reason=main" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_eq pending "$(state_get T1 status)" "T1 status"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/done" "child not started"
}

t_done_task() {
    setup "T1:done" "T2:pending"
    run_script dispatch-start.sh T1
    assert_eq 21 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=task-status" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_eq done "$(state_get T1 status)" "T1 status"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/done" "child not started"
}

echo "test-dispatch-start.sh"
test_case "start: 起動して prompt.md・in_progress・done ができる" t_start_ok
test_case "start: 作業ツリーが汚れていれば exit 20" t_dirty_tree
test_case "start: 依存が未完了なら exit 42" t_dep_incomplete
test_case "start: main 上なら exit 12" t_on_main
test_case "start: done のタスクは exit 21" t_done_task
summary
