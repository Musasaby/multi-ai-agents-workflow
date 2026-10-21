#!/bin/bash
# テスト共通ヘルパー(POSIX版スクリプト用)。
# 一時ディレクトリにダミーの利用先プロジェクト(.agents/workflow/ 一式 + git リポジトリ)を作り、
# agents-md-setup/templates/workflow/scripts/ のスクリプトをコピーして実行する。

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# テストの git を利用者のグローバル設定・システム設定から切り離す(Issue F-1)。
# テストに必要な設定(user.email 等)は new_project で各リポジトリのローカル設定に明示する
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

# gh スタブ(PATH 先頭に置き、gh_stub_set で挙動を切り替える)。
# 既定(gh_stub_set で設定していない状態)では、意図しない gh 呼び出しを
# stderr に記録して exit 97 で失敗させる(利用先テストでの実 gh 呼び出し防止)
GH_STUB_DIR="$(mktemp -d)"
# ダミープロジェクトに .git が無い場合でも、git が親ディレクトリの本物のリポジトリにたどり着かないようにする
GIT_CEILING_DIRECTORIES="$(dirname "$GH_STUB_DIR")"
export GIT_CEILING_DIRECTORIES
cat > "$GH_STUB_DIR/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_STUB_LOG"
if [ "${GH_STUB_SET:-}" = 1 ]; then
    [ -n "${GH_STUB_STDOUT:-}" ] && printf '%s\n' "$GH_STUB_STDOUT"
    [ -n "${GH_STUB_STDERR:-}" ] && printf '%s\n' "$GH_STUB_STDERR" >&2
    exit "${GH_STUB_CODE:-0}"
fi
printf 'gh stub: unexpected call: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$GH_STUB_DIR/gh"
if command -v cygpath > /dev/null 2>&1; then
    export PATH="$(cygpath -u "$GH_STUB_DIR"):$PATH"
else
    export PATH="$GH_STUB_DIR:$PATH"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_SCRIPTS="$REPO_ROOT/agents-md-setup/templates/workflow/scripts"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()
CREATED_PROJECTS=""

# python3 は Windows ネイティブ版の場合 MSYS パス(/c/...)を解決できないため変換する
py_path() {
    if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# <dir> が自分自身の git リポジトリであることを確かめる(親の本物のリポジトリに git を実行しないため)
assert_own_repo() {
    local dir="$1" expected actual
    if command -v cygpath > /dev/null 2>&1; then
        expected="$(cygpath -m "$dir")"
    else
        expected="$(cd "$dir" && pwd -P)"
    fi
    actual="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
    if [ "$actual" != "$expected" ]; then
        echo "FATAL: test project is not its own git repository: $dir (toplevel: ${actual:-none})" >&2
        exit 1
    fi
}

# 新しいダミープロジェクトを作り、そのパスを PROJ に設定する
new_project() {
    PROJ="$(mktemp -d)"
    CREATED_PROJECTS="$CREATED_PROJECTS $PROJ"
    mkdir -p "$PROJ/.agents/workflow/scripts" "$PROJ/.agents/workflow/runs"
    cp "$TEMPLATE_SCRIPTS"/* "$PROJ/.agents/workflow/scripts/"
    chmod +x "$PROJ/.agents/workflow/scripts/"*.sh
    cp "$REPO_ROOT/agents-md-setup/templates/workflow/config.json" "$PROJ/.agents/workflow/config.json"
    git -C "$PROJ" init -q -b main
    assert_own_repo "$PROJ"
    (
        cd "$PROJ" || exit 1
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        printf '.agents/\n' > .gitignore
        git add .gitignore
        git commit -q -m "init"
    ) || exit 1
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

# state.json のトップレベル group を設定する(空引数は「既定グループ=空文字列」として設定)。
# (キー自体を削除したい場合は remove_state_group を使うこと)
set_state_group() {
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$1" <<'PY'
import json, sys
p, group = sys.argv[1], sys.argv[2]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
s['group'] = group
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# state.json のトップレベル group キーを削除する(groupフィールド無しの旧state.json相当)
remove_state_group() {
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
s.pop('group', None)
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# state.json のトップレベル group を返す(キーが無ければ <absent>)
state_group() {
    python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    s = json.load(f)
print(s.get('group', '<absent>'))
" "$(py_path "$PROJ/.agents/workflow/state.json")"
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

# gh スタブの挙動を設定する: gh_stub_set <code> <stdout> <stderr>
# (stdout / stderr が空なら出力なし。設定時に呼び出し記録も空にする)
gh_stub_set() {
    export GH_STUB_SET=1
    GH_STUB_CODE="$1"
    GH_STUB_STDOUT="${2-}"
    GH_STUB_STDERR="${3-}"
    export GH_STUB_CODE GH_STUB_STDOUT GH_STUB_STDERR
    GH_STUB_LOG="$GH_STUB_DIR/log"
    export GH_STUB_LOG
    rm -f "$GH_STUB_LOG"
}

# gh の呼び出し記録を返す(gh が呼ばれていなければ空文字列)
gh_stub_log() {
    if [ -n "${GH_STUB_LOG:-}" ] && [ -f "$GH_STUB_LOG" ]; then
        cat "$GH_STUB_LOG"
    fi
}

# スタブの挙動を既定(未設定 = 意図しない呼び出しは exit 97)に戻す
gh_stub_reset() {
    unset GH_STUB_LOG GH_STUB_SET GH_STUB_CODE GH_STUB_STDOUT GH_STUB_STDERR
    rm -f "$GH_STUB_DIR/log"
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
    gh_stub_reset
    new_project
    "$2"
    cleanup_project
}

summary() {
    # 一時ディレクトリの残留検出(new_project が作ったディレクトリがすべて消えていること)
    local leftover=""
    local dir
    for dir in $CREATED_PROJECTS; do
        [ -n "$dir" ] && [ -e "$dir" ] && leftover="$leftover $dir"
    done
    # gh スタブのディレクトリも削除する(消えなければ残留として検出する)
    rm -rf "$GH_STUB_DIR"
    [ -e "$GH_STUB_DIR" ] && leftover="$leftover $GH_STUB_DIR"
    if [ -n "$leftover" ]; then
        echo "    leftover temp dir(s):$leftover"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_NAMES+=("一時ディレクトリの残留:$leftover")
    fi
    echo
    echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf '  %s\n' "${FAILED_NAMES[@]}"
        return 1
    fi
    return 0
}
