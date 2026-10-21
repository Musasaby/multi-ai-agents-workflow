#!/bin/bash
# workflow-archive(workflow 状態のアーカイブ移動, POSIX版)
source "$(dirname "$0")/lib.sh"

# "Archived: <dir> (<names>)" から <dir> を取り出す
archive_dir_of() {
    local rest="${OUT#"Archived: "}"
    echo "${rest%% (*}"
}

t_all_targets() {
    write_tasks "# tasks"
    write_state "T1:done"
    mkdir -p "$PROJ/.agents/workflow/runs/T0-1" "$PROJ/.agents/workflow/comprehension"
    printf 'r\n' > "$PROJ/.agents/workflow/runs/T0-1/report.md"
    printf 'q\n' > "$PROJ/.agents/workflow/comprehension/questions.md"
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    local dir
    dir="$(archive_dir_of)"
    assert_contains "$OUT" "(tasks.md, state.json, runs, comprehension)" "output lists all targets"
    assert_file_exists "$dir/tasks.md" "tasks.md moved"
    assert_file_exists "$dir/state.json" "state.json moved"
    assert_file_exists "$dir/runs/T0-1/report.md" "runs moved"
    assert_file_exists "$dir/comprehension/questions.md" "comprehension moved"
    assert_file_absent "$PROJ/.agents/workflow/tasks.md" "tasks.md removed from workflow dir"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json removed from workflow dir"
}

t_partial_targets() {
    write_state "T1:done"
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    local dir
    dir="$(archive_dir_of)"
    assert_contains "$OUT" "(state.json, runs)" "output lists state.json and runs"
    assert_not_contains "$OUT" "tasks.md" "output lists only existing targets"
    assert_file_exists "$dir/state.json" "state.json moved"
    assert_file_absent "$dir/tasks.md" "tasks.md untouched"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json removed from workflow dir"
}

