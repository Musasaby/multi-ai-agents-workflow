#!/bin/bash
set -uo pipefail

# 子エージェントの run 用の git worktree を作る・集める・消す。
# Usage: dispatch-worktree.sh <create|collect|remove|abort> <TaskId> <Attempt>
#   RUN=.agents/workflow/runs/<TaskId>-<Attempt>、WT=$RUN/worktree、ブランチ=agents-run/<TaskId>-<Attempt>
#   create : WT を HEAD から作る。試行回数が 2 以上なら、前の試行の変更を取り除いてから、
#            新しい WT に 3way で持ち越す(前の試行に $RUN/collected が無ければ取り除かず持ち越さない)。
#            取り除いたら $RUN/reverted に前のパッチのパスを書く。$RUN/worktree.txt(path / branch / base の3行)を書く
#   collect: WT の変更を $RUN/changes.patch にして本体へ git apply し、空の $RUN/collected を作って WT を消す。
#            tasks.md の changed に無いファイルは `Undeclared: <path>` で出す
#   remove : WT とブランチと $RUN/worktree.txt を消す(無くてもエラーにしない)
#   abort  : remove と同じく消したうえで、$RUN/reverted があれば、そこに書かれたパッチを本体に git apply で
#            当て直して reverted を消す(当て直せなければ stderr にパッチのパスを出して exit 20)
# exit: 0=成功 / 1=使い方不備 / 20=dirty-tree(前の試行の変更を本体から取り除けない・collect では本体の作業ツリーが clean でない) /
#   30=worktree(WT が既にある・作成に失敗・パッチを作る git の失敗・collect では worktree.txt または WT のディレクトリが無い) /
#   40=conflict(collect。git apply の失敗を含む / create の持ち越しの衝突)
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(continue / escalate reason=<理由>。
# 使い方不備の exit 1 では出さない)

ACTION="${1:?Usage: dispatch-worktree.sh <create|collect|remove|abort> <TaskId> <Attempt>}"
TASK_ID="${2:?Usage: dispatch-worktree.sh <create|collect|remove|abort> <TaskId> <Attempt>}"
ATTEMPT="${3:?Usage: dispatch-worktree.sh <create|collect|remove|abort> <TaskId> <Attempt>}"
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]] || [ "$ATTEMPT" -lt 1 ]; then
    echo "Invalid TaskId/Attempt: '$TASK_ID' '$ATTEMPT'" >&2
    exit 1
fi
case "$ACTION" in
    create | collect | remove | abort) ;;
    *)
        echo "Invalid action: '$ACTION' (create|collect|remove|abort)" >&2
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

# run ディレクトリの worktree.txt の base の値を出す(行が無ければ HEAD)
read_base() {
    local b=""
    if [ -f "$1/worktree.txt" ]; then
        b="$(sed -n 's/^base //p' "$1/worktree.txt" | head -n 1 | tr -d '\r')"
    fi
    echo "${b:-HEAD}"
}

# wt の変更(未追跡を含む。.agents/workflow は除く)の base との差分を out にバイナリ対応のパッチで書く。
# 成功したら 0、git が1つでも失敗したら 1
make_patch() {
    local wt="$1" out="$2" base="$3"
    if ! git -C "$wt" -c core.longpaths=true add -A; then
        echo "git add failed in $wt" >&2
        return 1
    fi
    if ! git -C "$wt" -c core.longpaths=true diff --cached --binary --no-renames "$base" -- . ':(exclude).agents/workflow' > "$out"; then
        git -C "$wt" -c core.longpaths=true reset -q > /dev/null 2>&1
        echo "git diff failed in $wt" >&2
        return 1
    fi
    if ! git -C "$wt" -c core.longpaths=true reset -q; then
        echo "git reset failed in $wt" >&2
        return 1
    fi
    return 0
}

