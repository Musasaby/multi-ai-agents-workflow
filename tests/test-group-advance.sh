#!/bin/bash
# T3: group-advance(グループ完了後の PR 状態判定とブランチ切替, POSIX版)。
# gh は lib.sh が PATH 先頭に置くスタブで差し替え、PR 状態(NO_PR / OPEN / CLOSED / MERGED)ごとの
# exit code と、MERGED 時のブランチ作成・切替・state.json 更新を検証する。
source "$(dirname "$0")/lib.sh"

# --- gh スタブ(lib.sh が PATH 先頭に置く。シナリオごとに gh_stub_set で挙動を設定する) ---
# gh_stub <NO_PR|OPEN|CLOSED|MERGED|FAIL> [url] [code]
gh_stub() {
    case "$1" in
        NO_PR)
            # 実 gh と同じ「PR が見つからない」メッセージと exit 1 を再現する
            gh_stub_set 1 '' 'no pull requests found for branch "develop/g1"'
            ;;
        OPEN)   gh_stub_set 0 "{\"state\":\"OPEN\",\"url\":\"$2\"}" '' ;;
        CLOSED) gh_stub_set 0 "{\"state\":\"CLOSED\",\"url\":\"$2\"}" '' ;;
        MERGED) gh_stub_set 0 "{\"state\":\"MERGED\",\"url\":\"$2\"}" '' ;;
        FAIL)   gh_stub_set "$3" '' 'gh stub failure' ;;
    esac
}

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

