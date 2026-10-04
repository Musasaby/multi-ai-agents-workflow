#!/bin/bash
set -euo pipefail

# 次に処理するタスクを state.json と tasks.md の依存関係から機械的に選ぶ。
#   1. in_progress / in_review のタスク(再開対象)があれば、state.json 上で最初のもの
#   2. なければ、依存タスクがすべて done の最初の pending タスク
# stdout: "<タスクID> <status>"
# exit: 0=該当あり / 1=使い方・tasks.md/state.json 不備 / 3=全タスク done / 4=実行可能なタスクなし

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

TASKS_PATH="$ROOT/.agents/workflow/tasks.md"
STATE_PATH="$ROOT/.agents/workflow/state.json"

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

python3 - "$(to_py_path "$SCRIPT_DIR")" "$(to_py_path "$TASKS_PATH")" "$(to_py_path "$STATE_PATH")" <<'PY'
import json, sys

script_dir, tasks_path, state_path = sys.argv[1:4]
sys.path.insert(0, script_dir)
import tasklib

with open(tasks_path, encoding='utf-8', newline='') as f:
    tasks = tasklib.parse_tasks(f.read())
try:
    graph = tasklib.resolve_deps(tasks, check_cycles=True)
except tasklib.TaskFileError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)

with open(state_path, encoding='utf-8') as f:
    state_tasks = json.load(f)['tasks']
status = {t['id']: t['status'] for t in state_tasks}

for t in state_tasks:
    if t['status'] in ('in_progress', 'in_review'):
        print(t['id'] + ' ' + t['status'])
        sys.exit(0)

if all(t['status'] == 'done' for t in state_tasks):
    print('All tasks are done', file=sys.stderr)
    sys.exit(3)

blocked = []
for t in state_tasks:
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
for t in state_tasks:
    if t['status'] == 'failed':
        print('  ' + t['id'] + ': failed', file=sys.stderr)
sys.exit(4)
PY
