#!/bin/bash
# git-state(git 状態の4行出力, POSIX版)
source "$(dirname "$0")/lib.sh"

# OUT の N 行目(1 始まり)を返す
out_line() {
    printf '%s\n' "$OUT" | sed -n "${1}p"
}

# 等しくないことを検証する(lib.sh に assert_ne が無いため、ここで定義する)
assert_ne() { # not-expected actual message
    if [ "$1" != "$2" ]; then _record ok; else _record ng "$3 (both lines are '$1')"; fi
}

t_four_items() {
    run_script git-state.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq 4 "$(printf '%s\n' "$OUT" | awk 'END { print NR }')" "出力は4行"
    assert_eq "head $(git -C "$PROJ" rev-parse HEAD)" "$(out_line 1)" "1行目は head <HEAD の値>"
    assert_eq "branch refs/heads/main" "$(out_line 2)" "2行目は branch refs/heads/main"
    assert_eq 1 "$(printf '%s\n' "$OUT" | grep -cE '^refs [0-9a-f]{64}$')" "3行目は refs + 16進64文字"
    assert_eq 1 "$(printf '%s\n' "$OUT" | grep -cE '^config [0-9a-f]{64}$')" "4行目は config + 16進64文字"
}

t_commit_changes_head() {
    run_script git-state.sh
    local before_head before_config
    before_head="$(out_line 1)"
    before_config="$(out_line 4)"
    git -C "$PROJ" commit -q --allow-empty -m x
    run_script git-state.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_ne "$before_head" "$(out_line 1)" "コミットで head 行が変わる"
    assert_eq "$before_config" "$(out_line 4)" "config 行は同じ"
}

t_config_changes_config() {
    run_script git-state.sh
    local before_head before_branch before_refs before_config
    before_head="$(out_line 1)"
    before_branch="$(out_line 2)"
    before_refs="$(out_line 3)"
    before_config="$(out_line 4)"
    git -C "$PROJ" config user.name x
    run_script git-state.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_ne "$before_config" "$(out_line 4)" "git config で config 行が変わる"
    assert_eq "$before_head" "$(out_line 1)" "head 行は変わらない"
    assert_eq "$before_branch" "$(out_line 2)" "branch 行は変わらない"
    assert_eq "$before_refs" "$(out_line 3)" "refs 行は変わらない"
}

t_branch_changes_refs() {
    run_script git-state.sh
    local before_head before_branch before_refs before_config
    before_head="$(out_line 1)"
    before_branch="$(out_line 2)"
    before_refs="$(out_line 3)"
    before_config="$(out_line 4)"
    git -C "$PROJ" branch x
    run_script git-state.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_ne "$before_refs" "$(out_line 3)" "ブランチ作成で refs 行が変わる"
    assert_eq "$before_head" "$(out_line 1)" "head 行は変わらない"
    assert_eq "$before_branch" "$(out_line 2)" "branch 行は変わらない"
    assert_eq "$before_config" "$(out_line 4)" "config 行は変わらない"
}

t_ref_ignores_other_branches() {
    run_script git-state.sh --ref refs/heads/main
    assert_eq 0 "$CODE" "exit: $ERR"
    local before_refs before_head
    before_refs="$(out_line 3)"
    before_head="$(out_line 1)"
    git -C "$PROJ" branch x
    run_script git-state.sh --ref refs/heads/main
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "$before_refs" "$(out_line 3)" "ほかのブランチ作成で --ref の refs 行は変わらない"
    assert_eq "$before_head" "$(out_line 1)" "head 行は変わらない"
}

t_ref_follows_own_branch() {
    run_script git-state.sh --ref refs/heads/main
    local before_refs
    before_refs="$(out_line 3)"
    git -C "$PROJ" commit -q --allow-empty -m x
    run_script git-state.sh --ref refs/heads/main
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_ne "$before_refs" "$(out_line 3)" "自分のブランチのコミットで --ref の refs 行が変わる"
}

