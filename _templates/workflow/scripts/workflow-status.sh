#!/bin/bash
set -euo pipefail

# 進捗と次の操作を短く出す(読み取り専用)。
# 引数: [--summary](省略時は通常モード)
# stdout: "Progress: <done>/<全タスク> done"、"Group: <名前> <done>/<数>"(グループ区切りがあるときだけ)、
#       "Current: <ID> <status> | <title>" / "Current: none"、
#       "Run: <ID>-<N> running elapsed=<秒>s log_idle=<秒>s" / "Run: <ID>-<N> finished"(in_progress で run があるときだけ)、
#       "Failed: T3, T5"(failed があるときだけ)、"PR: <state> <url>" / "PR: none" / "PR: unknown"(finish / group-advance のときだけ)、
#       "Comprehension: unanswered=<n>[ <ファイル名> ...]"、最後に "Next: ..."
#       --summary のときは、先頭に "Task <ID> <status> <commit 先頭7文字 | -> retries=<n> | <title>"(全タスク)と
#       要件の行("Requirement ..."・"Summary: ...")を足し、Next の直前に "Worktree: clean" / "Worktree: dirty <n>" を足す
# exit: 0=出力あり / 1=使い方・tasks.md/state.json 不備・next-task.sh の失敗

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
# tasklib を import しても scripts/__pycache__ を作らない(利用先の作業ツリーを汚さないため)
export PYTHONDONTWRITEBYTECODE=1

SUMMARY=0
if [ "$#" -eq 1 ] && [ "$1" = "--summary" ]; then
    SUMMARY=1
elif [ "$#" -ne 0 ]; then
    echo "Usage: workflow-status.sh [--summary]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

TASKS_PATH="$ROOT/.agents/workflow/tasks.md"
STATE_PATH="$ROOT/.agents/workflow/state.json"
RUNS_DIR="$ROOT/.agents/workflow/runs"
COMPREHENSION_DIR="$ROOT/.agents/workflow/comprehension"

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

# --- 次の操作(next-task.sh) ---
NEXT_ERR_FILE="$(mktemp)"
trap 'rm -f "$NEXT_ERR_FILE" "${GH_OUT_FILE:-}" "${GH_ERR_FILE:-}"' EXIT
NEXT_CODE=0
NEXT_OUT="$(bash "$SCRIPT_DIR/next-task.sh" 2> "$NEXT_ERR_FILE")" || NEXT_CODE=$?
if [ "$NEXT_CODE" -eq 1 ]; then
    cat "$NEXT_ERR_FILE" >&2
    exit 1
fi
NEXT_LINE="$(printf '%s\n' "$NEXT_OUT" | tr -d '\r' | grep '^Next:' | tail -n 1 || true)"

# --- PR の状態(finish / group-advance のときだけ) ---
PR_STATE=""
PR_URL=""
if [ "$NEXT_LINE" = "Next: finish" ] || [ "$NEXT_LINE" = "Next: group-advance" ]; then
    PR_STATE="unknown"
    BRANCH="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    print(json.load(f).get('branch') or '')
" "$(to_py_path "$STATE_PATH")" 2> /dev/null | tr -d '\r' || true)"
    if [ -n "$BRANCH" ] && command -v gh > /dev/null 2>&1; then
        GH_OUT_FILE="$(mktemp)"
        GH_ERR_FILE="$(mktemp)"
        GH_CODE=0
        gh pr view "$BRANCH" --json state,url > "$GH_OUT_FILE" 2> "$GH_ERR_FILE" || GH_CODE=$?
        if [ "$GH_CODE" -eq 0 ]; then
            PR_INFO="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
state = str(data.get('state') or '')
if not state:
    sys.exit(1)
print(state, str(data.get('url') or ''))
" "$(to_py_path "$GH_OUT_FILE")" 2> /dev/null | tr -d '\r')" || PR_INFO=""
            if [ -n "$PR_INFO" ]; then
                PR_STATE="${PR_INFO%% *}"
                PR_URL="${PR_INFO#* }"
                [ "$PR_URL" = "$PR_INFO" ] && PR_URL=""
            fi
        elif grep -qi 'no pull requests found' "$GH_ERR_FILE"; then
            PR_STATE="none"
        fi
    fi
fi

# --- 作業ツリーの変更数(--summary のときだけ git を呼ぶ) ---
DIRTY_COUNT=0
if [ "$SUMMARY" -eq 1 ]; then
    DIRTY_COUNT="$(git status --porcelain 2> /dev/null | tr -d '\r' | grep -c . || true)"
    DIRTY_COUNT="${DIRTY_COUNT:-0}"
fi

python3 - "$(to_py_path "$SCRIPT_DIR")" "$(to_py_path "$TASKS_PATH")" "$(to_py_path "$STATE_PATH")" \
    "$(to_py_path "$RUNS_DIR")" "$(to_py_path "$COMPREHENSION_DIR")" "$SUMMARY" "$NEXT_LINE" "$PR_STATE" "$PR_URL" \
    "$DIRTY_COUNT" <<'PY'
