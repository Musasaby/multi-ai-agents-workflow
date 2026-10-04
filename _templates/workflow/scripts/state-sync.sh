#!/bin/bash
set -euo pipefail

# On Windows (Git Bash + native python3), argv/file I/O default to the
# system codepage and mangle non-ASCII (Japanese) text. Force UTF-8.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
# tasklib を import しても scripts/__pycache__ を作らない(利用先の作業ツリーを汚さないため)
export PYTHONDONTWRITEBYTECODE=1

INIT=false
SOURCE=""
INSERT=""
BEFORE=""

need_value() {
    if [ "$2" -lt 2 ]; then
        echo "$1 requires a value" >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --init) INIT=true; shift ;;
        --source) need_value "$1" $#; SOURCE="$2"; shift 2 ;;
        --insert) need_value "$1" $#; INSERT="$2"; shift 2 ;;
        --before) need_value "$1" $#; BEFORE="$2"; shift 2 ;;
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

if [ -n "$INSERT" ] || [ -n "$BEFORE" ]; then
    if [ "$INIT" = true ]; then
        echo "--insert cannot be combined with --init" >&2
        exit 1
    fi
    if [ -z "$INSERT" ] || [ -z "$BEFORE" ]; then
        echo "--insert and --before must be given together (e.g. --insert T8 --before T4)" >&2
        exit 1
    fi
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
SCRIPT_DIR_PY="$(to_py_path "$SCRIPT_DIR")"

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

python3 - "$SCRIPT_DIR_PY" "$TASKS_PATH_PY" "$STATE_PATH_PY" "$INIT" "$SOURCE" "$BRANCH" "$INSERT" "$BEFORE" <<'PY'
import json, re, sys, datetime

script_dir, tasks_path, state_path, init, source, branch, insert, before = sys.argv[1:9]
init = init == 'true'
sys.path.insert(0, script_dir)
import tasklib

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

with open(tasks_path, encoding='utf-8', newline='') as f:
    content = f.read()

tasks = tasklib.parse_tasks(content)
if not tasks:
    fail('No task headings found in ' + tasks_path)
by_id = {t['id']: t for t in tasks}

existing = None
if not init:
    with open(state_path, encoding='utf-8') as f:
        existing = json.load(f)
existing_status = {t['id']: t['status'] for t in existing['tasks']} if existing else {}

# --- 挿入: 後続タスクの依存欄に新タスクを追加する(書き込みは検証後) ---
lines = None
if insert:
    if insert not in by_id:
        fail("Task to insert '" + insert + "' not found in tasks.md (append its section first)")
    if insert in existing_status and existing_status[insert] != 'pending':
        fail("Task to insert '" + insert + "' already exists in state.json with status '"
             + existing_status[insert] + "'")
    # "T4,T5" / "T4, T5" / "T4 T5" をすべて受け付ける(ps1 版と同じ)
    targets = [b for b in re.split(r'[,\s]+', before) if b]
    if not targets:
        fail('--before requires at least one task ID')
    errors = []
    for b in targets:
        if b == insert:
            errors.append("--before must not include the inserted task itself ('" + b + "')")
        elif b not in existing_status:
            errors.append("--before task '" + b + "' not found in state.json")
        elif existing_status[b] != 'pending':
            errors.append("--before task '" + b + "' is '" + existing_status[b]
                          + "' (only pending tasks can be rewritten)")
        elif b not in by_id:
            errors.append("--before task '" + b + "' not found in tasks.md")
    if errors:
        fail('\n'.join(errors))
    lines = tasklib.split_lines(content)
    for b in targets:
        try:
            deps = tasklib.parse_deps(by_id[b])
        except tasklib.TaskFileError as e:
            fail(str(e))
        if insert not in deps:
            deps.append(insert)
        tasklib.rewrite_dep_line(lines, by_id[b], deps)
    content = ''.join(lines)
    tasks = tasklib.parse_tasks(content)

# --- 依存欄の検証(全モード共通。state.json を書く前に失敗させる) ---
try:
    tasklib.resolve_deps(tasks, check_cycles=True)
except tasklib.TaskFileError as e:
    fail(str(e))

now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')

def new_entry(t):
    return {'id': t['id'], 'title': t['title'], 'status': 'pending', 'retries': 0, 'commit': None}

if init:
    state = {'source': source, 'branch': branch, 'updated_at': now, 'tasks': [new_entry(t) for t in tasks]}
else:
    out = list(existing['tasks'])
    for t in tasks:
        if t['id'] not in existing_status:
            out.append(new_entry(t))
    for tid in existing_status:
        if tid not in by_id:
            print("state.json has task '" + tid + "' not present in tasks.md (not removed)", file=sys.stderr)
    state = {'source': existing['source'], 'branch': existing['branch'], 'updated_at': now, 'tasks': out}

if lines is not None:
    with open(tasks_path, 'w', encoding='utf-8', newline='') as f:
        f.write(content)
    print('Inserted ' + insert + ' before ' + ','.join(targets) + ' (dependency lines updated in tasks.md)')

with open(state_path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY

echo "Synced: $STATE_PATH"
