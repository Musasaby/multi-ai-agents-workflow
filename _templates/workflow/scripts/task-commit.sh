#!/bin/bash
set -uo pipefail

# in_review のタスクの本体をコミットし、state.json を done にして、状態ファイルもコミットする。
# Usage: task-commit.sh <TaskId> <type> <説明>
#   1. 検証: TaskId の形式・type(feat|fix|refactor|docs|test|chore|perf|ci)・説明(空でなく改行なし)・
#      state.json の対象タスクが in_review
#   2. branch-check.sh --state が非0なら、その出力を流して exit 10 + その code
#   3. .agents/workflow を除く変更をステージする。ステージが空なら exit 20
#   4. "<type>: <説明>" + 空行 + "Task: <TaskId> (<state.json の source>)" でコミットする
#   5. task-state.sh <TaskId> done --commit <本体のハッシュ>
#   6. state.json・tasks.md・comprehension のうち git に無視されていないものを
#      "chore: <TaskId> の進捗状態を更新" でコミットする(追跡しないリポジトリでは何もしない)
# exit: 0=コミットした / 1=使い方不備・検証失敗 / 11〜15=branch-check の exit 1〜5 /
#       20=コミットする変更が無い / 30=git commit 失敗 / 31=task-state の done 失敗
# stdout の最後の行に "Next: <行動>" を出す: 0=continue / 20=escalate reason=no-changes

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

USAGE="Usage: task-commit.sh <TaskId> <feat|fix|refactor|docs|test|chore|perf|ci> <説明>"
if [ $# -ne 3 ]; then
    echo "$USAGE" >&2
    exit 1
fi
TASK_ID="$1"
TYPE="$2"
DESC="$3"

if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid TaskId: '$TASK_ID'" >&2
    exit 1
fi
case "$TYPE" in
    feat|fix|refactor|docs|test|chore|perf|ci) ;;
    *) echo "Invalid type: '$TYPE'
$USAGE" >&2; exit 1 ;;
esac
if [ -z "$DESC" ]; then
    echo "Description must not be empty" >&2
    exit 1
fi
case "$DESC" in
    *$'\n'*|*$'\r'*) echo "Description must not contain a newline" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
STATE_PATH=".agents/workflow/state.json"
if [ ! -f "$STATE_PATH" ]; then
    echo "state.json not found: $STATE_PATH" >&2
    exit 1
fi

to_py_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# --- 1. state.json の検証(対象タスクが in_review)と source の取得 ---
SOURCE="$(python3 - "$(to_py_path "$STATE_PATH")" "$TASK_ID" <<'PY'
import json, sys
path, task_id = sys.argv[1:3]
with open(path, encoding='utf-8-sig') as f:
    state = json.load(f)
task = next((t for t in state.get('tasks', []) if t.get('id') == task_id), None)
if task is None:
    print("Task '" + task_id + "' not found in state.json", file=sys.stderr)
    sys.exit(1)
if task.get('status') != 'in_review':
    print(task_id + ": status is '" + str(task.get('status')) + "' (expected in_review)", file=sys.stderr)
    sys.exit(1)
print(state.get('source') or '')
PY
)" || exit 1

# --- 2. ブランチの判定 ---
bash "$SCRIPT_DIR/branch-check.sh" --state
BC_CODE=$?
if [ "$BC_CODE" -ne 0 ]; then
    exit $((10 + BC_CODE))
fi

# --- 3. 本体のステージ ---
git add -A -- . ':(exclude).agents/workflow'
if git diff --cached --quiet; then
    echo "No changes to commit for $TASK_ID" >&2
    echo "Next: escalate reason=no-changes"
    exit 20
fi

# --- 4. 本体のコミット ---
MSG_FILE="$(mktemp)"
trap 'rm -f "$MSG_FILE"' EXIT
printf '%s: %s\n\nTask: %s (%s)\n' "$TYPE" "$DESC" "$TASK_ID" "$SOURCE" > "$MSG_FILE"
if ! git commit -q -F "$MSG_FILE"; then
    echo "git commit failed" >&2
    exit 30
fi
HASH="$(git rev-parse HEAD)"

# --- 5. 状態を done にする ---
if ! bash "$SCRIPT_DIR/task-state.sh" "$TASK_ID" done --commit "$HASH" > /dev/null; then
    echo "task-state.sh done failed (the body commit $HASH was already created)" >&2
    exit 31
fi

# --- 6. 状態ファイルのコミット(無視されていないものだけ) ---
for P in .agents/workflow/state.json .agents/workflow/tasks.md .agents/workflow/comprehension; do
    if [ -e "$P" ] && ! git check-ignore -q "$P"; then
        git add -- "$P"
    fi
done
STATE_COMMIT="none"
if ! git diff --cached --quiet; then
    if ! git commit -q -m "chore: $TASK_ID の進捗状態を更新"; then
        echo "git commit (state files) failed" >&2
        exit 30
    fi
    STATE_COMMIT="$(git rev-parse HEAD | cut -c1-7)"
fi

echo "Committed: ${HASH:0:7} $TYPE: $DESC"
echo "State commit: $STATE_COMMIT"
echo "Next: continue"
exit 0