import json, os, re, sys, time

sys.stdout.reconfigure(newline='\n')

(script_dir, tasks_path, state_path, runs_dir, comprehension_dir,
 summary, next_line, pr_state, pr_url, dirty_count) = sys.argv[1:11]
sys.path.insert(0, script_dir)
import tasklib

with open(tasks_path, encoding='utf-8', newline='') as f:
    content = f.read()
with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
try:
    tasks = tasklib.parse_tasks(content)
except tasklib.TaskFileError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)

st_tasks = state['tasks']
status_of = {t['id']: t.get('status') for t in st_tasks}
done = sum(1 for t in st_tasks if t.get('status') == 'done')
title_of = {t['id']: t['title'] for t in tasks}
out = []

# --- Task / Requirement(--summary のときだけ) ---
if summary == '1':
    for t in st_tasks:
        commit = str(t.get('commit') or '')[:7] or '-'
        out.append('Task ' + t['id'] + ' ' + str(t.get('status')) + ' ' + commit
                   + ' retries=' + str(t.get('retries', 0)) + ' | ' + title_of.get(t['id'], ''))
    try:
        out.extend(tasklib.requirement_status_lines(tasks, content, st_tasks))
    except tasklib.TaskFileError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

out.append('Progress: ' + str(done) + '/' + str(len(st_tasks)) + ' done')

# --- Group ---
order = tasklib.group_order(content)
if len(order) >= 2:
    group = state.get('group')
    if group not in order:
        group = None
        for t in tasks:
            if status_of.get(t['id']) != 'done':
                group = t['group']
                break
    if group is not None:
        members = [t for t in tasks if t['group'] == group]
        n_done = sum(1 for t in members if status_of.get(t['id']) == 'done')
        out.append('Group: ' + (group or '(default)') + ' ' + str(n_done) + '/' + str(len(members)))

# --- Current / Run ---
current = next((t for t in st_tasks if t.get('status') in ('in_progress', 'in_review')), None)
run_shown = False
if current is None:
    out.append('Current: none')
else:
    cid = current['id']
    out.append('Current: ' + cid + ' ' + current['status'] + ' | ' + title_of.get(cid, ''))
    if current['status'] == 'in_progress' and os.path.isdir(runs_dir):
        pat = re.compile('^' + re.escape(cid) + r'-(\d+)$')
        nums = [int(m.group(1)) for m in (pat.match(d) for d in os.listdir(runs_dir)) if m]
        if nums:
            run_id = cid + '-' + str(max(nums))
            run_dir = os.path.join(runs_dir, run_id)
            guard = os.path.join(run_dir, 'guard.sha256')
            if os.path.isfile(guard):
                run_shown = True
                if os.path.exists(os.path.join(run_dir, 'done')):
                    out.append('Run: ' + run_id + ' finished')
                else:
                    now = time.time()
                    log = os.path.join(run_dir, 'output.log')
                    idle = str(int(now - os.path.getmtime(log))) if os.path.isfile(log) else '-'
                    out.append('Run: ' + run_id + ' running elapsed=' + str(int(now - os.path.getmtime(guard)))
                               + 's log_idle=' + idle + 's')

# --- Failed ---
failed = [t['id'] for t in st_tasks if t.get('status') == 'failed']
if failed:
    out.append('Failed: ' + ', '.join(failed))

# --- PR ---
if pr_state:
    if pr_state in ('none', 'unknown'):
        out.append('PR: ' + pr_state)
    else:
        out.append('PR: ' + pr_state + (' ' + pr_url if pr_url else ''))

# --- Comprehension ---
unanswered = []
if os.path.isdir(comprehension_dir):
    for name in sorted(os.listdir(comprehension_dir)):
        if not name.endswith('.md'):
            continue
        p = os.path.join(comprehension_dir, name)
        if not os.path.isfile(p):
            continue
        with open(p, encoding='utf-8', errors='replace') as f:
            if any(l.strip() == '**あなたの回答**: <!-- ここに記入 -->' for l in f):
                unanswered.append(name)
out.append('Comprehension: unanswered=' + str(len(unanswered)) + ''.join(' ' + n for n in unanswered))

# --- Worktree(--summary のときだけ) ---
if summary == '1':
    n_dirty = int(dirty_count or 0)
    out.append('Worktree: clean' if n_dirty == 0 else 'Worktree: dirty ' + str(n_dirty))

# --- Next ---
if run_shown:
    out.append('Next: wait')
elif pr_state == 'none':
    out.append('Next: create-pr')
elif pr_state == 'OPEN':
    out.append('Next: wait-merge')
elif pr_state == 'CLOSED':
    out.append('Next: escalate reason=pr-closed')
else:
    out.append(next_line)

for line in out:
    print(line)
PY
