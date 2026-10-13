#!/bin/bash
set -euo pipefail

# 次に処理するタスクを state.json と tasks.md の依存関係から機械的に選ぶ。
#   1. in_progress / in_review のタスク(再開対象)があれば、state.json 上で最初のもの
#   2. なければ、依存タスクがすべて done の最初の pending タスク
# branch_per_group が有効で tasks.md にグループ区切りがある場合は、state.json の
# group(現在の作業グループ。無い/未知のグループ名なら「未完了タスクを含む最初のグループ」)
# のタスクだけを候補にする。作業グループが全タスク done で他グループに未完了があれば
# stdout に作業グループ名を出して exit 6(グループ境界で停止する合図)。
# stdout: "<タスクID> <status>" / グループ完了時は "<作業グループ名>"
# exit: 0=該当あり / 1=使い方・tasks.md/state.json 不備 / 3=全タスク done /
#       4=実行可能なタスクなし / 6=作業グループ完了(他グループに未完了あり)

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
# tasklib を import しても scripts/__pycache__ を作らない(利用先の作業ツリーを汚さないため)
export PYTHONDONTWRITEBYTECODE=1

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

to_py_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

python3 - "$(to_py_path "$SCRIPT_DIR")" "$(to_py_path "$TASKS_PATH")" "$(to_py_path "$STATE_PATH")" "$(to_py_path "$CONFIG_PATH")" <<'PY'
import json, sys

script_dir, tasks_path, state_path, config_path = sys.argv[1:5]
sys.path.insert(0, script_dir)
import tasklib

with open(tasks_path, encoding='utf-8', newline='') as f:
    content = f.read()
tasks = tasklib.parse_tasks(content)
try:
    graph = tasklib.resolve_deps(tasks, check_cycles=True)
    tasklib.check_group_deps(tasks, tasklib.group_order(content))
except tasklib.TaskFileError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)

with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
state_tasks = state['tasks']
status = {t['id']: t['status'] for t in state_tasks}
if not state_tasks:
    print('state.json has no tasks', file=sys.stderr)
    sys.exit(1)

# config.json が無い・読めない場合は branch_per_group の既定値(true)を使う
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

for t in state_tasks:
    if t['status'] in ('in_progress', 'in_review'):
        print(t['id'] + ' ' + t['status'])
        sys.exit(0)

if all(t['status'] == 'done' for t in state_tasks):
    print('All tasks are done', file=sys.stderr)
    sys.exit(3)

if group_mode:
    work_group = state.get('group')
    if work_group is None or work_group not in group_names:
        # group フィールドが無い(または未知の名前の)既存 state.json は後方互換として、
        # 未完了タスクを含む最初のグループを作業グループとみなす(next-task は書き換えない)
        work_group = unfinished_group()
        if work_group is None:
            # 到達しないはず(全タスク done なら上で exit 3)
            work_group = group_names[0]
    candidates = [t for t in state_tasks if group_of.get(t['id']) == work_group]
    others = [t for t in state_tasks if group_of.get(t['id']) != work_group]
    if candidates and all(t['status'] == 'done' for t in candidates) \
            and any(t['status'] != 'done' for t in others):
        print(work_group)
        sys.exit(6)
else:
    candidates = state_tasks

blocked = []
for t in candidates:
    if t['status'] != 'pending':
        continue
    if t['id'] not in graph:
        print("Task '" + t['id'] + "' is in state.json but not in tasks.md", file=sys.stderr)
        sys.exit(1)
    waiting = [d for d in graph[t['id']] if status.get(d) != 'done']
    if not waiting:
        print(t['id'] + ' pending')
        sys.exit(0)
    blocked.append(t['id'] + ': waiting for ' + ', '.join(d + '(' + status.get(d, 'missing') + ')' for d in waiting))

print('No runnable task. Blocked:', file=sys.stderr)
for b in blocked:
    print('  ' + b, file=sys.stderr)
for t in candidates:
    if t['status'] == 'failed':
        print('  ' + t['id'] + ': failed', file=sys.stderr)
sys.exit(4)
PY