# wt・ブランチ・wt の隣の worktree.txt を消す(無いものは飛ばす)
drop_worktree() {
    local wt="$1" branch="$2"
    if [ -d "$wt" ]; then
        git -c core.longpaths=true worktree remove --force "$wt"
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
    abort)
        drop_worktree "$WT" "$BRANCH"
        if [ -f "$RUN/reverted" ]; then
            REV_PATCH="$(head -n 1 "$RUN/reverted" | tr -d '\r')"
            if [ -z "$REV_PATCH" ] || ! git apply "$REV_PATCH"; then
                echo "failed to re-apply the reverted changes to the main working tree: $REV_PATCH" >&2
                echo "Next: escalate reason=dirty-tree"
                exit 20
            fi
            rm -f "$RUN/reverted"
        fi
        echo "Next: continue"
        exit 0
        ;;
    collect)
        WT_PATH=""
        if [ -f "$RUN/worktree.txt" ]; then
            WT_PATH="$(sed -n 's/^path //p' "$RUN/worktree.txt" | head -n 1 | tr -d '\r')"
        fi
        if [ -z "$WT_PATH" ] || [ ! -d "$WT_PATH" ]; then
            echo "worktree not found: $RUN" >&2
            echo "Next: escalate reason=worktree"
            exit 30
        fi
        DIRTY="$(git status --porcelain -- . ':(exclude).agents/workflow')"
        if [ -n "$DIRTY" ]; then
            echo "main working tree is not clean:" >&2
            echo "$DIRTY" >&2
            echo "Next: escalate reason=dirty-tree"
            exit 20
        fi

        rm -f "$RUN/collected"
        PATCH="$RUN/changes.patch"
        if ! make_patch "$WT_PATH" "$PATCH" "$(read_base "$RUN")"; then
            echo "failed to make the patch from the worktree: $WT_PATH" >&2
            echo "Next: escalate reason=worktree"
            exit 30
        fi
        CHANGED_FILES=""
        if [ -s "$PATCH" ]; then
            CHANGED_FILES="$(git -c core.quotepath=false apply --numstat "$PATCH" | cut -f3-)"
        fi

        # tasks.md の対象タスクが宣言した変更対象(changed)
        DECLARED=""
        if [ -f .agents/workflow/tasks.md ]; then
            DECLARED="$(PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 python3 - "$(abs_path "$SCRIPT_DIR")" "$(abs_path .agents/workflow/tasks.md)" "$TASK_ID" <<'PY'
import sys

sys.stdout.reconfigure(newline='\n')

script_dir, tasks_path, task_id = sys.argv[1:4]
sys.path.insert(0, script_dir)
import tasklib

with open(tasks_path, encoding='utf-8', newline='') as f:
    tasks = tasklib.parse_tasks(f.read())
for t in tasks:
    if t['id'] == task_id:
        for p in t['changed']:
            print(p)
PY
)"
        fi
        UNDECLARED=0
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if ! printf '%s\n' "$DECLARED" | tr -d '\r' | grep -Fxq -- "$f"; then
                echo "Undeclared: $f"
                UNDECLARED=1
            fi
        done <<< "$CHANGED_FILES"
        if [ "$UNDECLARED" -eq 0 ]; then
            echo "Undeclared: none"
        fi

        if [ ! -s "$PATCH" ]; then
            echo "Applied: 0 files"
        else
            if ! CHECK_OUT="$(git apply --check "$PATCH" 2>&1)"; then
                echo "$CHECK_OUT" >&2
                echo "Next: escalate reason=conflict"
                exit 40
            fi
            if ! APPLY_OUT="$(git apply "$PATCH" 2>&1)"; then
                echo "$APPLY_OUT" >&2
                echo "Next: escalate reason=conflict"
                exit 40
            fi
            echo "Applied: $(printf '%s\n' "$CHANGED_FILES" | grep -c .) files"
        fi

        : > "$RUN/collected"
        drop_worktree "$WT" "$BRANCH"
        echo "Patch: $PATCH"
        echo "Next: review $TASK_ID"
        exit 0
        ;;
