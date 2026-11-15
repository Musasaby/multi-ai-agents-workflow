#!/bin/bash
set -uo pipefail

# タスクが今どの段階にあるかを、state.json と runs/ のファイルの有無だけで判定する(読み取り専用)。
# Usage: run-phase.sh <TaskId>
# stdout: "Phase: <段階> <試行回数>" の 1 行だけ
# exit: 0=判定した / 1=使い方不備・state.json が無い・タスクが state.json に無い
#
# <段階> の意味:
#   start        = この試行番号で起動する
#   running      = 実装の run の完了待ち
#   review-start = レビューを起動する
#   reviewing    = レビューの完了待ち
#   collect      = 取り込む
#   gate         = 品質ゲートとコミット
#   retry        = レビュー不合格の再 dispatch
#   manual       = 親が今の手順で処理する
#   pending / done / failed = 対象外の状態をそのまま出す

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1

USAGE="Usage: run-phase.sh <TaskId>"
TASK_ID="${1:-}"
if [ "$#" -ne 1 ] || [ -z "$TASK_ID" ]; then
    echo "$USAGE" >&2
    exit 1
fi
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid TaskId: '$TASK_ID'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

STATE_PATH="$ROOT/.agents/workflow/state.json"
RUNS_DIR="$ROOT/.agents/workflow/runs"
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

python3 - "$(to_py_path "$STATE_PATH")" "$(to_py_path "$RUNS_DIR")" "$TASK_ID" <<'PY'
import json, os, re, sys

sys.stdout.reconfigure(newline='\n')

state_path, runs_dir, task_id = sys.argv[1:4]

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
task = next((t for t in state.get('tasks', []) if t.get('id') == task_id), None)
if task is None:
    fail("Task '" + task_id + "' not found in state.json")

status = task.get('status')

# N = runs/<ID>-<n>/guard.sha256 がある最大の n(無ければ 0)
n = 0
if os.path.isdir(runs_dir):
    pat = re.compile(re.escape(task_id) + r'-(\d+)$')
    for name in os.listdir(runs_dir):
        m = pat.match(name)
        if m and os.path.isfile(os.path.join(runs_dir, name, 'guard.sha256')):
            n = max(n, int(m.group(1)))

run = os.path.join(runs_dir, task_id + '-' + str(n))
review = os.path.join(runs_dir, 'review-' + task_id + '-' + str(n))

def has(path, name):
    return os.path.exists(os.path.join(path, name))

verdict = ''
verdict_path = os.path.join(review, 'verdict')
if os.path.isfile(verdict_path):
    with open(verdict_path, encoding='utf-8', errors='replace') as f:
        verdict = f.readline().rstrip('\r\n')

if status not in ('in_progress', 'in_review'):
    phase = str(status)
elif status == 'in_progress':
    if n == 0:
        phase = 'start'
        n = 1
    elif has(run, 'superseded') or has(run, 'collected'):
        phase = 'start'
        n += 1
    elif not has(run, 'checked'):
        phase = 'running'
    elif not has(review, 'guard.sha256'):
        phase = 'review-start'
    elif verdict == '':
        phase = 'reviewing'
    elif verdict == 'pass':
        phase = 'collect'
    elif verdict == 'fail':
        phase = 'retry'
    else:
        phase = 'unknown'
else:  # in_review
    if verdict == 'pass' and has(run, 'collected'):
        phase = 'gate'
    elif verdict == 'fail' and not has(run, 'collected'):
        phase = 'retry'
    else:
        phase = 'manual'

print('Phase: ' + phase + ' ' + str(n))
PY
