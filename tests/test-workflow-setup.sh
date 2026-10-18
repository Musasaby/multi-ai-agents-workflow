#!/bin/bash
# #61: workflow-setup(利用先のセットアップ, POSIX版)
source "$(dirname "$0")/lib.sh"

IS_WINDOWS=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;; esac

# 空の利用先(test_case が new_project 済み): テンプレートは .agents/skills/_templates/ 配下、.agents/workflow/ と .gitignore は無い
setup_empty_project() {
    rm -rf "$PROJ/.agents/workflow" "$PROJ/.gitignore"
    mkdir -p "$PROJ/.agents/skills"
    cp -r "$REPO_ROOT/_templates" "$PROJ/.agents/skills/_templates"
}

# リンク自体だけを消す(リンク先の .agents の中身を巻き込まない)
remove_claude_link() {
    [ -L "$PROJ/.claude" ] || return 0
    if [ "$IS_WINDOWS" = true ]; then
        (cd "$PROJ" && cmd //c "rmdir .claude" > /dev/null 2>&1)
    else
        rm -f "$PROJ/.claude"
    fi
}

run_setup() {
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$PROJ" && bash .agents/skills/_templates/workflow/scripts/workflow-setup.sh "$@") > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

t_setup() {
    setup_empty_project
    run_setup
    assert_eq 0 "$CODE" "exit 0: $OUT $ERR"
    assert_file_exists "$PROJ/.agents/workflow/config.json" "config.json"
    assert_file_exists "$PROJ/.agents/workflow/scripts/next-task.sh" "scripts copied"
    assert_file_exists "$PROJ/AGENTS.md" "AGENTS.md"
    assert_eq "@AGENTS.md" "$(tr -d '\r' < "$PROJ/CLAUDE.md")" "CLAUDE.md content"
    assert_contains "$(cat "$PROJ/.gitignore")" ".agents/workflow/runs/" "gitignore line"
    assert_contains "$(cat "$PROJ/.gitattributes")" "text eol=lf" "gitattributes line"
    if [ -L "$PROJ/.claude" ]; then _record ok; else _record ng ".claude is not a link"; fi
    remove_claude_link
}

t_idempotent() {
    setup_empty_project
    run_setup
    run_setup
    assert_eq 0 "$CODE" "2nd run exit 0: $OUT $ERR"
    assert_eq "Next: continue" "$(printf '%s\n' "$OUT" | tail -n 1)" "2nd run last line"
    remove_claude_link
    assert_not_contains "$OUT" "CREATED" "no CREATED on 2nd run"
    assert_not_contains "$OUT" "APPENDED" "no APPENDED on 2nd run"
    assert_eq 1 "$(grep -cxF '.agents/workflow/runs/' "$PROJ/.gitignore")" "runs line once"
    assert_eq 1 "$(grep -cxF '.claude' "$PROJ/.gitignore")" ".claude line once"
}

t_claude_md_kept() {
    setup_empty_project
    printf '# mine\n' > "$PROJ/CLAUDE.md"
    run_setup
    assert_eq 3 "$CODE" "exit 3"
    assert_eq "# mine" "$(cat "$PROJ/CLAUDE.md")" "CLAUDE.md untouched"
    assert_contains "$OUT" "DECIDE claude-md" "DECIDE claude-md"
    assert_eq "Next: confirm" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
    remove_claude_link
}

t_check() {
    setup_empty_project
    run_setup --check
    assert_eq 3 "$CODE" "exit 3"
    assert_contains "$OUT" "MISSING" "MISSING listed"
    assert_file_absent "$PROJ/.agents/workflow/config.json" "nothing created"
    assert_file_absent "$PROJ/CLAUDE.md" "CLAUDE.md not created"
}

t_old_layout() {
    setup_empty_project
    run_setup
    mkdir -p "$PROJ/.agents/workflow/logs"
    run_setup
    assert_contains "$OUT" "DECIDE old-layout" "old layout detected"
    remove_claude_link
}

echo "test-workflow-setup.sh"
test_case "setup: 空の利用先に必要なものを揃える" t_setup
test_case "setup: 2回目の実行では何も変えない" t_idempotent
test_case "setup: 既存の CLAUDE.md の内容は上書きせず DECIDE を出す" t_claude_md_kept
test_case "setup: --check は何も変えずに不足を出す" t_check
test_case "setup: 旧レイアウトを DECIDE で知らせる" t_old_layout
summary