# origin(bare)付きのリポジトリに develop/g1 ブランチを用意し、
# state.json を「作業グループ P が完了・ブランチ develop/g1」に揃える
setup_advance() {
    # テストケースが作ったダミープロジェクト($PROJ)をそのまま使う(作り直さない)
    (
        cd "$PROJ"
        git init -q --bare -b main .agents/remote.git
        git remote add origin .agents/remote.git
        printf 'a\n' > a.txt; git add a.txt; git commit -q -m "init main"
        git push -q -u origin main
        git checkout -q -b develop/g1
        printf 'b\n' > b.txt; git add b.txt; git commit -q -m "feat: g1"
        git push -q -u origin develop/g1
    )
    p_a_tasks
    write_state "T1:done" "T2:pending" "T3:pending"
    set_state_group P
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

state_branch() {
    python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    print(json.load(f).get('branch', ''))
" "$(py_path "$PROJ/.agents/workflow/state.json")"
}

t_advance_no_pr() {
    setup_advance
    gh_stub NO_PR
    run_script group-advance.sh
    assert_eq 7 "$CODE" "exit code: $ERR"
    assert_eq "NO_PR" "${OUT%%$'\n'*}" "stdout"
    assert_eq "Next: create-pr" "${OUT##*$'\n'}" "stdout last line"
    assert_contains "$(gh_stub_log)" "view develop/g1" "gh called with the state branch"
    assert_eq "develop/g1" "$(state_branch)" "state.json unchanged"
    assert_eq "P" "$(state_group)" "group unchanged"
}

t_advance_open() {
    setup_advance
    gh_stub OPEN "https://example.com/pr/1"
    run_script group-advance.sh
    assert_eq 8 "$CODE" "exit code: $ERR"
    assert_eq "OPEN https://example.com/pr/1" "${OUT%%$'\n'*}" "stdout has the PR URL"
    assert_eq "Next: wait-merge" "${OUT##*$'\n'}" "stdout last line"
    assert_eq "P" "$(state_group)" "group unchanged"
}

t_advance_open_unpushed() {
    setup_advance
    (cd "$PROJ" && printf 'c\n' > c.txt && git add c.txt && git commit -q -m "fix: review")
    gh_stub OPEN "https://example.com/pr/1"
    run_script group-advance.sh
    assert_eq 10 "$CODE" "exit code: $ERR"
    assert_eq "OPEN https://example.com/pr/1" "${OUT%%$'\n'*}" "stdout has the PR URL"
    assert_eq "Next: update-pr" "${OUT##*$'\n'}" "stdout last line"
    assert_contains "$ERR" "1 commit(s)" "stderr reports the unpushed commits"
    assert_eq "P" "$(state_group)" "group unchanged"
}

t_advance_open_no_remote_branch() {
    setup_advance
    (cd "$PROJ" && git update-ref -d refs/remotes/origin/develop/g1)
    gh_stub OPEN "https://example.com/pr/1"
    run_script group-advance.sh
    assert_eq 10 "$CODE" "exit code: $ERR"
    assert_eq "Next: update-pr" "${OUT##*$'\n'}" "stdout last line"
    assert_contains "$ERR" "not found" "stderr says the remote branch is missing"
}

t_advance_closed() {
    setup_advance
    gh_stub CLOSED "https://example.com/pr/1"
    run_script group-advance.sh
    assert_eq 9 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "CLOSED" "stderr explains the closed PR"
    assert_eq "Next: escalate reason=pr-closed" "${OUT##*$'\n'}" "stdout last line"
    assert_eq "P" "$(state_group)" "state.json unchanged"
}

t_advance_merged() {
    setup_advance
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop/g2
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "ADVANCED develop/g2 A" "${OUT%%$'\n'*}" "stdout shows the new branch and group"
    assert_eq "Next: continue" "${OUT##*$'\n'}" "stdout last line"
    assert_eq "develop/g2" "$(cd "$PROJ" && git branch --show-current)" "switched to the new branch"
    assert_eq "develop/g2" "$(state_branch)" "state.json branch updated"
    assert_eq "A" "$(state_group)" "state.json group updated to the next group"
}

t_advance_branch_dash_prefix() {
    setup_advance
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop-g2
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "develop-g2" "$(cd "$PROJ" && git branch --show-current)" "switched to the new branch"
    assert_eq "develop-g2" "$(state_branch)" "state.json branch updated"
}

t_advance_merged_base_branch() {
    setup_advance
    (
        cd "$PROJ"
        git branch release/v1 main
        git checkout -q release/v1
        printf 'r\n' > r.txt; git add r.txt; git commit -q -m "feat: release"
        git push -q -u origin release/v1
        git checkout -q develop/g1
    )
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['base_branch'] = 'release/v1'
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
PY
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop/g2
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "develop/g2" "$(cd "$PROJ" && git branch --show-current)" "switched to the new branch"
    assert_eq "$(cd "$PROJ" && git rev-parse release/v1)" "$(cd "$PROJ" && git rev-parse HEAD)" "branched from base_branch"
    assert_not_contains "$(cd "$PROJ" && git rev-parse main)" "$(cd "$PROJ" && git rev-parse HEAD)" "not branched from main"
}

t_advance_merged_commits_state() {
    setup_advance
    (
        cd "$PROJ"
        printf '.agents/remote.git/\n.agents/other-clone/\n.agents/workflow/scripts/\n.agents/workflow/config.json\n.agents/workflow/runs/\n' > .gitignore
        git add .gitignore .agents/workflow/state.json .agents/workflow/tasks.md
        git commit -q -m "track state"
        # PR マージ後の main を模す(切替後も state.json が main 側に存在するようにする)
        git checkout -q main
        git merge -q --ff-only develop/g1
        git push -q origin main
        git checkout -q develop/g1
    )
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop/g2
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "State commit: " "stdout has the state commit line"
    assert_eq "chore: A グループの作業を開始" "$(cd "$PROJ" && git log -1 --format=%s)" "latest commit on the new branch"
    assert_eq "develop/g2" "$(cd "$PROJ" && git branch --show-current)" "on the new branch"
    assert_eq "" "$(cd "$PROJ" && git status --porcelain)" "working tree is clean"
}

t_advance_merged_untracked_state_no_commit() {
    setup_advance
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop/g2
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "State commit: none" "no state commit"
}

t_advance_merged_pulls_main() {
    setup_advance
    # origin/main にだけあるコミットを用意し、ローカル main を古くしておく
    git clone -q "$PROJ/.agents/remote.git" "$PROJ/.agents/other-clone"
    (
        cd "$PROJ/.agents/other-clone"
        git config user.email "test@example.com"
        git config user.name "test"
        printf 'c\n' > c.txt; git add c.txt; git commit -q -m "on origin"
        git push -q origin main
    )
    local old_main bare_main new_main new_origin_main
    old_main="$(cd "$PROJ" && git rev-parse main)"
    bare_main="$(git --git-dir="$PROJ/.agents/remote.git" rev-parse main)"
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop/g2
    assert_eq 0 "$CODE" "exit code: $ERR"
    new_main="$(cd "$PROJ" && git rev-parse main)"
    new_origin_main="$(cd "$PROJ" && git rev-parse origin/main)"
    assert_eq "$bare_main" "$new_origin_main" "origin/main fast-forwarded to the remote tip"
    assert_eq "$bare_main" "$new_main" "main fast-forwarded to origin/main"
    assert_not_contains "$new_main" "$old_main" "main actually moved"
}

t_advance_merged_requires_branch() {
    setup_advance
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "--branch" "usage shown"
    assert_eq "develop/g1" "$(cd "$PROJ" && git branch --show-current)" "still on the work branch"
    assert_eq "develop/g1" "$(state_branch)" "state.json unchanged"
    assert_eq "P" "$(state_group)" "group unchanged"
}

t_advance_branch_prefix_rejected() {
    setup_advance
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch feature/x
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "develop/" "stderr explains the prefix rule"
    assert_eq "P" "$(state_group)" "state.json unchanged"
}

t_advance_dirty_tree_rejected() {
    setup_advance
    gh_stub MERGED "https://example.com/pr/1"
    touch "$PROJ/dirt.txt"
    run_script group-advance.sh --branch develop/g2
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "clean" "stderr explains the dirty tree"
    assert_eq "develop/g1" "$(cd "$PROJ" && git branch --show-current)" "branch unchanged"
    assert_eq "P" "$(state_group)" "state.json unchanged"
}

t_advance_group_incomplete_rejected() {
    setup_advance
    # 作業グループ P は T1 のみ。T1 が未完了なら境界ではない
    write_state "T1:in_review" "T2:pending" "T3:pending"
    set_state_group P
    set_state_branch develop/g1
    gh_stub NO_PR
    run_script group-advance.sh
    assert_eq 1 "$CODE" "exit code"
    assert_eq "" "$OUT" "stdout empty"
    assert_contains "$ERR" "T1" "stderr names the unfinished task"
    assert_eq "P" "$(state_group)" "group unchanged"
    assert_eq "develop/g1" "$(state_branch)" "state.json unchanged"
}

t_advance_unknown_group_rejected() {
    setup_advance
    set_state_group ZZZ
    run_script group-advance.sh
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "group" "stderr explains"
    assert_eq "ZZZ" "$(state_group)" "state.json unchanged"
}

t_advance_gh_failure_propagated() {
    setup_advance
    gh_stub FAIL "" 4
    run_script group-advance.sh
    assert_eq 4 "$CODE" "gh's exit code is returned"
    assert_contains "$ERR" "gh pr view failed" "stderr explains"
    assert_eq "P" "$(state_group)" "state.json unchanged"
}

t_advance_all_done_rejected() {
    setup_advance
    write_state "T1:done" "T2:done" "T3:done"
    set_state_group P
    set_state_branch develop/g1
    gh_stub MERGED "https://example.com/pr/1"
    run_script group-advance.sh --branch develop/g2
    assert_eq 1 "$CODE" "exit code"
    assert_contains "$ERR" "unfinished" "stderr explains no next group"
    assert_eq "P" "$(state_group)" "state.json unchanged"
}

echo "test-group-advance.sh"
test_case "advance: PR なしは exit 7" t_advance_no_pr
test_case "advance: OPEN は exit 8" t_advance_open
test_case "advance: OPEN で未 push のコミットがあれば exit 10" t_advance_open_unpushed
test_case "advance: OPEN でリモートのブランチが無ければ exit 10" t_advance_open_no_remote_branch
test_case "advance: CLOSED は exit 9" t_advance_closed
test_case "advance: MERGED はブランチ作成と state 更新" t_advance_merged
test_case "advance: --branch は既定で develop- 始まりも受け付ける" t_advance_branch_dash_prefix
test_case "advance: MERGED は base_branch から次のブランチを切る" t_advance_merged_base_branch
test_case "advance: 状態ファイルを追跡するリポジトリでは切替後に state.json をコミットする" t_advance_merged_commits_state
test_case "advance: .agents を追跡しないリポジトリでは state.json をコミットしない" t_advance_merged_untracked_state_no_commit
test_case "advance: MERGED は main を origin/main まで進める" t_advance_merged_pulls_main
test_case "advance: MERGED で --branch 無しは exit 1" t_advance_merged_requires_branch
test_case "advance: develop/ 以外の --branch は exit 1" t_advance_branch_prefix_rejected
test_case "advance: 作業ツリーが汚れていると exit 1" t_advance_dirty_tree_rejected
test_case "advance: 作業グループ未完了は exit 1" t_advance_group_incomplete_rejected
test_case "advance: 未知のグループ名は exit 1" t_advance_unknown_group_rejected
test_case "advance: gh 失敗は exit code を返す" t_advance_gh_failure_propagated
test_case "advance: 全タスク完了で切替先が無ければ exit 1" t_advance_all_done_rejected
summary
