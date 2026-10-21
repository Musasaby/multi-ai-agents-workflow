#!/bin/bash
# #65: tools/build-dist.sh(main の木から開発用ファイルを除いた dist ブランチを作る)
source "$(dirname "$0")/lib.sh"

SRC_DIR=""

# $PROJ 内(.agents/ は ignore 済み)にダミーの配布元リポジトリを作り、スクリプトと .distignore を置いてコミットする
setup_source() {
    SRC_DIR="$PROJ/.agents/src"
    mkdir -p "$SRC_DIR/skill" "$SRC_DIR/tests" "$SRC_DIR/docs/plans" "$SRC_DIR/tools"
    git -C "$SRC_DIR" init -q -b main
    assert_own_repo "$SRC_DIR"
    printf 'a\n' > "$SRC_DIR/skill/a.md"
    printf '#!/bin/bash\n' > "$SRC_DIR/tests/t.sh"
    printf 'p\n' > "$SRC_DIR/docs/plans/p.md"
    printf 'dev\n' > "$SRC_DIR/AGENTS.md"
    printf '# dist ブランチから除く\ntests/\ndocs/\ntools/\nAGENTS.md\n.distignore\n' > "$SRC_DIR/.distignore"
    cp "$REPO_ROOT/tools/build-dist.sh" "$SRC_DIR/tools/build-dist.sh"
    (
        cd "$SRC_DIR" || exit 1
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        git add -A
        git commit -q -m "init"
    ) || exit 1
}

run_build() {
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$SRC_DIR" && bash tools/build-dist.sh "$@") > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

t_build() {
    setup_source
    run_build
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_contains "$OUT" "Updated: dist" "Updated"
    local files
    files="$(git -C "$SRC_DIR" ls-tree -r --name-only dist)"
    assert_contains "$files" "skill/a.md" "skill/a.md がある"
    assert_not_contains "$files" "tests/" "tests/ が無い"
    assert_not_contains "$files" "docs/" "docs/ が無い"
    assert_not_contains "$files" "tools/" "tools/ が無い"
    assert_not_contains "$files" "AGENTS.md" "AGENTS.md が無い"
    assert_not_contains "$files" ".distignore" ".distignore が無い"
}

t_unchanged_and_parent() {
    setup_source
    run_build
    local first
    first="$(git -C "$SRC_DIR" rev-parse dist)"
    run_build
    assert_eq 0 "$CODE" "2回目 exit 0: $ERR"
    assert_contains "$OUT" "Unchanged: dist" "2回目は Unchanged"
    printf 'a2\n' > "$SRC_DIR/skill/a.md"
    git -C "$SRC_DIR" commit -q -a -m "change"
    run_build
    assert_eq 0 "$CODE" "3回目 exit 0: $ERR"
    assert_contains "$OUT" "Updated: dist" "3回目は Updated"
    assert_eq "$first" "$(git -C "$SRC_DIR" rev-parse dist^)" "dist^ は1回目の dist"
}

t_no_distignore() {
    setup_source
    git -C "$SRC_DIR" rm -q .distignore
    git -C "$SRC_DIR" commit -q -m "rm distignore"
    run_build
    assert_eq 1 "$CODE" "exit 1"
    assert_contains "$ERR" ".distignore not found" "stderr"
}

t_subtree_pull() {
    setup_source
    run_build
    local consumer="$PROJ/.agents/consumer"
    mkdir -p "$consumer"
    git -C "$consumer" init -q -b main
    assert_own_repo "$consumer"
    (
        cd "$consumer" || exit 1
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        printf 'x\n' > README.md
        git add -A
        git commit -q -m "init"
        git subtree add -q --prefix=.agents/skills "$SRC_DIR" main --squash
        printf 'mine\n' > .agents/skills/mine.md
        git add -A
        git commit -q -m "mine"
    ) || exit 1
    (cd "$consumer" && git subtree pull -q --prefix=.agents/skills "$SRC_DIR" dist --squash -m pull) > /dev/null 2>&1
    assert_eq 0 "$?" "subtree pull exit 0"
    assert_file_absent "$consumer/.agents/skills/tests" "tests が消える"
    assert_file_absent "$consumer/.agents/skills/AGENTS.md" "AGENTS.md が消える"
    assert_file_exists "$consumer/.agents/skills/mine.md" "mine.md が残る"
    assert_file_exists "$consumer/.agents/skills/skill/a.md" "skill/a.md が残る"
}

echo "test-build-dist.sh"
test_case "build-dist: 除外パスを除いた木で dist を作る" t_build
test_case "build-dist: 変更が無ければ Unchanged、変更があれば前回の dist を親にする" t_unchanged_and_parent
test_case "build-dist: .distignore が無ければ exit 1" t_no_distignore
test_case "build-dist: main から取り込んだ subtree を dist から pull すると開発用ファイルが消える" t_subtree_pull
summary
