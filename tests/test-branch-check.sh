#!/bin/bash
# #32: branch-check(作業ブランチが使ってよいかの判定, POSIX版)。
# gh は lib.sh が PATH 先頭に置くスタブで差し替え、判定ごとの exit code と stdout、
# --state の判定が gh より先に行われること、何も書き換えないことを検証する。
source "$(dirname "$0")/lib.sh"

# --- gh スタブ(lib.sh が PATH 先頭に置く。シナリオごとに gh_stub_set で挙動を設定する) ---
# gh_stub <NONE|NO_PR_MESSAGE|MERGED|FAIL> [url]
gh_stub() {
    case "$1" in
        # 実 gh は一致する PR が無いとき [] を出力して exit 0
        NONE) gh_stub_set 0 '[]' '' ;;
        # 古い gh の「PR が見つからない」失敗(PR なしとして扱う)
        NO_PR_MESSAGE) gh_stub_set 1 '' 'no pull requests found for branch "develop/g1"' ;;
        MERGED) gh_stub_set 0 "[{\"url\":\"$2\"}]" '' ;;
        FAIL) gh_stub_set 4 '' 'HTTP 401: Bad credentials' ;;
    esac
}

# 作業ブランチ develop/g1 に切り替え、state.json の branch を develop/g1 にする
setup_work_branch() {
    (cd "$PROJ" && git checkout -q -b develop/g1)
    write_state "T1:pending"
    set_state_branch develop/g1
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

# 作業ツリー・state.json の状態(実行前後で一致することを確かめる)
snapshot() {
    (cd "$PROJ" && git status --porcelain && git branch --show-current)
    cat "$PROJ/.agents/workflow/state.json" 2> /dev/null
}

t_main_rejected() {
    gh_stub NONE
    run_script branch-check.sh
    assert_eq 2 "$CODE" "exit code: $ERR"
    assert_eq "Next: switch-branch reason=main" "$OUT" "stdout has only the Next: line"
    assert_contains "$ERR" "main" "stderr explains"
    assert_eq "" "$(gh_stub_log)" "gh not called"
}

t_base_branch_rejected() {
    (cd "$PROJ" && git checkout -q -b trunk)
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['base_branch'] = 'trunk'
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
PY
    gh_stub NONE
    run_script branch-check.sh
    assert_eq 2 "$CODE" "base_branch is treated as main: $ERR"
}

t_upstream_branch_allowed() {
    (cd "$PROJ" && git checkout -q -b dist)
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['upstream'] = {'url': 'https://github.com/example/repo.git', 'branch': 'dist'}
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
PY
    gh_stub NONE
    run_script branch-check.sh
    assert_eq 0 "$CODE" "upstream.branch is not forbidden: $ERR"
    assert_eq "OK dist" "${OUT%%$'\n'*}" "stdout"
}

t_merged() {
    setup_work_branch
    gh_stub MERGED "https://example.com/pr/1"
    local before
    before="$(snapshot)"
    run_script branch-check.sh
    assert_eq 3 "$CODE" "exit code: $ERR"
    assert_eq "MERGED https://example.com/pr/1" "${OUT%%$'\n'*}" "stdout has the PR URL"
    assert_eq "Next: switch-branch reason=merged" "${OUT##*$'\n'}" "last line is the Next: line"
    assert_contains "$(gh_stub_log)" "pr list --head develop/g1 --state merged" "gh asked for merged PRs of the branch"
    assert_eq "$before" "$(snapshot)" "nothing changed"
}

t_no_pr() {
    setup_work_branch
    gh_stub NONE
    local before
    before="$(snapshot)"
    run_script branch-check.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "OK develop/g1" "${OUT%%$'\n'*}" "stdout"
    assert_eq "Next: continue" "${OUT##*$'\n'}" "last line is the Next: line"
    assert_eq "$before" "$(snapshot)" "nothing changed"
}

t_no_pr_message() {
    setup_work_branch
    gh_stub NO_PR_MESSAGE
    run_script branch-check.sh
    assert_eq 0 "$CODE" "'no pull requests found' failure is treated as no PR: $ERR"
    assert_eq "OK develop/g1" "${OUT%%$'\n'*}" "stdout"
}

t_open_only() {
    # OPEN の PR しか無いブランチでは、--state merged の結果は空になる
    setup_work_branch
    gh_stub NONE
    run_script branch-check.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$(gh_stub_log)" "--state merged" "only merged PRs are asked for"
}

t_gh_failure() {
    setup_work_branch
    gh_stub FAIL
    run_script branch-check.sh
    assert_eq 4 "$CODE" "exit code"
    assert_eq "Next: escalate reason=gh-unavailable" "$OUT" "stdout has only the Next: line"
    assert_contains "$ERR" "Bad credentials" "stderr includes gh's message"
}

t_gh_invalid_output() {
    setup_work_branch
    gh_stub NONE
    GH_STUB_STDOUT='not json'
    run_script branch-check.sh
    assert_eq 4 "$CODE" "unparsable gh output: $ERR"
}

t_state_mismatch() {
    setup_work_branch
    set_state_branch develop/other
    gh_stub MERGED "https://example.com/pr/1"
    run_script branch-check.sh --state
    assert_eq 5 "$CODE" "exit code: $ERR"
    assert_eq "Next: escalate reason=state-branch-mismatch" "${OUT##*$'\n'}" "last line is the Next: line"
    assert_contains "$ERR" "develop/g1" "stderr shows the current branch"
    assert_contains "$ERR" "develop/other" "stderr shows the state branch"
    assert_eq "" "$(gh_stub_log)" "gh not called"
}

t_state_match() {
    setup_work_branch
    gh_stub NONE
    run_script branch-check.sh --state
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "OK develop/g1" "${OUT%%$'\n'*}" "stdout"
}

t_state_ignored_without_flag() {
    setup_work_branch
    set_state_branch develop/other
    gh_stub NONE
    run_script branch-check.sh
    assert_eq 0 "$CODE" "state.json is not checked without --state: $ERR"
}

t_state_file_absent() {
    (cd "$PROJ" && git checkout -q -b develop/g1)
    rm -f "$PROJ/.agents/workflow/state.json"
    gh_stub NONE
    run_script branch-check.sh --state
    assert_eq 0 "$CODE" "missing state.json skips the check: $ERR"
    assert_eq "OK develop/g1" "${OUT%%$'\n'*}" "stdout"
}

t_main_before_state() {
    # main 上では state.json と不一致でも exit 2(判定順 2 が 3 より先)
    write_state "T1:pending"
    set_state_branch develop/other
    gh_stub NONE
    run_script branch-check.sh --state
    assert_eq 2 "$CODE" "main is checked first: $ERR"
}

t_detached_head() {
    (cd "$PROJ" && git checkout -q --detach)
    gh_stub NONE
    run_script branch-check.sh
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "detached" "stderr explains"
}

t_unknown_argument() {
    gh_stub NONE
    run_script branch-check.sh --bogus
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "Usage" "usage shown"
    assert_eq "" "$(gh_stub_log)" "gh not called"
}

echo "test-branch-check.sh"
test_case "branch-check: main 上は exit 2" t_main_rejected
test_case "branch-check: config の base_branch 上も exit 2" t_base_branch_rejected
test_case "branch-check: upstream.branch の名前は禁止しない" t_upstream_branch_allowed
test_case "branch-check: マージ済み PR ありは exit 3 と MERGED <URL>" t_merged
test_case "branch-check: PR なし([])は exit 0 と OK <branch>" t_no_pr
test_case "branch-check: gh の「no pull requests found」失敗も PR なし扱い" t_no_pr_message
test_case "branch-check: OPEN の PR のみは exit 0" t_open_only
test_case "branch-check: gh 失敗は exit 4" t_gh_failure
test_case "branch-check: gh の出力が解析できなければ exit 4" t_gh_invalid_output
test_case "branch-check: --state で state.json と不一致は exit 5(gh を呼ばない)" t_state_mismatch
test_case "branch-check: --state で一致すれば exit 0" t_state_match
test_case "branch-check: --state なしでは state.json を見ない" t_state_ignored_without_flag
test_case "branch-check: state.json 無しは --state でも判定を飛ばす" t_state_file_absent
test_case "branch-check: main の判定は state.json の判定より先" t_main_before_state
test_case "branch-check: detached HEAD は exit 1" t_detached_head
test_case "branch-check: 不明な引数は exit 1" t_unknown_argument
summary
