#!/bin/bash
# #58: task-commit(本体コミット・状態更新・状態ファイルのコミット, POSIX版)。
# gh は lib.sh のスタブで差し替え、コミットの内容・state.json の更新・失敗時に何も変わらないことを検証する。
source "$(dirname "$0")/lib.sh"

# 作業ブランチ develop/t に切り替え、state.json の T1 を in_review・branch を develop/t にする
setup_review() {
    (cd "$PROJ" && git checkout -q -b develop/t)
    write_state "T1:in_review"
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
s['branch'] = 'develop/t'
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
    gh_stub_set 0 '[]' ''
}

commit_count() {
    git -C "$PROJ" rev-list --count HEAD
}

t_commit() {
    setup_review
    echo a > "$PROJ/a.txt"
    run_script task-commit.sh T1 feat "説明"
    assert_eq 0 "$CODE" "exit code: $ERR"
    local msg head
    msg="$(git -C "$PROJ" log -1 --format=%B)"
    head="$(git -C "$PROJ" rev-parse HEAD)"
    assert_contains "$msg" "feat: 説明" "subject"
    assert_contains "$msg" "Task: T1 (test)" "task trailer"
    assert_eq "done" "$(state_get T1 status)" "T1 is done"
    assert_eq "$head" "$(state_get T1 commit)" "commit hash recorded"
    assert_eq "Next: continue" "${OUT##*$'\n'}" "last line is the Next: line"
}

t_untracked_agents() {
    setup_review
    echo a > "$PROJ/a.txt"
    local before
    before="$(commit_count)"
    run_script task-commit.sh T1 fix "説明"
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "State commit: none" "no state commit"
    assert_eq "$((before + 1))" "$(commit_count)" "only the body commit was added"
}

t_tracked_state() {
    (cd "$PROJ" && printf '.agents/workflow/runs/\n' > .gitignore)
    setup_review
    write_tasks <<'EOF'
## T1: test
EOF
    (cd "$PROJ" && git add .gitignore .agents/workflow/state.json .agents/workflow/tasks.md && git commit -q -m "chore: state")
    echo a > "$PROJ/a.txt"
    run_script task-commit.sh T1 feat "説明"
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "chore: T1 の進捗状態を更新" "$(git -C "$PROJ" log -1 --format=%s)" "state commit subject"
    assert_contains "$(git -C "$PROJ" show --name-only --format= HEAD)" ".agents/workflow/state.json" "state.json in state commit"
    assert_eq "feat: 説明" "$(git -C "$PROJ" log -1 --format=%s HEAD~1)" "body commit before it"
    assert_not_contains "$(git -C "$PROJ" show --name-only --format= HEAD~1)" ".agents/" "body commit has no .agents"
    assert_not_contains "$OUT" "State commit: none" "state commit reported"
}

t_no_changes() {
    setup_review
    local before_state before_head
    before_state="$(cat "$PROJ/.agents/workflow/state.json")"
    before_head="$(git -C "$PROJ" rev-parse HEAD)"
    run_script task-commit.sh T1 feat "説明"
    assert_eq 20 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=no-changes" "${OUT##*$'\n'}" "last line is the Next: line"
    assert_eq "in_review" "$(state_get T1 status)" "T1 stays in_review"
    assert_eq "$before_state" "$(cat "$PROJ/.agents/workflow/state.json")" "state.json unchanged"
    assert_eq "$before_head" "$(git -C "$PROJ" rev-parse HEAD)" "HEAD unchanged"
}

t_main_rejected() {
    write_state "T1:in_review"
    gh_stub_set 0 '[]' ''
    echo a > "$PROJ/a.txt"
    local before_state before_head
    before_state="$(cat "$PROJ/.agents/workflow/state.json")"
    before_head="$(git -C "$PROJ" rev-parse HEAD)"
    run_script task-commit.sh T1 feat "説明"
    assert_eq 12 "$CODE" "exit code: $ERR"
    assert_eq "in_review" "$(state_get T1 status)" "T1 stays in_review"
    assert_eq "$before_state" "$(cat "$PROJ/.agents/workflow/state.json")" "state.json unchanged"
    assert_eq "$before_head" "$(git -C "$PROJ" rev-parse HEAD)" "HEAD unchanged"
}

echo "test-task-commit.sh"
test_case "commit: 本体をコミットし done とハッシュを記録する" t_commit
test_case "commit: .agents を追跡しないリポジトリでは状態コミットをしない" t_untracked_agents
test_case "commit: 状態ファイルを追跡するリポジトリでは chore コミットを作る" t_tracked_state
test_case "commit: 変更が無ければ exit 20" t_no_changes
test_case "commit: main 上なら exit 12 でコミットしない" t_main_rejected
summary
