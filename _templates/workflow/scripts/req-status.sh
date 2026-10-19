#!/bin/bash
set -euo pipefail

# 要件ごとの充足状況(対応タスクの状態)の一覧を tasks.md と state.json から機械生成する(読み取り専用)。
# 引数は取らない。
# stdout: 要件ごとに "Requirement R1 [done|partial|pending]: T1(done abc1234), T2(pending) | <要件の本文>"、
#       要件欄が 'なし' のタスクがあれば "Requirement なし: ..."、最後に "Summary: done=<n> partial=<n> pending=<n>"。
#       要件の節も欄も無ければ "No requirements section"
# exit: 0=出力あり / 1=使い方・tasks.md/state.json 不備

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
# tasklib を import しても scripts/__pycache__ を作らない(利用先の作業ツリーを汚さないため)
export PYTHONDONTWRITEBYTECODE=1

if [ "$#" -ne 0 ]; then
    echo "Usage: req-status.sh" >&2
    exit 1
fi

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

sys.stdout.reconfigure(newline='\n')

script_dir, tasks_path, state_path = sys.argv[1:4]
sys.path.insert(0, script_dir)
import tasklib

with open(tasks_path, encoding='utf-8', newline='') as f:
    content = f.read()
with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
try:
    tasks = tasklib.parse_tasks(content)
    lines = tasklib.requirement_status_lines(tasks, content, state['tasks'])
except tasklib.TaskFileError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
if not lines:
    print('No requirements section')
for line in lines:
    print(line)
PY