t_slug_required() {
    write_state "T1:done"
    run_script workflow-archive.sh
    assert_eq 1 "$CODE" "no slug rejected"
    assert_contains "$ERR" "使い方" "usage message"
    assert_file_exists "$PROJ/.agents/workflow/state.json" "nothing moved"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

t_slug_with_path_chars() {
    write_state "T1:done"
    local slug
    for slug in "a/b" 'a\b' "a..b" ".."; do
        run_script workflow-archive.sh "$slug"
        assert_eq 1 "$CODE" "slug '$slug' rejected"
        assert_file_exists "$PROJ/.agents/workflow/state.json" "nothing moved for '$slug'"
        assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created for '$slug'"
    done
}

t_no_targets() {
    mkdir -p "$PROJ/.agents/workflow"
    rm -rf "$PROJ/.agents/workflow/runs"
    run_script workflow-archive.sh myslug
    assert_eq 1 "$CODE" "no targets rejected"
    assert_contains "$ERR" "移動対象がありません" "message"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
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

setup_branch_state() {
    write_tasks "# tasks"
    write_state "T1:done"
    set_state_branch develop/x
}

last_line() {
    printf '%s\n' "$1" | tail -n 1
}

t_pr_open() {
    setup_branch_state
    gh_stub_set 0 '{"state":"OPEN","url":"https://example.com/pr/1"}' ''
    run_script workflow-archive.sh myslug
    assert_eq 2 "$CODE" "exit: $ERR"
    assert_eq "OPEN https://example.com/pr/1" "$(printf '%s\n' "$OUT" | head -n 1)" "first line"
    assert_eq "Next: escalate reason=pr-open" "$(last_line "$OUT")" "Next line"
    assert_file_exists "$PROJ/.agents/workflow/state.json" "state.json kept"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

t_pr_closed() {
    setup_branch_state
    gh_stub_set 0 '{"state":"CLOSED","url":"https://example.com/pr/1"}' ''
    run_script workflow-archive.sh myslug
    assert_eq 3 "$CODE" "exit: $ERR"
    assert_eq "Next: escalate reason=pr-closed" "$(last_line "$OUT")" "Next line"
    assert_file_exists "$PROJ/.agents/workflow/state.json" "state.json kept"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

t_gh_failure() {
    setup_branch_state
    gh_stub_set 1 '' 'gh stub failure'
    run_script workflow-archive.sh myslug
    assert_eq 4 "$CODE" "exit: $ERR"
    assert_eq "Next: escalate reason=gh-unavailable" "$(last_line "$OUT")" "Next line"
    assert_file_exists "$PROJ/.agents/workflow/state.json" "state.json kept"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

t_pr_merged() {
    setup_branch_state
    gh_stub_set 0 '{"state":"MERGED","url":"https://example.com/pr/1"}' ''
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json moved"
    assert_contains "$(gh_stub_log)" "pr view develop/x" "gh pr view called"
}

t_force() {
    setup_branch_state
    run_script workflow-archive.sh myslug --force
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "" "$(gh_stub_log)" "gh not called"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json moved"
}

t_no_pr_unmerged() {
    setup_branch_state
    gh_stub_set 1 '' 'no pull requests found for branch "develop/x"'
    (
        cd "$PROJ" || exit 1
        git checkout -q -b develop/x
        printf 'x\n' > x.txt
        git add x.txt
        git commit -q -m "feat: x"
    ) || exit 1
    run_script workflow-archive.sh myslug
    assert_eq 5 "$CODE" "exit: $ERR"
    assert_eq "NO_PR" "$(printf '%s\n' "$OUT" | head -n 1)" "first line"
    assert_eq "Next: escalate reason=pr-not-created" "$(last_line "$OUT")" "Next line"
    assert_contains "$ERR" "1 commit(s)" "stderr mentions commit count"
    assert_file_exists "$PROJ/.agents/workflow/state.json" "state.json kept"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

t_no_pr_no_new_commits() {
    setup_branch_state
    gh_stub_set 1 '' 'no pull requests found for branch "develop/x"'
    git -C "$PROJ" branch develop/x
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json moved"
}

t_no_pr_no_branch() {
    setup_branch_state
    gh_stub_set 1 '' 'no pull requests found for branch "develop/x"'
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json moved"
}

t_no_pr_base_branch() {
    setup_branch_state
    gh_stub_set 1 '' 'no pull requests found for branch "develop/x"'
    (
        cd "$PROJ" || exit 1
        git checkout -q -b develop/x
        printf 'x\n' > x.txt
        git add x.txt
        git commit -q -m "feat: x"
        git branch trunk develop/x
    ) || exit 1
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['base_branch'] = 'trunk'
c['upstream'] = {'url': 'https://github.com/example/repo.git', 'branch': 'dist'}
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
PY
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json moved"
}

echo "test-workflow-archive.sh"
test_case "全対象の移動と Archived: の出力" t_all_targets
test_case "一部の対象だけ移動" t_partial_targets
test_case "スラッグなしは exit 1" t_slug_required
test_case "パス区切り・.. を含むスラッグは exit 1" t_slug_with_path_chars
test_case "移動対象なしは exit 1" t_no_targets
test_case "PR が OPEN なら exit 2 で何も移動しない" t_pr_open
test_case "PR が CLOSED なら exit 3" t_pr_closed
test_case "gh が失敗したら exit 4" t_gh_failure
test_case "PR が MERGED ならアーカイブする" t_pr_merged
test_case "--force なら PR を確かめずにアーカイブする" t_force
test_case "PR 未作成で未マージのコミットがあれば exit 5" t_no_pr_unmerged
test_case "PR 未作成で未マージのコミットが無ければアーカイブする" t_no_pr_no_new_commits
test_case "PR 未作成でブランチが無ければアーカイブする" t_no_pr_no_branch
test_case "PR 未作成のとき比較先は base_branch" t_no_pr_base_branch
summary
