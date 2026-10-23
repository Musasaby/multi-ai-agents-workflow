#!/bin/bash
set -uo pipefail

# 今のブランチが作業に使ってよいかを機械的に判定する(Issue #32)。何も書き換えない。
# Usage: branch-check.sh [--state]
# squash マージでは git merge-base --is-ancestor が成り立たず、main から切った直後の
# 新ブランチでは逆に成り立ってしまうため、祖先判定は使わず gh の PR 状態で判定する。
# 判定順(gh を呼ばずに済む判定を先に行う):
#   1. 使い方不備・git 失敗(detached HEAD を含む)→ exit 1
#   2. 現在のブランチが main(config.json の base_branch があればその名前も)→ exit 2
#   3. --state 指定時、state.json の branch と現在のブランチが異なる → exit 5
#      (state.json が無い・branch が空の場合はこの判定を飛ばす)
#   4. gh が無い・認証切れ等で PR 状態を取得できない → exit 4
#   5. 現在のブランチの PR がマージ済み → stdout "MERGED <PR URL>"、exit 3
#   6. いずれにも当たらない → stdout "OK <ブランチ名>"、exit 0
# gh pr list --head <branch> --state merged は、一致する PR が無ければ [] を出力して exit 0。
# (古い gh が「no pull requests found」で失敗した場合も PR なしとして扱う)
# exit: 0=使ってよい / 1=使い方・git 失敗 / 2=main 上 / 3=PR マージ済み / 4=gh で判定不能
#       5=state.json の branch と不一致
# stdout の最後の行に "Next: <行動>" を出す(exit 1 を除く): 0=continue / 2=switch-branch reason=main /
#       3=switch-branch reason=merged / 4=escalate reason=gh-unavailable / 5=escalate reason=state-branch-mismatch

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

USAGE="Usage: branch-check.sh [--state]"
CHECK_STATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --state) CHECK_STATE=1; shift ;;
        *) echo "Unknown argument: $1
$USAGE" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

STATE_PATH="$ROOT/.agents/workflow/state.json"
CONFIG_PATH="$ROOT/.agents/workflow/config.json"

# python3 on Git Bash for Windows is typically a native Windows build that
# cannot resolve MSYS-style absolute paths (e.g. /c/...). Convert to a
# Windows-native path (forward slashes) for paths passed into python3.
to_py_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# json_field <path> <dotted.key> → 値(無い・読めない場合は空文字列)
json_field() {
    [ -f "$1" ] || return 0
    python3 - "$(to_py_path "$1")" "$2" <<'PY' 2> /dev/null || true
import json, sys
path, key = sys.argv[1:3]
with open(path, encoding='utf-8-sig') as f:
    value = json.load(f)
for part in key.split('.'):
    value = value.get(part) if isinstance(value, dict) else None
print(value if isinstance(value, str) else '')
PY
}

# --- 1. 現在のブランチ ---
BRANCH="$(git branch --show-current 2>&1)"
GIT_CODE=$?
if [ "$GIT_CODE" -ne 0 ]; then
    echo "git branch --show-current failed (exit $GIT_CODE): $BRANCH" >&2
    exit 1
fi
if [ -z "$BRANCH" ]; then
    echo "HEAD is detached (switch to a work branch first)" >&2
    exit 1
fi

# --- 2. main 上 ---
BASE_BRANCH="$(json_field "$CONFIG_PATH" base_branch)"
if [ "$BRANCH" = "main" ] || { [ -n "$BASE_BRANCH" ] && [ "$BRANCH" = "$BASE_BRANCH" ]; }; then
    echo "On '$BRANCH': do not work on the main branch (create a work branch from the latest origin/${BASE_BRANCH:-main}; its name must start with one of config.json branch_prefixes, default 'develop/', 'develop-')" >&2
    echo "Next: switch-branch reason=main"
    exit 2
fi

# --- 3. state.json の branch との一致(--state 指定時のみ) ---
if [ "$CHECK_STATE" -eq 1 ]; then
    STATE_BRANCH="$(json_field "$STATE_PATH" branch)"
    if [ -n "$STATE_BRANCH" ] && [ "$STATE_BRANCH" != "$BRANCH" ]; then
        echo "Current branch '$BRANCH' differs from state.json's branch '$STATE_BRANCH' (switch to '$STATE_BRANCH', or update state.json if the workflow moved)" >&2
        echo "Next: escalate reason=state-branch-mismatch"
        exit 5
    fi
fi

# --- 4・5. PR 状態(マージ済みか) ---
if ! command -v gh > /dev/null 2>&1; then
    echo "gh not found: cannot check whether '$BRANCH' has a merged PR" >&2
    echo "Next: escalate reason=gh-unavailable"
    exit 4
fi

GH_OUT_FILE="$(mktemp)"
GH_ERR_FILE="$(mktemp)"
trap 'rm -f "$GH_OUT_FILE" "$GH_ERR_FILE"' EXIT

gh pr list --head "$BRANCH" --state merged --json url --limit 1 > "$GH_OUT_FILE" 2> "$GH_ERR_FILE"
GH_CODE=$?
if [ "$GH_CODE" -ne 0 ]; then
    GH_ERR="$(cat "$GH_ERR_FILE")"
    if printf '%s' "$GH_ERR" | grep -qi 'no pull request'; then
        echo "OK $BRANCH"
        echo "Next: continue"
        exit 0
    fi
    echo "gh pr list failed (exit $GH_CODE): cannot check whether '$BRANCH' has a merged PR: $GH_ERR" >&2
    echo "Next: escalate reason=gh-unavailable"
    exit 4
fi

PR_URL="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    text = f.read().strip()
data = json.loads(text) if text else []
if not isinstance(data, list):
    raise SystemExit('expected a JSON list')
print((str(data[0].get('url') or '') or '(unknown URL)') if data else '')
" "$(to_py_path "$GH_OUT_FILE")")" || {
    echo "Failed to parse gh pr list output (expected a JSON list): $(cat "$GH_OUT_FILE")" >&2
    echo "Next: escalate reason=gh-unavailable"
    exit 4
}

if [ -n "$PR_URL" ]; then
    echo "MERGED $PR_URL"
    echo "Next: switch-branch reason=merged"
    exit 3
fi

echo "OK $BRANCH"
echo "Next: continue"
exit 0
