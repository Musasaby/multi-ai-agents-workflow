#!/bin/bash
set -uo pipefail

# グループ完了後の PR 状態を gh で機械的に判定し、マージ済みなら次グループのブランチへ
# 切り替える(Issue #30 改善提案 3)。state.json の branch / group を更新する。
# Usage: group-advance.sh [--branch <新ブランチ名>]
# 前提チェック(満たさなければ exit 1。何も書き換えない):
#   - next-task 相当の判定で作業グループが完了していること
#   - git status --porcelain が空であること
# gh pr view <state.json の branch> --json state,url の結果で分岐する:
#   - PR なし(gh が「no pull requests found」で失敗)→ stdout "NO_PR"、exit 7(親は PR 作成へ)
#   - OPEN   → stdout "OPEN <PR URL>"、exit 8(マージ待ち。親は報告して停止)。
#              ただしローカルのブランチに origin/<branch> へ未 push のコミットがある、または
#              origin/<branch> が無い場合は exit 10(PR の更新へ。fetch はしない)
#   - CLOSED → PR がマージされずに閉じている。stderr に説明、exit 9(エスカレーション)
#   - MERGED → main を最新化(git switch main + git pull --ff-only)し、--branch で指定した
#              名前(develop/ 始まり。必須)のブランチを作成・切替。state.json の branch を
#              新ブランチ名、group を次のグループ(未完了タスクを含む最初のグループ)に更新
#              して exit 0。stdout に "ADVANCED <新ブランチ名> <新グループ名>"
# exit: 0=切替完了 / 1=使い方・前提不備 / 7=PR 未作成 / 8=マージ待ち / 9=PR 閉鎖(未マージ) /
#       10=PR 更新が必要(OPEN で未 push のコミットがある、または origin/<branch> が無い)
#       git / gh の失敗時は何も書き換えず、その exit code を返す
# stdout の最後の行は次アクションを示す "Next:" 行(0=continue / 7=create-pr / 8=wait-merge /
# 9=escalate reason=pr-closed / 10=update-pr)。1 と git / gh の失敗をそのまま返す exit では出力しない

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
# tasklib を import しても scripts/__pycache__ を作らない(利用先の作業ツリーを汚さないため)
export PYTHONDONTWRITEBYTECODE=1

USAGE="Usage: group-advance.sh [--branch <new-branch-name>]"
NEW_BRANCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch)
            if [ $# -lt 2 ]; then echo "--branch requires a value" >&2; exit 1; fi
            NEW_BRANCH="$2"; shift 2 ;;
        *) echo "Unknown argument: $1
$USAGE" >&2; exit 1 ;;
    esac
done
if [ -n "$NEW_BRANCH" ] && [ "${NEW_BRANCH#develop/}" = "$NEW_BRANCH" ]; then
    echo "Invalid --branch: '$NEW_BRANCH' (must start with 'develop/')" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

TASKS_PATH="$ROOT/.agents/workflow/tasks.md"
STATE_PATH="$ROOT/.agents/workflow/state.json"
CONFIG_PATH="$ROOT/.agents/workflow/config.json"

for p in "$TASKS_PATH" "$STATE_PATH"; do
    if [ ! -f "$p" ]; then
        echo "not found: $p" >&2
        exit 1
    fi
done

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

# --- 前提チェック: 作業グループの完了判定(next-task と同じグループ判定) ---
# 成功時は stdout に 4 行で出力する: state の branch / 作業グループ名 /
# 次グループ名(既定グループは空文字列) / 次グループの有無(1=あり, 0=全タスク done)
GROUP_INFO="$(python3 - "$(to_py_path "$SCRIPT_DIR")" "$(to_py_path "$TASKS_PATH")" "$(to_py_path "$STATE_PATH")" "$(to_py_path "$CONFIG_PATH")" <<'PY'
import json, sys

script_dir, tasks_path, state_path, config_path = sys.argv[1:5]
sys.path.insert(0, script_dir)
import tasklib

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

with open(tasks_path, encoding='utf-8', newline='') as f:
    content = f.read()
try:
    tasks = tasklib.parse_tasks(content)
    tasklib.resolve_deps(tasks, check_cycles=True)
    tasklib.check_group_deps(tasks, tasklib.group_order(content))
except tasklib.TaskFileError as e:
    fail(str(e))

with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
state_tasks = state['tasks']
if not state_tasks:
    fail('state.json has no tasks')
status = {t['id']: t['status'] for t in state_tasks}

try:
    with open(config_path, encoding='utf-8') as f:
        config = json.load(f)
