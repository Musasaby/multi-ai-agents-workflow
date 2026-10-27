#!/bin/bash
set -uo pipefail

# 子エージェントの run 用の git worktree を作る・集める・消す。
# Usage: dispatch-worktree.sh <create|collect|remove> <TaskId> <Attempt>
#   RUN=.agents/workflow/runs/<TaskId>-<Attempt>、WT=$RUN/worktree、ブランチ=agents-run/<TaskId>-<Attempt>
#   create : WT を HEAD から作る。試行回数が 2 以上なら、前の試行の変更を取り除いてから、
#            新しい WT に 3way で持ち越す。$RUN/worktree.txt(path / branch / base の3行)を書く
#   collect: (未実装)
#   remove : WT とブランチと $RUN/worktree.txt を消す(無くてもエラーにしない)
# exit: 0=成功 / 1=使い方不備 / 20=dirty-tree(前の試行の変更を本体から取り除けない) /
#   30=worktree(WT が既にある・作成に失敗) / 40=conflict(collect)
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(continue / escalate reason=<理由>。
# 使い方不備の exit 1 では出さない)

ACTION="${1:?Usage: dispatch-worktree.sh <create|collect|remove> <TaskId> <Attempt>}"
TASK_ID="${2:?Usage: dispatch-worktree.sh <create|collect|remove> <TaskId> <Attempt>}"
ATTEMPT="${3:?Usage: dispatch-worktree.sh <create|collect|remove> <TaskId> <Attempt>}"
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]] || [ "$ATTEMPT" -lt 1 ]; then
    echo "Invalid TaskId/Attempt: '$TASK_ID' '$ATTEMPT'" >&2
    exit 1
fi
case "$ACTION" in
    create | collect | remove) ;;
    *)
        echo "Invalid action: '$ACTION' (create|collect|remove)" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

RUN=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
WT="$RUN/worktree"
BRANCH="agents-run/${TASK_ID}-${ATTEMPT}"

abs_path() {
    local p
    p="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$p"
    else
        echo "$p"
    fi
}

# wt の変更(未追跡を含む。.agents/workflow は除く)を out にバイナリ対応のパッチで書く
make_patch() {
    local wt="$1" out="$2"
    git -C "$wt" add -A
    git -C "$wt" diff --cached --binary HEAD -- . ':(exclude).agents/workflow' > "$out"
    git -C "$wt" reset -q
}

# wt・ブランチ・wt の隣の worktree.txt を消す(無いものは飛ばす)
drop_worktree() {
    local wt="$1" branch="$2"
    if [ -d "$wt" ]; then
        git worktree remove --force "$wt"
    fi
    if git rev-parse --verify -q "refs/heads/$branch" > /dev/null; then
        git branch -D -q "$branch"
    fi
    rm -f "$(dirname "$wt")/worktree.txt"
}

case "$ACTION" in
    remove)
        drop_worktree "$WT" "$BRANCH"
        echo "Next: continue"
        exit 0
        ;;
    collect)
        echo "collect: not implemented" >&2
        exit 1
        ;;
esac

# --- create ---
if [ -e "$WT" ]; then
    echo "worktree already exists: $WT" >&2
    echo "Next: escalate reason=worktree"
    exit 30
fi

CARRY=""
if [ "$ATTEMPT" -ge 2 ]; then
    PREV=".agents/workflow/runs/${TASK_ID}-$((ATTEMPT - 1))"
    PREV_PATCH="$PREV/changes.patch"
    PREV_WT_PATH=""
    if [ -f "$PREV/worktree.txt" ]; then
        PREV_WT_PATH="$(sed -n 's/^path //p' "$PREV/worktree.txt" | head -n 1 | tr -d '\r')"
    fi
    if [ -n "$PREV_WT_PATH" ] && [ -d "$PREV_WT_PATH" ]; then
        make_patch "$PREV_WT_PATH" "$PREV_PATCH"
        drop_worktree "$PREV/worktree" "agents-run/${TASK_ID}-$((ATTEMPT - 1))"
    fi
    if [ -s "$PREV_PATCH" ]; then
        if git apply -R --check "$PREV_PATCH" 2> /dev/null; then
            git apply -R "$PREV_PATCH"
        elif ! git apply --check "$PREV_PATCH" 2> /dev/null; then
            echo "previous attempt's changes can be neither reverted nor applied cleanly: $PREV_PATCH" >&2
            echo "Next: escalate reason=dirty-tree"
            exit 20
        fi
        CARRY="$PREV_PATCH"
    fi
fi

mkdir -p "$RUN"
if ! git worktree add -q -b "$BRANCH" "$WT" HEAD; then
    echo "git worktree add failed: $WT ($BRANCH)" >&2
    echo "Next: escalate reason=worktree"
    exit 30
fi
mkdir -p "$WT/.agents/workflow/runs/${TASK_ID}-${ATTEMPT}/tmp"

WT_ABS="$(abs_path "$WT")"
{
    echo "path $WT_ABS"
    echo "branch refs/heads/$BRANCH"
    echo "base $(git rev-parse HEAD)"
} > "$RUN/worktree.txt"

if [ -n "$CARRY" ]; then
    if git -C "$WT" apply --3way "$(abs_path "$CARRY")"; then
        echo "Carried: $CARRY"
    else
        echo "Carried: conflict $CARRY"
    fi
else
    echo "Carried: none"
fi

echo "Worktree: $WT"
echo "Branch: $BRANCH"
echo "Next: continue"
exit 0
