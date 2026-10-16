#!/bin/bash
# lib-guard(tests/lib.sh の git 閉じ込めガード, POSIX版)
source "$(dirname "$0")/lib.sh"

LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 外側のリポジトリ($PROJ)の状態(コミット数と .git/config の内容)
outer_state() { printf '%s|%s' "$(git -C "$PROJ" rev-list --count HEAD)" "$(cat "$PROJ/.git/config")"; }

# 別プロセスで lib を読み込んで $1 の本文を実行する → OUT / ERR / CODE
run_in_child() {
    mkdir -p "$PROJ/tmp" "$PROJ/inner"
    local out_file="$PROJ/child.out" err_file="$PROJ/child.err"
    LIB_SH="$LIB_SH" INNER="$PROJ/inner" TMPDIR="$PROJ/tmp" bash -c "$1" > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
}

t_assert_own_repo_fails() {
    local before
    before="$(outer_state)"
    run_in_child 'source "$LIB_SH"; assert_own_repo "$INNER"'
    assert_eq 1 "$CODE" "exit: $ERR"
    assert_contains "$ERR" "FATAL: test project is not its own git repository" "fatal message"
    assert_eq "$before" "$(outer_state)" "外側のリポジトリは変化しない"
}

t_ceiling_blocks_outer_repo() {
    local before
    before="$(outer_state)"
    run_in_child 'source "$LIB_SH"; d="$(mktemp -d)"; git -C "$d" rev-parse --show-toplevel'
    assert_eq 128 "$CODE" "exit: $ERR"
    assert_eq "$before" "$(outer_state)" "外側のリポジトリは変化しない"
}

t_new_project_own_repo() {
    local before
    before="$(outer_state)"
    run_in_child 'source "$LIB_SH"; new_project; echo "OK"'
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "OK" "new_project がダミー自身のリポジトリを作る"
    assert_eq "$before" "$(outer_state)" "外側のリポジトリは変化しない"
}

echo "test-lib-guard.sh"
test_case "guard: .git の無いディレクトリは assert_own_repo で失敗する" t_assert_own_repo_fails
test_case "guard: GIT_CEILING_DIRECTORIES があれば外側のリポジトリに届かない" t_ceiling_blocks_outer_repo
test_case "guard: 外側のリポジトリ内でも new_project はダミー自身のリポジトリになる" t_new_project_own_repo
summary
