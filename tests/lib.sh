#!/bin/bash
# テスト共通ヘルパー(POSIX版スクリプト用)。
# 一時ディレクトリにダミーの利用先プロジェクト(.agents/workflow/ 一式 + git リポジトリ)を作り、
# _templates/workflow/scripts/ のスクリプトをコピーして実行する。

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_SCRIPTS="$REPO_ROOT/_templates/workflow/scripts"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()

# python3 は Windows ネイティブ版の場合 MSYS パス(/c/...)を解決できないため変換する
py_path() {
    if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# 新しいダミープロジェクトを作り、そのパスを PROJ に設定する
new_project() {
    PROJ="$(mktemp -d)"
    mkdir -p "$PROJ/.agents/workflow/scripts" "$PROJ/.agents/workflow/runs"
    cp "$TEMPLATE_SCRIPTS"/* "$PROJ/.agents/workflow/scripts/"
    chmod +x "$PROJ/.agents/workflow/scripts/"*.sh
    cp "$REPO_ROOT/_templates/workflow/config.json" "$PROJ/.agents/workflow/config.json"
    (
        cd "$PROJ"
        git init -q -b main
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        printf '.agents/\n' > .gitignore
        git add .gitignore
        git commit -q -m "init"
    )
}

cleanup_project() {
    [ -n "${PROJ:-}" ] && rm -rf "$PROJ"
    PROJ=""
}

write_tasks() {
    cat > "$PROJ/.agents/workflow/tasks.md"
}

# write_state "T1:done" "T2:pending" ...
write_state() {
    local json_tasks=""
    local item id status retries
    for item in "$@"; do
        # "T1:status" または "T1:status:retries"
        IFS=':' read -r id status retries <<< "$item"
        retries="${retries:-0}"
        [ -n "$json_tasks" ] && json_tasks="$json_tasks,"
        json_tasks="$json_tasks{\"id\":\"$id\",\"title\":\"$id title\",\"status\":\"$status\",\"retries\":$retries,\"commit\":null}"
    done
    printf '{"source":"test","branch":"main","updated_at":"2026-01-01T00:00:00+09:00","tasks":[%s]}\n' "$json_tasks" \
        > "$PROJ/.agents/workflow/state.json"
}

# write_report T1 1 → runs/T1-1/report.md を作る
write_report() {
    mkdir -p "$PROJ/.agents/workflow/runs/$1-$2"
    printf '## 完了報告\n- 変更ファイル: a\n' > "$PROJ/.agents/workflow/runs/$1-$2/report.md"
}

# run_script <name.sh> [args...] → OUT / ERR / CODE を設定する
run_script() {
    local script="$1"; shift
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$PROJ" && ".agents/workflow/scripts/$script" "$@") > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

# state.json の値を python で取り出す: state_get 'T1' 'status'
state_get() {
    python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    s = json.load(f)
for t in s['tasks']:
    if t['id'] == sys.argv[2]:
        print(t[sys.argv[3]]); break
else:
    print('<absent>')
" "$(py_path "$PROJ/.agents/workflow/state.json")" "$1" "$2"
}

state_ids() {
    python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    s = json.load(f)
print(','.join(t['id'] for t in s['tasks']))
" "$(py_path "$PROJ/.agents/workflow/state.json")"
}

_record() {
    if [ "$1" = ok ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_NAMES+=("$CURRENT_TEST: $2")
        echo "    FAIL: $2"
    fi
}

assert_eq() { # expected actual message
    if [ "$1" = "$2" ]; then _record ok; else _record ng "$3 (expected '$1', got '$2')"; fi
}

assert_contains() { # haystack needle message
    case "$1" in
        *"$2"*) _record ok ;;
        *) _record ng "$3 (missing '$2' in: $(printf '%s' "$1" | head -c 400))" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) _record ng "$3 (unexpected '$2')" ;;
        *) _record ok ;;
    esac
}

assert_file_exists() { if [ -f "$1" ]; then _record ok; else _record ng "$2 (file not found: $1)"; fi; }
assert_file_absent() { if [ ! -e "$1" ]; then _record ok; else _record ng "$2 (file exists: $1)"; fi; }

# test_case <name> <function>
test_case() {
    CURRENT_TEST="$1"
    echo "  - $1"
    new_project
    "$2"
    cleanup_project
}

summary() {
    echo
    echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf '  %s\n' "${FAILED_NAMES[@]}"
        return 1
    fi
    return 0
}
