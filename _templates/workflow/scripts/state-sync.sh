#!/bin/bash
set -euo pipefail

# On Windows (Git Bash + native python3), argv/file I/O default to the
# system codepage and mangle non-ASCII (Japanese) text. Force UTF-8.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

INIT=false
SOURCE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --init) INIT=true; shift ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

TASKS_PATH="$ROOT/.agents/workflow/tasks.md"
STATE_PATH="$ROOT/.agents/workflow/state.json"

if [ ! -f "$TASKS_PATH" ]; then
    echo "tasks.md not found: $TASKS_PATH" >&2
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
TASKS_PATH_PY="$(to_py_path "$TASKS_PATH")"
STATE_PATH_PY="$(to_py_path "$STATE_PATH")"

if [ "$INIT" = true ]; then
    if [ -z "$SOURCE" ]; then
        echo "--source is required with --init" >&2
        exit 1
    fi
    if [ -f "$STATE_PATH" ]; then
        echo "state.json already exists: $STATE_PATH (use normal sync mode to append, not --init)" >&2
        exit 1
    fi
    BRANCH="$(git branch --show-current)"
else
    if [ ! -f "$STATE_PATH" ]; then
        echo "state.json not found: $STATE_PATH (run with --init first)" >&2
        exit 1
    fi
    BRANCH=""
fi

python3 -c "
import json, re, sys, datetime

tasks_path = '$TASKS_PATH_PY'
state_path = '$STATE_PATH_PY'
init = $( [ "$INIT" = true ] && echo True || echo False )
source = sys.argv[1]
branch = sys.argv[2]

with open(tasks_path, encoding='utf-8') as f:
    content = f.read()

tasks_in_file = {}
order = []
for line in content.split('\n'):
    m = re.match(r'^## (T\d+):\s*(.+)', line)
    if m:
        tid, title = m.group(1), m.group(2).strip()
        if tid not in tasks_in_file:
            order.append(tid)
        tasks_in_file[tid] = title

if not tasks_in_file:
    print('No task headings found in ' + tasks_path, file=sys.stderr)
    sys.exit(1)

now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')

if init:
    tasks = [
        {'id': tid, 'title': tasks_in_file[tid], 'status': 'pending', 'retries': 0, 'commit': None}
        for tid in order
    ]
    state = {'source': source, 'branch': branch, 'updated_at': now, 'tasks': tasks}
else:
    with open(state_path, encoding='utf-8') as f:
        existing = json.load(f)
    existing_ids = {t['id'] for t in existing['tasks']}
    tasks = list(existing['tasks'])
    for tid in order:
        if tid not in existing_ids:
            tasks.append({'id': tid, 'title': tasks_in_file[tid], 'status': 'pending', 'retries': 0, 'commit': None})
    for tid in existing_ids:
        if tid not in tasks_in_file:
            print(\"state.json has task '\" + tid + \"' not present in tasks.md (not removed)\", file=sys.stderr)
    state = {'source': existing['source'], 'branch': existing['branch'], 'updated_at': now, 'tasks': tasks}

with open(state_path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write('\n')
" "$SOURCE" "$BRANCH"

echo "Synced: $STATE_PATH"
