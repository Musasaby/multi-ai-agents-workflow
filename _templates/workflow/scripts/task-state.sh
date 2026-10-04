#!/bin/bash
set -uo pipefail

# state.json のタスクの状態を、許された遷移だけで機械的に更新する(LLM が JSON を手で編集しない)。
# Usage: task-state.sh <TaskId> <action> [--commit <hash>]
#   start  : pending / in_progress → in_progress(dispatch。中断後の再 dispatch も可)
#   review : in_progress → in_review(子の完了報告を検証した後)
#   done   : in_review → done(--commit <コミットハッシュ> 必須)
#   retry  : in_review → in_progress、retries + 1(retries が max_fix_retries 以上なら exit 4)
#   fail   : pending 以外 → failed
#   reset  : failed → pending(retries を 0、commit を null に戻す。ユーザー判断でやり直す場合)
# exit: 0=更新した / 1=使い方不備・許されない遷移 / 4=retry の上限超過
# 拒否した場合、state.json は変更しない。

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1

USAGE="Usage: task-state.sh <TaskId> <start|review|done|retry|fail|reset> [--commit <hash>]"
TASK_ID="${1:-}"
ACTION="${2:-}"
COMMIT=""
if [ -z "$TASK_ID" ] || [ -z "$ACTION" ]; then
    echo "$USAGE" >&2
    exit 1
fi
shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --commit)
            if [ $# -lt 2 ]; then echo "--commit requires a value" >&2; exit 1; fi
            COMMIT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid TaskId: '$TASK_ID'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
STATE_PATH=".agents/workflow/state.json"
CONFIG_PATH=".agents/workflow/config.json"
if [ ! -f "$STATE_PATH" ]; then
    echo "state.json not found: $STATE_PATH" >&2
    exit 1
fi

python3 - "$STATE_PATH" "$CONFIG_PATH" "$TASK_ID" "$ACTION" "$COMMIT" <<'PY'
import datetime, json, os, re, sys

state_path, config_path, task_id, action, commit = sys.argv[1:6]

# 動作ごとの「遷移元として許される状態」と遷移先
TRANSITIONS = {
    'start': ({'pending', 'in_progress'}, 'in_progress'),
    'review': ({'in_progress'}, 'in_review'),
    'done': ({'in_review'}, 'done'),
    'retry': ({'in_review'}, 'in_progress'),
    'fail': ({'in_progress', 'in_review', 'done', 'failed'}, 'failed'),
    'reset': ({'failed'}, 'pending'),
}

def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)

if action not in TRANSITIONS:
    fail("Unknown action '" + action + "' (expected: " + ', '.join(TRANSITIONS) + ")")
if action == 'done':
    if not commit:
        fail('done requires --commit <hash>')
    if not re.fullmatch(r'[0-9a-fA-F]{7,40}', commit):
        fail("Invalid commit hash: '" + commit + "'")
elif commit:
    fail('--commit is only valid with done')

with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
task = next((t for t in state.get('tasks', []) if t.get('id') == task_id), None)
if task is None:
    fail("Task '" + task_id + "' not found in state.json")

allowed, target = TRANSITIONS[action]
current = task.get('status')
if current not in allowed:
    fail(task_id + ": cannot '" + action + "' from '" + str(current) + "' (allowed from: "
         + ', '.join(sorted(allowed)) + ")")

if action == 'retry':
    max_retries = 2
    if os.path.exists(config_path):
        with open(config_path, encoding='utf-8') as f:
            max_retries = int(json.load(f).get('max_fix_retries', 2))
    if int(task.get('retries', 0)) >= max_retries:
        fail(task_id + ': retries (' + str(task.get('retries', 0)) + ') reached max_fix_retries ('
             + str(max_retries) + '); escalate instead of retrying', 4)
    task['retries'] = int(task.get('retries', 0)) + 1
elif action == 'done':
    task['commit'] = commit
elif action == 'reset':
    task['retries'] = 0
    task['commit'] = None

task['status'] = target
state['updated_at'] = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
with open(state_path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(task_id + ': ' + str(current) + ' -> ' + target
      + (' (retries ' + str(task['retries']) + ')' if action == 'retry' else '')
      + (' (commit ' + commit + ')' if action == 'done' else ''))
PY
