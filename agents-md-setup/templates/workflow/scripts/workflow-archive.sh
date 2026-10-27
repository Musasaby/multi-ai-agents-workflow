#!/bin/bash
set -euo pipefail

# workflow 状態(tasks.md / state.json / runs/ / comprehension/)を archive/ へ移動する。
# Usage: workflow-archive.sh <スラッグ> [--force]   (--force はスラッグの前後どちらでも可)
# 判定順:
#   1. 引数の解析(スラッグ未指定・余分な引数は exit 1)
#   2. スラッグのパス区切り・'..' の検査、移動対象の有無(無ければ exit 1)
#   3. --force が無ければ PR の状態を確かめる(state.json の branch が空・main・config.json の
#      base_branch と同じなら gh を呼ばずに通す)。gh pr view の結果で分岐する:
#      - MERGED → アーカイブする
#      - PR なし(gh が「no pull request」で失敗)→ ローカルにブランチが無い、または比較先
#        (base_branch、無ければ main)に未マージのコミットが無ければアーカイブする。
#        未マージのコミットがある・比較先が無い → stdout "NO_PR"、exit 5
#      - OPEN   → stdout "OPEN <PR URL>"、exit 2
#      - CLOSED → stdout "CLOSED <PR URL>"、exit 3
#      - gh が無い・失敗・出力を解析できない → exit 4
#      - それ以外の state → exit 1
# exit: 0=アーカイブした / 1=使い方不備 / 2=PR OPEN / 3=PR CLOSED / 4=gh で判定不能 /
#       5=PR 未作成でブランチに未マージのコミットがある(比較先が無い場合も含む)
# 止めるとき(2 / 3 / 4 / 5)は何も移動せず、archive/ も作らない。stdout の最後の行は次アクションを示す
# "Next:" 行(2=escalate reason=pr-open / 3=escalate reason=pr-closed / 4=escalate reason=gh-unavailable /
# 5=escalate reason=pr-not-created)。
# exit 0 の出力は "Archived: ..." の1行だけ("Next:" 行は出さない)

FORCE=0
SLUG=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *)
            if [ -z "$SLUG" ]; then SLUG="$arg"; else echo "Unknown argument: $arg" >&2; exit 1; fi ;;
    esac
done
if [ -z "$SLUG" ]; then
    echo "使い方: workflow-archive.sh <スラッグ> [--force]" >&2
    exit 1
fi