except OSError:
    config = {}
branch_per_group = config.get('branch_per_group', True)

group_of = {t['id']: t['group'] for t in tasks}
group_names = tasklib.group_order(content)
# branch_per_group が false、またはグループ区切りが無い場合は全タスクを1グループとして扱う
group_mode = bool(branch_per_group) and any(name != tasklib.DEFAULT_GROUP for name in group_names)

def unfinished_group():
    """未完了タスクを含む最初のグループ(group_names 順)。なければ None。"""
    for name in group_names:
        if any(status.get(tid) != 'done' for tid, g in group_of.items() if g == name):
            return name
    return None

if group_mode:
    work_group = state.get('group')
    if work_group is None or work_group not in group_names:
        fail("state.json 'group' is missing or unknown: '" + str(work_group)
             + "' (group-advance is only for the group boundary reported by next-task, exit 6)")
    candidates = [t for t in state_tasks if group_of.get(t['id']) == work_group]
else:
    work_group = tasklib.DEFAULT_GROUP
    candidates = state_tasks

if not candidates:
    fail("No tasks belong to the work group '" + str(work_group) + "'")
not_done = [t['id'] for t in candidates if t['status'] != 'done']
if not_done:
    fail('Work group is not complete: ' + ', '.join(not_done)
         + ' (group-advance is only for the group boundary reported by next-task, exit 6)')

next_group = unfinished_group()
print(str(state.get('branch') or ''))
print(work_group)
print(next_group if next_group is not None else '')
print('1' if next_group is not None else '0')
PY
)" || exit 1

STATE_BRANCH="$(printf '%s\n' "$GROUP_INFO" | sed -n 1p)"
WORK_GROUP="$(printf '%s\n' "$GROUP_INFO" | sed -n 2p)"
NEXT_GROUP="$(printf '%s\n' "$GROUP_INFO" | sed -n 3p)"
HAS_NEXT_GROUP="$(printf '%s\n' "$GROUP_INFO" | sed -n 4p)"

if [ -z "$STATE_BRANCH" ]; then
    echo "state.json has no branch (run next-task / state-sync first)" >&2
    exit 1
fi

# --- 前提チェック: 作業ツリーが clean であること ---
GIT_STATUS="$(git status --porcelain 2>&1)"
GIT_CODE=$?
if [ "$GIT_CODE" -ne 0 ]; then
    echo "git status failed (exit $GIT_CODE): $GIT_STATUS" >&2
    exit "$GIT_CODE"
fi
if [ -n "$GIT_STATUS" ]; then
    echo "Working tree is not clean (commit or stash before advancing the group):
$GIT_STATUS" >&2
    exit 1
fi

# --- PR 状態の判定(gh の失敗は「PR なし」のメッセージだけ例外的に NO_PR 扱い) ---
GH_OUT_FILE="$(mktemp)"
GH_ERR_FILE="$(mktemp)"
trap 'rm -f "$GH_OUT_FILE" "$GH_ERR_FILE" "${GIT_ERR_FILE:-}"' EXIT

gh pr view "$STATE_BRANCH" --json state,url > "$GH_OUT_FILE" 2> "$GH_ERR_FILE"
GH_CODE=$?
if [ "$GH_CODE" -ne 0 ]; then
    GH_ERR="$(cat "$GH_ERR_FILE")"
    if printf '%s' "$GH_ERR" | grep -qi 'no pull request'; then
        echo "NO_PR"
        echo "Next: create-pr"
        exit 7
    fi
    echo "gh pr view failed (exit $GH_CODE): $GH_ERR" >&2
    exit "$GH_CODE"
fi

PR_INFO="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(str(data.get('state', '')), str(data.get('url', '')))
" "$(to_py_path "$GH_OUT_FILE")")" || {
    echo "Failed to parse gh pr view output (expected JSON with 'state')" >&2
    exit 1
}
PR_STATE="${PR_INFO%% *}"
PR_URL="${PR_INFO#* }"

