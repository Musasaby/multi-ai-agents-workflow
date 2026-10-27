#!/bin/bash
set -euo pipefail

# 次に処理するタスクを state.json と tasks.md の依存関係から機械的に選ぶ。
#   1. in_progress / in_review のタスク(再開対象)があれば、state.json 上で最初のもの
#   2. なければ、依存タスクがすべて done の最初の pending タスク
# branch_per_group が有効で tasks.md にグループ区切りがある場合は、state.json の
# group(現在の作業グループ。無い/未知のグループ名なら「未完了タスクを含む最初のグループ」)
# のタスクだけを候補にする。作業グループが全タスク done で他グループに未完了があれば
# stdout に作業グループ名を出して exit 6(グループ境界で停止する合図)。
# stdout: "<タスクID> <status>" / グループ完了時は "<作業グループ名>"。最後の行に "Next: <行動>" を出す
#       (exit 0=dispatch/review <タスクID>、exit 3=finish、exit 4=escalate reason=blocked、
#       exit 6=group-advance。exit 1 では出さない)
# exit: 0=該当あり / 1=使い方・tasks.md/state.json 不備 / 3=全タスク done /
#       4=実行可能なタスクなし / 5=実行中のタスクの完了待ち(max_parallel が 2 以上) /
#       6=作業グループ完了(他グループに未完了あり)
# max_parallel(config.json)が 2 以上のときは、in_review があればそれを優先し、なければ
# in_progress を active として空きの分だけ、変更対象(changed)が重ならない pending を
# "Next: dispatch <ID> <ID> ..." で複数選ぶ

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

# stdout の行末を OS によらず LF に揃える(Windows ネイティブ Python は \r\n に変換するため。
# 最終行を機械的に読む呼び出し側が CR を参照しなくて済む)
sys.stdout.reconfigure(newline='\n')

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
# max_parallel: 整数で 2 以上のときだけ並列選択を行う(無い・1 未満・整数でなければ 1)
max_parallel = config.get('max_parallel', 1)
if isinstance(max_parallel, bool) or not isinstance(max_parallel, int) or max_parallel < 1:
    max_parallel = 1
exclusive_files = config.get('parallel_exclusive_files')
if not isinstance(exclusive_files, list) or not all(isinstance(x, str) for x in exclusive_files):
    exclusive_files = ['AGENTS.md', 'README.md']
changed_of = {t['id']: t.get('changed', []) for t in tasks}

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
    if t['status'] == 'in_review' or (max_parallel < 2 and t['status'] == 'in_progress'):
        print(t['id'] + ' ' + t['status'])
        if t['status'] == 'in_review':
            print('Next: review ' + t['id'])
        else:
            print('Next: dispatch ' + t['id'])
        sys.exit(0)

if all(t['status'] == 'done' for t in state_tasks):
    print('All tasks are done', file=sys.stderr)
    print('Next: finish')
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
        print('Next: group-advance')
        sys.exit(6)
else:
    candidates = state_tasks

if max_parallel >= 2:
    active = [t['id'] for t in state_tasks if t['status'] == 'in_progress']

    def is_solo(tid):
        ch = changed_of.get(tid, [])
        return not ch or any(f in exclusive_files for f in ch)

    chosen = []
    if not any(is_solo(a) for a in active):
        busy = set()
        for a in active:
            busy.update(changed_of.get(a, []))
        for t in candidates:
            if t['status'] != 'pending':
                continue
            if t['id'] not in graph:
                print("Task '" + t['id'] + "' is in state.json but not in tasks.md", file=sys.stderr)
                sys.exit(1)
            if max_parallel - len(active) - len(chosen) <= 0:
                break
            if any(status.get(d) != 'done' for d in graph[t['id']]):
                continue
            ch = changed_of.get(t['id'], [])
            if is_solo(t['id']):
                if not active and not chosen:
                    chosen.append(t['id'])
                    break
                continue
            if busy.isdisjoint(ch):
                chosen.append(t['id'])
                busy.update(ch)
    if chosen or active:
        for a in active:
            print(a + ' in_progress')
        for c in chosen:
            print(c + ' pending')
        if chosen:
            print('Next: dispatch ' + ' '.join(chosen))
            sys.exit(0)
        print('Next: wait ' + ' '.join(active))
        sys.exit(5)

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
        print('Next: dispatch ' + t['id'])
        sys.exit(0)
    blocked.append(t['id'] + ': waiting for ' + ', '.join(d + '(' + status.get(d, 'missing') + ')' for d in waiting))

print('No runnable task. Blocked:', file=sys.stderr)
for b in blocked:
    print('  ' + b, file=sys.stderr)
for t in candidates:
    if t['status'] == 'failed':
        print('  ' + t['id'] + ': failed', file=sys.stderr)
print('Next: escalate reason=blocked')
sys.exit(4)
PY