case "$SLUG" in
    */*|*\\*|*..*)
        echo "スラッグにパス区切りや '..' を含めることはできません: $SLUG" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

WORKFLOW_DIR="$ROOT/.agents/workflow"
STATE_PATH="$WORKFLOW_DIR/state.json"
CONFIG_PATH="$WORKFLOW_DIR/config.json"

if [ ! -d "$WORKFLOW_DIR" ]; then
    echo "workflow ディレクトリが見つかりません: $WORKFLOW_DIR" >&2
    exit 1
fi

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

# PR の状態を確かめる。止めるときは exit し、アーカイブしてよいときは return 0
check_pr() {
    local BRANCH BASE_BRANCH
    BRANCH="$(json_field "$STATE_PATH" branch)"
    BASE_BRANCH="$(json_field "$CONFIG_PATH" base_branch)"
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] || { [ -n "$BASE_BRANCH" ] && [ "$BRANCH" = "$BASE_BRANCH" ]; }; then
        return 0
    fi

    if ! command -v gh > /dev/null 2>&1; then
        echo "gh not found: cannot check the PR state of '$BRANCH' (use --force to archive anyway)" >&2
        echo "Next: escalate reason=gh-unavailable"
        exit 4
    fi

    GH_CODE=0
    GH_OUT_FILE="$(mktemp)"
    GH_ERR_FILE="$(mktemp)"
    trap 'rm -f "$GH_OUT_FILE" "$GH_ERR_FILE"' EXIT
    gh pr view "$BRANCH" --json state,url > "$GH_OUT_FILE" 2> "$GH_ERR_FILE" || GH_CODE=$?
    if [ "$GH_CODE" -ne 0 ]; then
        if grep -qi 'no pull request' "$GH_ERR_FILE"; then
            # PR 未作成: ブランチに比較先へ入っていないコミットがあれば、まだサイクルが終わっていないとみなす
            if ! git rev-parse --verify --quiet "refs/heads/$BRANCH" > /dev/null; then
                return 0   # ローカルにブランチが無い(失う作業が無い)
            fi
            local BASE BASE_REF COUNT
            BASE="${BASE_BRANCH:-main}"
            BASE_REF=""
            if git rev-parse --verify --quiet "refs/heads/$BASE" > /dev/null; then
                BASE_REF="refs/heads/$BASE"
            elif git rev-parse --verify --quiet "refs/remotes/origin/$BASE" > /dev/null; then
                BASE_REF="refs/remotes/origin/$BASE"
            fi
            if [ -n "$BASE_REF" ]; then
                COUNT="$(git rev-list --count "$BASE_REF..refs/heads/$BRANCH")"
                [ "$COUNT" -eq 0 ] && return 0
                echo "NO_PR"
                echo "$COUNT commit(s) on '$BRANCH' are not in '$BASE' and no PR exists (create the PR and add tasks to the current cycle, or use --force to archive anyway)" >&2
            else
                echo "NO_PR"
                echo "'$BASE' not found: cannot check whether '$BRANCH' is merged (use --force to archive anyway)" >&2
            fi
            echo "Next: escalate reason=pr-not-created"
            exit 5
        fi
        echo "gh pr view failed (exit $GH_CODE): $(cat "$GH_ERR_FILE")" >&2
        echo "Next: escalate reason=gh-unavailable"
        exit 4
    fi

    local PR_INFO PR_STATE PR_URL
    PR_INFO="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(str(data.get('state', '')), str(data.get('url', '')))
" "$(to_py_path "$GH_OUT_FILE")")" || {
        echo "Failed to parse gh pr view output (expected JSON with 'state')" >&2
        echo "Next: escalate reason=gh-unavailable"
        exit 4
    }
    PR_STATE="${PR_INFO%% *}"
    PR_URL="${PR_INFO#* }"

    case "$PR_STATE" in
        OPEN)
            echo "OPEN $PR_URL"
            echo "PR for '$BRANCH' is not merged yet (add tasks to the current cycle instead, or use --force to archive anyway)" >&2
            echo "Next: escalate reason=pr-open"
            exit 2
            ;;
        CLOSED)
            echo "CLOSED $PR_URL"
            echo "PR for '$BRANCH' is CLOSED without merging (use --force to archive anyway)" >&2
            echo "Next: escalate reason=pr-closed"
            exit 3
            ;;
        MERGED)
            return 0
            ;;
        *)
            echo "Unexpected PR state: '$PR_STATE'" >&2
            exit 1
            ;;
    esac
}

TIMESTAMP="$(date '+%Y%m%d-%H%M')"
ARCHIVE_DIR="$WORKFLOW_DIR/archive/${TIMESTAMP}-${SLUG}"

TARGETS="tasks.md state.json runs comprehension"
EXISTING=""
for name in $TARGETS; do
    if [ -e "$WORKFLOW_DIR/$name" ]; then
        EXISTING="$EXISTING $name"
    fi
done

if [ -z "$EXISTING" ]; then
    echo "移動対象がありません(tasks.md / state.json / runs/ / comprehension/ のいずれも存在しません)" >&2
    exit 1
fi

[ "$FORCE" -eq 1 ] || check_pr

# runs/*/worktree.txt がある run の worktree とブランチを消す(失敗しても続ける)
drop_run_worktrees() {
    local txt wt branch
    for txt in "$WORKFLOW_DIR"/runs/*/worktree.txt; do
        [ -f "$txt" ] || continue
        wt="$(sed -n 's/^path //p' "$txt" | head -n 1 | tr -d '\r')"
        branch="$(sed -n 's/^branch //p' "$txt" | head -n 1 | tr -d '\r')"
        branch="${branch#refs/heads/}"
        [ -n "$branch" ] || branch="agents-run/$(basename "$(dirname "$txt")")"
        if [ -n "$wt" ] && [ -d "$wt" ]; then
            git worktree remove --force "$wt" >&2 || echo "worktree の削除に失敗しました: $wt" >&2
        fi
        if git rev-parse --verify -q "refs/heads/$branch" > /dev/null; then
            git branch -D -q "$branch" >&2 || echo "ブランチの削除に失敗しました: $branch" >&2
        fi
    done
}

drop_run_worktrees

mkdir -p "$ARCHIVE_DIR"

for name in $EXISTING; do
    mv "$WORKFLOW_DIR/$name" "$ARCHIVE_DIR/$name"
done

git worktree prune >&2 || true

echo "Archived: $ARCHIVE_DIR ($(echo "$EXISTING" | sed 's/^ //;s/ /, /g'))"
