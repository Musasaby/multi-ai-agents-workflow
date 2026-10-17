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
test_case "git-state: detached HEAD では branch が -" t_detached_branch_dash
summary
