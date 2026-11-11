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

# runs/T1-1/done が現れるまで最大120秒待つ(0.5秒ごと)
wait_done() {
    local i
    for i in $(seq 1 240); do
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
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/done" "done within 120s"
}

t_start_guard_ready() {
    setup "T1:pending" "T2:pending"
    run_script dispatch-start.sh T1
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/guard.sha256" "guard.sha256 on return"
    wait_done T1-1
}

t_start_launch_fail() {
    setup "T1:pending" "T2:pending"
    rm "$PROJ/.agents/workflow/scripts/dispatch-run.sh"
    DISPATCH_START_LAUNCH_TIMEOUT=2 run_script dispatch-start.sh T1
    assert_eq 60 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=launch" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
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

t_retry_dirty_with_notes() {
    setup "T1:in_progress" "T2:pending"
    printf 'x\n' > "$PROJ/x.txt"
    mkdir -p "$PROJ/.agents/workflow/runs/T1-2"
    printf 'fix\n' > "$PROJ/.agents/workflow/runs/T1-2/fix-notes.md"
    run_script dispatch-start.sh T1 2
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: wait" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    wait_done T1-2
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-2/done" "done within 120s"
    assert_eq in_progress "$(state_get T1 status)" "T1 status"
}

t_retry_dirty_no_notes() {
    setup "T1:in_progress" "T2:pending"
    printf 'x\n' > "$PROJ/x.txt"
    run_script dispatch-start.sh T1 2
    assert_eq 20 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=dirty-tree" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-2/done" "child not started"
}

t_attempt_zero() {
    setup "T1:pending" "T2:pending"
    run_script dispatch-start.sh T1 0
    assert_eq 1 "$CODE" "exit code: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-0/done" "child not started"
}

t_retry_dirty_no_notes_msg() {
    setup "T1:in_progress" "T2:pending"
    printf 'x\n' > "$PROJ/x.txt"
    run_script dispatch-start.sh T1 2
    assert_eq 20 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "fix-notes.md not found" "stderr"
}

set_child_cfg() { # $1=キー $2=値
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

# review 節を設定する($1=mode $2=command_template $3=subagent $4=subagent_model)
set_review_cfg() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" "$2" "${3:-}" "${4:-}" <<'PY'
import json, sys
p, mode, tmpl, sub, model = sys.argv[1:6]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
review = {'mode': mode, 'command_template': tmpl}
if sub:
    review['subagent'] = sub
if model:
    review['subagent_model'] = model
cfg['review'] = review
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# レビューの run を起動できる状態にする(T1 を in_review にし、review 節と report.md を用意する)
setup_review() {
    setup "T1:in_review" "T2:pending"
    printf '#!/bin/bash\necho review\n' > "$PROJ/.agents/review-child.sh"
    set_review_cfg dispatch 'bash ./.agents/review-child.sh "{prompt}"'
    write_report T1 1
}

t_review_ok() {
    setup_review
    printf 'x\n' > "$PROJ/x.txt"
    run_script dispatch-start.sh --review T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Run: review-T1-1" "Run line"
    assert_eq "Next: wait" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_file_exists "$PROJ/.agents/workflow/runs/review-T1-1/guard.sha256" "guard.sha256 on return"
    assert_eq in_review "$(state_get T1 status)" "T1 status"
    wait_done review-T1-1
    assert_file_exists "$PROJ/.agents/workflow/runs/review-T1-1/done" "done within 120s"
}

t_review_mode_absent() {
    setup "T1:in_review" "T2:pending"
    run_script dispatch-start.sh --review T1
    assert_eq 23 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "review.mode" "stderr"
    assert_eq "Next: escalate reason=review-mode" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_file_absent "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md" "no prompt"
}

t_review_mode_not_dispatch() {
    setup "T1:in_review" "T2:pending"
    set_review_cfg manual 'bash ./.agents/review-child.sh "{prompt}"'
    run_script dispatch-start.sh --review T1
    assert_eq 23 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "review.mode" "stderr"
    assert_eq "Next: escalate reason=review-mode" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_file_absent "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md" "no prompt"
}

t_review_not_in_review() {
    setup "T1:pending" "T2:pending"
    set_review_cfg dispatch 'bash ./.agents/child.sh "{prompt}"'
    run_script dispatch-start.sh --review T1
    assert_eq 21 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=task-status" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
}

t_review_config_missing_template() {
    setup "T1:in_review" "T2:pending"
    set_review_cfg dispatch ''
    write_report T1 1
    run_script dispatch-start.sh --review T1
    assert_eq 24 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=review-config" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_file_absent "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md" "no prompt"
}

t_review_attempt_from_retries() {
    setup "T1:in_review:2" "T2:pending"
    set_review_cfg dispatch 'bash ./.agents/child.sh "{prompt}"'
    write_report T1 3
    run_script dispatch-start.sh --review T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Run: review-T1-3" "Run line"
    wait_done review-T1-3
}

t_review_subagent_model() {
    setup "T1:in_review" "T2:pending"
    set_review_cfg dispatch '' always opus
    write_report T1 1
    run_script dispatch-start.sh --review T1 --subagent-capable
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Launcher: subagent" "Launcher line"
    assert_contains "$OUT" "Model: opus" "Model line"
    assert_eq "Next: subagent review-T1 1" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    assert_file_absent "$PROJ/.agents/workflow/runs/review-T1-1/done" "child not started"
}

t_healthcheck_fail() {
    setup "T1:pending" "T2:pending"
    set_child_cfg healthcheck_command 'exit 3'
    run_script dispatch-start.sh T1
    assert_eq 30 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=healthcheck" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_eq pending "$(state_get T1 status)" "T1 status"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/done" "child not started"
}

t_warmup_once() {
    setup "T1:pending" "T2:pending"
    set_child_cfg warmup_command 'echo w >> .agents/warmup.log'
    run_script dispatch-start.sh T1
    assert_eq 0 "$CODE" "exit code (T1): $ERR"
    wait_done T1-1
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/done" "T1 done"
    printf '## 完了報告
- 変更ファイル: なし
' > "$PROJ/.agents/workflow/runs/T1-1/report.md"
    write_state "T1:done" "T2:pending"
    set_state_branch develop/t
    run_script dispatch-start.sh T2
    assert_eq 0 "$CODE" "exit code (T2): $ERR"
    wait_done T2-1
    assert_file_exists "$PROJ/.agents/workflow/runs/T2-1/done" "T2 done"
    assert_eq 1 "$(wc -l < "$PROJ/.agents/warmup.log" | tr -d ' ')" "warmup.log lines"
}

t_warmup_after_subagent() {
    setup "T1:pending" "T2:pending"
    set_child_cfg warmup_command 'echo w >> .agents/warmup.log'
    set_child_cfg subagent always
    run_script dispatch-start.sh T1 --subagent-capable
    assert_eq 0 "$CODE" "exit code (T1): $ERR"
    assert_contains "$OUT" "Launcher: subagent" "Launcher line (T1)"
    assert_file_absent "$PROJ/.agents/warmup.log" "no warmup for subagent run"
    printf '## 完了報告
- 変更ファイル: なし
' > "$PROJ/.agents/workflow/runs/T1-1/report.md"
    write_state "T1:done" "T2:pending"
    set_state_branch develop/t
    set_child_cfg subagent never
    run_script dispatch-start.sh T2
    assert_eq 0 "$CODE" "exit code (T2): $ERR"
    wait_done T2-1
    assert_file_exists "$PROJ/.agents/workflow/runs/T2-1/done" "T2 done"
    assert_file_exists "$PROJ/.agents/warmup.log" "warmup.log"
    assert_eq 1 "$(wc -l < "$PROJ/.agents/warmup.log" | tr -d ' ')" "warmup.log lines"
}

t_warmup_fail() {
    setup "T1:pending" "T2:pending"
    set_child_cfg warmup_command 'exit 1'
    run_script dispatch-start.sh T1
    assert_eq 31 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=warmup" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_eq pending "$(state_get T1 status)" "T1 status"
}

# --pr 用: origin(bare)付きで develop/t に1コミットし、T1 を done(commit=そのハッシュ)にする
setup_pr() {
    setup "T1:pending" "T2:pending"
    (
        cd "$PROJ"
        git switch -q main
        git init -q --bare -b main .agents/remote.git
        git remote add origin .agents/remote.git
        git push -q -u origin main
        git switch -q develop/t
        printf 'b\n' > b.txt; git add b.txt; git commit -q -m "feat: t1"
    )
    local h
    h="$(git -C "$PROJ" rev-parse --short HEAD)"
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$h" <<'PY'
import json, sys
p, h = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
for t in s['tasks']:
    if t['id'] == 'T1':
        t['status'] = 'done'
        t['commit'] = h
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

t_pr_ok() {
    setup_pr
    run_script dispatch-start.sh --pr
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Run: pr-" "Run line"
    assert_eq "Next: wait" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    local run
    run="$(printf '%s\n' "$OUT" | sed -n 's/^Run: //p' | tr -d '\r')"
    wait_done "$run"
    assert_file_exists "$PROJ/.agents/workflow/runs/$run/done" "done within 120s"
}

t_pr_on_main() {
    setup "T1:done" "T2:pending"
    git -C "$PROJ" switch -q main
    run_script dispatch-start.sh --pr
    assert_eq 12 "$CODE" "exit code: $ERR"
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

t_parallel_dirty_ok() {
    setup "T1:pending" "T2:pending"
    set_max_parallel 2
    printf 'x
' > "$PROJ/x.txt"
    run_script dispatch-start.sh T1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: wait" "$(printf '%s
' "$OUT" | tail -1)" "last line"
    assert_contains "$OUT" "Worktree:" "Worktree line"
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/worktree.txt" "worktree.txt"
    assert_eq in_progress "$(state_get T1 status)" "T1 status"
    wait_done T1-1
}

t_parallel_worktree_exists() {
    setup "T1:pending" "T2:pending"
    set_max_parallel 2
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1/worktree"
    run_script dispatch-start.sh T1
    assert_eq 61 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=worktree" "$(printf '%s
' "$OUT" | tail -1)" "last line"
    assert_eq pending "$(state_get T1 status)" "T1 status"
}

t_parallel_healthcheck_cleanup() {
    setup "T1:pending" "T2:pending"
    set_max_parallel 2
    set_child_cfg healthcheck_command 'false'
    run_script dispatch-start.sh T1
    assert_eq 30 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=healthcheck" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/worktree" "worktree が残らない"
    assert_eq 0 "$(git -C "$PROJ" rev-parse --verify -q refs/heads/agents-run/T1-1 > /dev/null && echo 1 || echo 0)" "ブランチが残らない"

    set_child_cfg healthcheck_command ''
    run_script dispatch-start.sh T1
    assert_eq 0 "$CODE" "healthcheck を外すと同じ試行で起動できる: $ERR"
    wait_done T1-1
}

t_subagent_always() {
    setup "T1:pending" "T2:pending"
    set_child_cfg subagent always
    set_child_cfg subagent_model sonnet
    run_script dispatch-start.sh T1 --subagent-capable
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Launcher: subagent" "Launcher line"
    assert_contains "$OUT" "Model: sonnet" "Model line"
    local root_abs
    root_abs="$(py_path "$PROJ")"
    assert_eq "$root_abs/.agents/workflow/runs/T1-1/prompt.md" "$(printf '%s\n' "$OUT" | sed -n 's/^Prompt: //p' | tr -d '\r')" "Prompt line"
    assert_eq "$root_abs" "$(printf '%s\n' "$OUT" | sed -n 's/^Workdir: //p' | tr -d '\r')" "Workdir line"
    assert_eq "$root_abs/.agents/workflow/runs/T1-1/output.log" "$(printf '%s\n' "$OUT" | sed -n 's/^Output: //p' | tr -d '\r')" "Output line"
    assert_eq "Next: subagent T1 1" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    assert_not_contains "$OUT" "Watch all:" "no Watch all"
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/guard.sha256" "guard.sha256"
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/git-state.txt" "git-state.txt"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/done" "child not started"
}

t_subagent_auto_opencode_cli() {
    setup "T1:pending" "T2:pending"
    set_child_cfg profile opencode
    set_child_cfg subagent auto
    run_script dispatch-start.sh T1 --subagent-capable
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Launcher: cli" "Launcher line"
    assert_eq "Next: wait" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    wait_done T1-1
}

t_subagent_never_stream_json_cli() {
    setup "T1:pending" "T2:pending"
    set_child_cfg profile claude-stream-json
    set_child_cfg subagent never
    run_script dispatch-start.sh T1 --subagent-capable
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Launcher: cli" "Launcher line"
    assert_eq "Next: wait" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    wait_done T1-1
}

t_pr_subagent_section() {
    setup_pr
    set_child_cfg subagent always
    run_script dispatch-start.sh --pr --subagent-capable
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Launcher: subagent" "Launcher line"
    assert_eq "Next: subagent pr-1 1" "$(printf '%s\n' "$OUT" | tail -1 | tr -d '\r')" "last line"
    assert_eq subagent "$(cat "$PROJ/.agents/workflow/runs/pr-1-1/launcher")" "launcher"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/pr-1-1/prompt.md")" "## サブエージェントとして実行する場合の追加の指示" "subagent section in PR prompt"
    assert_file_absent "$PROJ/.agents/workflow/runs/pr-1-1/done" "child not started"
}

echo "test-dispatch-start.sh"
test_case "start: 起動して prompt.md・in_progress・done ができる" t_start_ok
test_case "start: 戻った時点で guard.sha256 がある" t_start_guard_ready
test_case "start: dispatch-run が起動しなければ exit 60" t_start_launch_fail
test_case "start: 作業ツリーが汚れていれば exit 20" t_dirty_tree
test_case "start: 依存が未完了なら exit 42" t_dep_incomplete
test_case "start: main 上なら exit 12" t_on_main
test_case "start: done のタスクは exit 21" t_done_task
test_case "start: リトライ(fix-notes あり)は作業ツリーが汚れていても起動する" t_retry_dirty_with_notes
test_case "start: リトライでも fix-notes が無ければ exit 20" t_retry_dirty_no_notes
test_case "start: 試行回数 0 は exit 1" t_attempt_zero
test_case "start: リトライで fix-notes が無ければ stderr に案内を出す" t_retry_dirty_no_notes_msg
test_case "start: healthcheck_command が失敗すれば exit 30" t_healthcheck_fail
test_case "start: warmup_command は最初の dispatch だけ実行する" t_warmup_once
test_case "start: サブエージェントの run の後の最初の CLI の run でウォームアップする" t_warmup_after_subagent
test_case "start: warmup_command が失敗すれば exit 31" t_warmup_fail
test_case "start: --pr は pr-<N> の run を起動する" t_pr_ok
test_case "start: --pr で main 上なら exit 12" t_pr_on_main
test_case "start: max_parallel 2 は未コミットの変更があっても worktree の run を起動する" t_parallel_dirty_ok
test_case "start: max_parallel 2 で worktree が既にあれば exit 61" t_parallel_worktree_exists
test_case "start: max_parallel 2 で healthcheck が失敗すると exit 30 で worktree・ブランチが残らない" t_parallel_healthcheck_cleanup
test_case "start: subagent always + --subagent-capable は子を起動せず subagent で準備する" t_subagent_always
test_case "start: subagent auto + opencode プロファイルは --subagent-capable があっても cli" t_subagent_auto_opencode_cli
test_case "start: subagent never + claude-stream-json プロファイルは --subagent-capable があっても cli" t_subagent_never_stream_json_cli
test_case "start: --pr --subagent-capable は pr の prompt.md にサブエージェント用の節を足す" t_pr_subagent_section
test_case "start: review の run を起動する" t_review_ok
test_case "start: review.mode が dispatch でなければ起動しない" t_review_mode_not_dispatch
test_case "start: review.mode が無ければ exit 23" t_review_mode_absent
test_case "start: --review でタスクが in_review でなければ exit 21" t_review_not_in_review
test_case "start: review.command_template が空なら起動しない" t_review_config_missing_template
test_case "start: --review の Attempt 省略時は retries + 1" t_review_attempt_from_retries
test_case "start: review の run をサブエージェントで起動する" t_review_subagent_model
summary