case "$PR_STATE" in
    OPEN)
        # 未 push のコミットがあれば既存 PR の更新を促す(fetch はせず、リモート追跡ブランチと比べる)
        REMOTE_REF="refs/remotes/origin/$STATE_BRANCH"
        if ! git rev-parse --verify --quiet "$REMOTE_REF" > /dev/null; then
            echo "OPEN $PR_URL"
            echo "'origin/$STATE_BRANCH' not found (the branch is not pushed from this clone; push it and update the PR)" >&2
            echo "Next: update-pr"
            exit 10
        fi
        UNPUSHED="$(git rev-list --count "$REMOTE_REF..refs/heads/$STATE_BRANCH" 2>&1)"
        GIT_CODE=$?
        if [ "$GIT_CODE" -ne 0 ]; then
            echo "git rev-list failed (exit $GIT_CODE): $UNPUSHED" >&2
            exit "$GIT_CODE"
        fi
        echo "OPEN $PR_URL"
        if [ "$UNPUSHED" -gt 0 ]; then
            echo "$UNPUSHED commit(s) on '$STATE_BRANCH' are not pushed to 'origin/$STATE_BRANCH' (push them and update the PR)" >&2
            echo "Next: update-pr"
            exit 10
        fi
        echo "Next: wait-merge"
        exit 8
        ;;
    MERGED)
        ;;  # 後続の切替処理に進む
    CLOSED)
        echo "PR for '$STATE_BRANCH' is CLOSED without merging (escalate: check why it was closed, then reopen or recreate the PR)" >&2
        echo "Next: escalate reason=pr-closed"
        exit 9
        ;;
    *)
        echo "Unexpected PR state: '$PR_STATE' (expected OPEN, MERGED or CLOSED)" >&2
        exit 1
        ;;
esac

# --- MERGED: 次グループのブランチを作成して切替し、state.json を更新する ---
if [ -z "$NEW_BRANCH" ]; then
    echo "$USAGE
--branch <new-branch-name> is required when the PR is merged (the next group works on a new branch)" >&2
    exit 1
fi
if [ "$HAS_NEXT_GROUP" != "1" ]; then
    echo "No group with unfinished tasks remains; nothing to advance to" >&2
    exit 1
fi

GIT_ERR_FILE="$(mktemp)"

git switch main > /dev/null 2> "$GIT_ERR_FILE"
GIT_CODE=$?
if [ "$GIT_CODE" -ne 0 ]; then
    echo "git switch main failed (exit $GIT_CODE): $(cat "$GIT_ERR_FILE")" >&2
    exit "$GIT_CODE"
fi

git pull --ff-only > /dev/null 2> "$GIT_ERR_FILE"
GIT_CODE=$?
if [ "$GIT_CODE" -ne 0 ]; then
    echo "git pull --ff-only failed (exit $GIT_CODE): $(cat "$GIT_ERR_FILE")" >&2
    exit "$GIT_CODE"
fi

git switch -c "$NEW_BRANCH" > /dev/null 2> "$GIT_ERR_FILE"
GIT_CODE=$?
if [ "$GIT_CODE" -ne 0 ]; then
    echo "git switch -c '$NEW_BRANCH' failed (exit $GIT_CODE): $(cat "$GIT_ERR_FILE")" >&2
    exit "$GIT_CODE"
fi

if ! python3 - "$(to_py_path "$STATE_PATH")" "$NEW_BRANCH" "$NEXT_GROUP" <<'PY'
import datetime, json, sys

state_path, branch, group = sys.argv[1:4]
with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
state['branch'] = branch
state['group'] = group
state['updated_at'] = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
with open(state_path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
then
    echo "Failed to update state.json (the new branch is already created: '$NEW_BRANCH')" >&2
    exit 1
fi

STATE_REL=".agents/workflow/state.json"
STATE_COMMIT="none"
if ! git check-ignore -q "$STATE_REL"; then
    if [ -n "$NEXT_GROUP" ]; then
        COMMIT_MSG="chore: $NEXT_GROUP グループの作業を開始"
    else
        COMMIT_MSG="chore: 既定グループの作業を開始"
    fi
    git add -- "$STATE_REL" 2> "$GIT_ERR_FILE"
    GIT_CODE=$?
    if [ "$GIT_CODE" -ne 0 ]; then
        echo "git add '$STATE_REL' failed (exit $GIT_CODE): $(cat "$GIT_ERR_FILE")" >&2
        exit 1
    fi
    if ! git diff --cached --quiet -- "$STATE_REL"; then
        git commit -q -m "$COMMIT_MSG" > /dev/null 2> "$GIT_ERR_FILE"
        GIT_CODE=$?
        if [ "$GIT_CODE" -ne 0 ]; then
            echo "git commit failed (exit $GIT_CODE): $(cat "$GIT_ERR_FILE")" >&2
            exit 1
        fi
        STATE_COMMIT="$(git rev-parse --short=7 HEAD)"
    fi
fi

echo "ADVANCED $NEW_BRANCH $NEXT_GROUP"
echo "State commit: $STATE_COMMIT"
echo "Next: continue"
