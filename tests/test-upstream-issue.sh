#!/bin/bash
# #10: upstream-issue(起票先の解決・重複検索・起票, POSIX版。gh は --dry-run で呼ばない)
source "$(dirname "$0")/lib.sh"

set_upstream() { # $1 = upstream.url(空文字なら upstream キーを削除)
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, url = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
if url:
    cfg['upstream']['url'] = url
else:
    cfg.pop('upstream', None)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

t_search_https() {
    run_script upstream-issue.sh --search "signal 241" --dry-run
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Musasaby/multi-ai-agents-workflow" "repo from default config"
    assert_contains "$OUT" "gh issue list" "search command"
    assert_contains "$OUT" "--state all" "includes closed issues"
    assert_contains "$OUT" "signal 241" "query"
}

t_search_ssh() {
    set_upstream "git@github.com:someone/forked-workflow.git"
    run_script upstream-issue.sh --search x --dry-run
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "someone/forked-workflow" "ssh url parsed"
    assert_not_contains "$OUT" ".git" "suffix stripped"
}

t_search_no_suffix() {
    set_upstream "https://github.com/someone/repo"
    run_script upstream-issue.sh --search x --dry-run
    assert_contains "$OUT" "someone/repo" "url without .git"
}

t_missing_upstream() {
    set_upstream ""
    run_script upstream-issue.sh --search x --dry-run
    assert_eq 1 "$CODE" "exit code"
}

t_non_github() {
    set_upstream "https://gitlab.com/a/b.git"
    run_script upstream-issue.sh --search x --dry-run
    assert_eq 1 "$CODE" "exit code"
}

t_create_dry_run() {
    printf '## 現象\nx\n' > "$PROJ/body.md"
    run_script upstream-issue.sh --create --title "テストの件名" --body-file body.md --dry-run
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "gh issue create" "create command"
    assert_contains "$OUT" "-R Musasaby/multi-ai-agents-workflow" "explicit repo"
    assert_contains "$OUT" "テストの件名" "title"
    assert_contains "$OUT" "--body-file" "body file"
    assert_not_contains "$OUT" "--label" "no label"
}

t_create_requires_title() {
    printf 'x\n' > "$PROJ/body.md"
    run_script upstream-issue.sh --create --body-file body.md --dry-run
    assert_eq 1 "$CODE" "exit code"
}

t_create_requires_body_file() {
    run_script upstream-issue.sh --create --title t --body-file nothing.md --dry-run
    assert_eq 1 "$CODE" "exit code"
}

t_no_mode() {
    run_script upstream-issue.sh --dry-run
    assert_eq 1 "$CODE" "exit code"
}

t_missing_value_no_hang() {
    local code
    (cd "$PROJ" && timeout 10 .agents/workflow/scripts/upstream-issue.sh --create --title) > /dev/null 2>&1
    code=$?
    assert_eq 1 "$code" "option without value -> exit 1 (124 = hang)"
}

t_windows_abs_body_file() {
    printf 'x\n' > "$PROJ/body.md"
    local abs
    abs="$(py_path "$PROJ/body.md")"
    run_script upstream-issue.sh --create --title t --body-file "$abs" --dry-run
    assert_eq 0 "$CODE" "absolute body-file path accepted: $ERR"
}

echo "test-upstream-issue.sh"
test_case "search: https" t_search_https
test_case "search: ssh" t_search_ssh
test_case "search: .gitなし" t_search_no_suffix
test_case "upstream未設定はexit 1" t_missing_upstream
test_case "github以外はexit 1" t_non_github
test_case "create: dry-run" t_create_dry_run
test_case "create: title必須" t_create_requires_title
test_case "create: body-file必須" t_create_requires_body_file
test_case "モード未指定はexit 1" t_no_mode
test_case "値の欠けたオプションでハングしない" t_missing_value_no_hang
test_case "body-file の絶対パス" t_windows_abs_body_file
summary