esac

# --- create ---
if [ -e "$WT" ]; then
    echo "worktree already exists: $WT" >&2
    echo "Next: escalate reason=worktree"
    exit 30
fi

CARRY=""
REVERTED=0
NOT_COLLECTED=""
if [ "$ATTEMPT" -ge 2 ]; then
    PREV=".agents/workflow/runs/${TASK_ID}-$((ATTEMPT - 1))"
    PREV_PATCH="$PREV/changes.patch"
    PREV_WT_PATH=""
    if [ -f "$PREV/worktree.txt" ]; then
        PREV_WT_PATH="$(sed -n 's/^path //p' "$PREV/worktree.txt" | head -n 1 | tr -d '\r')"
    fi
    PREV_HAS_WT=0
    if [ -n "$PREV_WT_PATH" ] && [ -d "$PREV_WT_PATH" ]; then
        PREV_HAS_WT=1
        if ! make_patch "$PREV_WT_PATH" "$PREV_PATCH" "$(read_base "$PREV")"; then
            echo "failed to make the patch from the previous worktree: $PREV_WT_PATH" >&2
            echo "Next: escalate reason=worktree"
            exit 30
        fi
    fi
    if [ -f "$PREV/collected" ]; then
        if [ -s "$PREV_PATCH" ]; then
            if git apply -R --check "$PREV_PATCH" 2> /dev/null; then
                git apply -R "$PREV_PATCH"
                REVERTED=1
                mkdir -p "$RUN"
                echo "$PREV_PATCH" > "$RUN/reverted"
            elif ! git apply --check "$PREV_PATCH" 2> /dev/null; then
                echo "previous attempt's changes can be neither reverted nor applied cleanly: $PREV_PATCH" >&2
                echo "Next: escalate reason=dirty-tree"
                exit 20
            fi
            CARRY="$PREV_PATCH"
        fi
    elif [ -e "$PREV_PATCH" ]; then
        NOT_COLLECTED="$PREV_PATCH"
    fi
    if [ "$PREV_HAS_WT" -eq 1 ]; then
        drop_worktree "$PREV/worktree" "agents-run/${TASK_ID}-$((ATTEMPT - 1))"
    fi
fi

mkdir -p "$RUN"
if ! ADD_OUT="$(git -c core.longpaths=true worktree add -q -b "$BRANCH" "$WT" HEAD 2>&1)"; then
    # 作りかけの WT・ブランチ・worktree.txt を消し、取り除いた前の試行の変更は本体に戻す
    rm -rf "$WT"
    if git rev-parse --verify -q "refs/heads/$BRANCH" > /dev/null; then
        git branch -D -q "$BRANCH"
    fi
    git worktree prune
    rm -f "$RUN/worktree.txt"
    if [ "$REVERTED" -eq 1 ]; then
        git apply "$PREV_PATCH"
        rm -f "$RUN/reverted"
    fi
    echo "git worktree add failed: $WT ($BRANCH)" >&2
    printf '%s\n' "$ADD_OUT" | tr -d '\r' | grep . | tail -n 1 >&2
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
    if git -C "$WT" -c core.longpaths=true apply --3way "$(abs_path "$CARRY")"; then
        echo "Carried: $CARRY"
    else
        drop_worktree "$WT" "$BRANCH"
        if [ "$REVERTED" -eq 1 ]; then
            git apply "$CARRY"
            rm -f "$RUN/reverted"
        fi
        echo "carrying the previous attempt's changes conflicted: $CARRY" >&2
        echo "Next: escalate reason=conflict"
        exit 40
    fi
elif [ -n "$NOT_COLLECTED" ]; then
    echo "Carried: none (not collected: $NOT_COLLECTED)"
else
    echo "Carried: none"
fi

echo "Worktree: $WT"
echo "Branch: $BRANCH"
echo "Next: continue"
exit 0