t_ref_usage_error() {
    run_script git-state.sh --ref
    assert_eq 1 "$CODE" "--ref の値が無いと exit 1"
    assert_eq "Usage: git-state.sh [--ref <refname> | --run <refname> --parent <refname>]" "$ERR" "使い方を stderr に出す"
    run_script git-state.sh --bogus
    assert_eq 1 "$CODE" "未知の引数は exit 1"
    run_script git-state.sh --run refs/heads/agents-run/r1
    assert_eq 1 "$CODE" "--run だけだと exit 1"
    run_script git-state.sh --parent refs/heads/main
    assert_eq 1 "$CODE" "--parent だけだと exit 1"
    run_script git-state.sh --run refs/heads/agents-run/r1 --parent
    assert_eq 1 "$CODE" "--parent の値が無いと exit 1"
    run_script git-state.sh --run
    assert_eq 1 "$CODE" "--run の値が無いと exit 1"
    run_script git-state.sh --ref refs/heads/main --run refs/heads/agents-run/r1 --parent refs/heads/main
    assert_eq 1 "$CODE" "--ref との併用は exit 1"
}

RUN_REF=refs/heads/agents-run/r1

t_run_ignores_other_runs_and_parent() {
    git -C "$PROJ" branch agents-run/r1
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    assert_eq 0 "$CODE" "exit: $ERR"
    local before
    before="$(out_line 3)"
    git -C "$PROJ" branch agents-run/r2
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    assert_eq "$before" "$(out_line 3)" "ほかの run のブランチ作成で変わらない"
    git -C "$PROJ" commit -q --allow-empty -m parent
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    assert_eq "$before" "$(out_line 3)" "--parent のブランチのコミットで変わらない"
}

t_run_detects_other_changes() {
    git -C "$PROJ" branch agents-run/r1
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    local before
    before="$(out_line 3)"
    git -C "$PROJ" tag t1
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    assert_ne "$before" "$(out_line 3)" "タグ作成で変わる"
    before="$(out_line 3)"
    git -C "$PROJ" branch other
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    assert_ne "$before" "$(out_line 3)" "--parent 以外のブランチ作成で変わる"
    before="$(out_line 3)"
    git -C "$PROJ" update-ref "$RUN_REF" "$(git -C "$PROJ" commit-tree -m x "HEAD^{tree}")"
    run_script git-state.sh --run "$RUN_REF" --parent refs/heads/main
    assert_ne "$before" "$(out_line 3)" "自分の run のブランチの移動で変わる"
}

t_run_parent_dash_excludes_nothing() {
    run_script git-state.sh --run "$RUN_REF" --parent -
    local before
    before="$(out_line 3)"
    git -C "$PROJ" commit -q --allow-empty -m x
    run_script git-state.sh --run "$RUN_REF" --parent -
    assert_ne "$before" "$(out_line 3)" "--parent - なら main の移動で変わる"
}

t_detached_branch_dash() {
    git -C "$PROJ" checkout -q --detach
    run_script git-state.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "branch -" "$(out_line 2)" "detached HEAD では branch -"
    assert_eq "head $(git -C "$PROJ" rev-parse HEAD)" "$(out_line 1)" "head 行は HEAD の値のまま"
}

echo "test-git-state.sh"
test_case "git-state: 4 項目を出力する" t_four_items
test_case "git-state: コミットで head が変わる" t_commit_changes_head
test_case "git-state: git config で config が変わる" t_config_changes_config
test_case "git-state: ブランチ作成で refs が変わる" t_branch_changes_refs
test_case "git-state: --ref はほかのブランチの変化を無視する" t_ref_ignores_other_branches
test_case "git-state: --ref は自分のブランチの変化に追従する" t_ref_follows_own_branch
test_case "git-state: 不正な引数は exit 1" t_ref_usage_error
test_case "git-state: --run はほかの run と --parent の変化を無視する" t_run_ignores_other_runs_and_parent
test_case "git-state: --run はタグ・ほかのブランチ・自分の run の変化を検知する" t_run_detects_other_changes
test_case "git-state: --parent - は何も除かない" t_run_parent_dash_excludes_nothing
test_case "git-state: detached HEAD では branch が -" t_detached_branch_dash
summary
