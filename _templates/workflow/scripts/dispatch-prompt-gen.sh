#!/bin/bash
set -euo pipefail

# On Windows (Git Bash + native python3), argv/file I/O default to the
# system codepage and mangle non-ASCII (Japanese) text. Force UTF-8.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

USAGE="Usage: dispatch-prompt-gen.sh <TaskId> [Attempt] | dispatch-prompt-gen.sh --pr"
PR_MODE=false
if [ "${1:-}" = "--pr" ]; then
    PR_MODE=true
    TASK_ID="pr"
    ATTEMPT=1
else
    TASK_ID="${1:?$USAGE}"
    ATTEMPT="${2:-1}"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

TASKS_PATH="$ROOT/.agents/workflow/tasks.md"
STATE_PATH="$ROOT/.agents/workflow/state.json"
CONFIG_PATH="$ROOT/.agents/workflow/config.json"
RUNS_BASE="$ROOT/.agents/workflow/runs"
RUN_DIR="$RUNS_BASE/${TASK_ID}-${ATTEMPT}"
PROMPT_PATH="$RUN_DIR/prompt.md"
TEMPLATE_PATH="$SCRIPT_DIR/dispatch-prompt-template.md"

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
STATE_PATH_PY="$(to_py_path "$STATE_PATH")"
CONFIG_PATH_PY="$(to_py_path "$CONFIG_PATH")"
TEMPLATE_PATH_PY="$(to_py_path "$TEMPLATE_PATH")"
PROMPT_PATH_PY="$(to_py_path "$PROMPT_PATH")"

# --- PR mode: PR作成を子に単発依頼するプロンプトを生成する ---
# 対象タスク = state.json で done かつ commit が git log <base>..HEAD に含まれるもの。
# 出力先は runs/pr-<連番>-1/prompt.md。stdout に "RunId: pr-<連番>" を出す。
if [ "$PR_MODE" = true ]; then
    BASE_BRANCH="main"
    BRANCH="$(git branch --show-current)"
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "$BASE_BRANCH" ]; then
        echo "PR mode must be run on a work branch (current: '${BRANCH:-detached HEAD}')" >&2
        exit 1
    fi
    if ! git rev-parse --verify --quiet "$BASE_BRANCH" > /dev/null; then
        echo "Base branch '$BASE_BRANCH' not found" >&2
        exit 1
    fi
    if [ ! -f "$STATE_PATH" ]; then
        echo "state.json not found: $STATE_PATH" >&2
        exit 1
    fi
    PR_N=1
    if [ -d "$RUNS_BASE" ]; then
        for d in "$RUNS_BASE"/pr-*-1; do
            [ -d "$d" ] || continue
            n="$(basename "$d" | sed 's/^pr-//; s/-1$//')"
            if [ "$n" -ge "$PR_N" ] 2>/dev/null; then
                PR_N=$((n + 1))
            fi
        done
    fi
    PR_RUN_DIR="$RUNS_BASE/pr-${PR_N}-1"
    COMMITS="$(git log "$BASE_BRANCH..HEAD" --format=%H)"
    mkdir -p "$PR_RUN_DIR"
    python3 - "$STATE_PATH_PY" "$(to_py_path "$SCRIPT_DIR/dispatch-pr-prompt-template.md")" \
        "$(to_py_path "$PR_RUN_DIR/prompt.md")" "$BRANCH" "$BASE_BRANCH" \
        ".agents/workflow/runs/pr-${PR_N}-1" "$COMMITS" <<'PY' || { rmdir "$PR_RUN_DIR" 2>/dev/null; exit 1; }
import json, sys
state_path, template_path, prompt_path, branch, base, run_dir, commits = sys.argv[1:8]
commits = [c for c in commits.split() if c]
with open(state_path, encoding='utf-8') as f:
    tasks = json.load(f)['tasks']
selected = []
for t in tasks:
    c = t.get('commit')
    if t.get('status') == 'done' and c and any(h.startswith(c) for h in commits):
        selected.append('- ' + t['id'] + ': ' + t['title'] + ' (commit ' + c + ')')
if not selected:
    print('No done tasks whose commit is in ' + base + '..HEAD (nothing to include in the PR)', file=sys.stderr)
    sys.exit(1)
with open(template_path, encoding='utf-8') as f:
    text = f.read()
for key, value in (('{task_list}', '\n'.join(selected)), ('{branch}', branch),
                   ('{base_branch}', base), ('{run_dir}', run_dir)):
    text = text.replace(key, value)
with open(prompt_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(text)
PY
    echo "Generated: $PR_RUN_DIR/prompt.md"
    echo "RunId: pr-${PR_N}"
    exit 0
fi

# --- Extract task section from tasks.md ---
extract_task_section() {
    local id="$1"
    awk -v id="$id" '
        /^## / {
            if (in_section) exit
            if ($0 ~ "^## " id ":") in_section = 1
        }
        in_section { print }
    ' "$TASKS_PATH"
}

# --- Get task title from state.json ---
get_task_title() {
    local id="$1"
    if [ -f "$STATE_PATH" ]; then
        python3 -c "
import json, sys
with open('$STATE_PATH_PY') as f:
    state = json.load(f)
for t in state['tasks']:
    if t['id'] == '$id':
        print(t['title']); sys.exit(0)
print(''); sys.exit(0)
" 2>/dev/null || echo ''
    else
        echo ''
    fi
}

# --- Check task exists ---
if ! grep -q "^## ${TASK_ID}:" "$TASKS_PATH" 2>/dev/null; then
    echo "Task '${TASK_ID}' not found in ${TASKS_PATH}" >&2
    exit 1
fi

TASK_SECTION=$(extract_task_section "$TASK_ID")

# Extract title
TASK_TITLE=""
if echo "$TASK_SECTION" | head -1 | grep -qE "^## ${TASK_ID}:"; then
    TASK_TITLE=$(echo "$TASK_SECTION" | head -1 | sed "s/^## ${TASK_ID}:[[:space:]]*//")
fi

# Extract and validate dependencies (invalid tokens are an error, never silently dropped)
DEPS=$(python3 - "$(to_py_path "$SCRIPT_DIR")" "$(to_py_path "$TASKS_PATH")" "$TASK_ID" <<'PY'
import sys
script_dir, tasks_path, task_id = sys.argv[1:4]
sys.path.insert(0, script_dir)
import tasklib
with open(tasks_path, encoding='utf-8', newline='') as f:
    tasks = tasklib.parse_tasks(f.read())
ids = {t['id'] for t in tasks}
task = next(t for t in tasks if t['id'] == task_id)
try:
    deps = tasklib.parse_deps(task)
except tasklib.TaskFileError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
unknown = [d for d in deps if d not in ids]
if unknown:
    print(task_id + ': depends on unknown task(s) ' + ', '.join(unknown) + ' (not found in tasks.md)', file=sys.stderr)
    sys.exit(1)
print(','.join(deps))
PY
) || exit 1

# --- Handoff guard ---
if [ -n "$DEPS" ]; then
    if [ ! -f "$STATE_PATH" ]; then
        echo "state.json not found: $STATE_PATH" >&2
        exit 1
    fi

    MISSING=""
    IFS=',' read -ra DEP_ARRAY <<< "$DEPS"
    for dep_id in "${DEP_ARRAY[@]}"; do
        dep_status=$(python3 -c "
import json
with open('$STATE_PATH_PY') as f:
    state = json.load(f)
for t in state['tasks']:
    if t['id'] == '${dep_id}':
        print(t['status']); exit(0)
print('missing')
" 2>/dev/null || echo 'missing')
        if [ "$dep_status" != "done" ]; then
            MISSING="${MISSING}${dep_id}: status is not done
"
        fi
    done

    for dep_id in "${DEP_ARRAY[@]}"; do
        if echo "$MISSING" | grep -q "^${dep_id}:"; then
            continue
        fi
        MAX_ATTEMPT=0
        if [ -d "$RUNS_BASE" ]; then
            for d in "$RUNS_BASE"/${dep_id}-*; do
                [ -d "$d" ] || continue
                dirname=$(basename "$d")
                n=$(echo "$dirname" | sed "s/^${dep_id}-//")
                if [ "$n" -gt "$MAX_ATTEMPT" ] 2>/dev/null; then
                    MAX_ATTEMPT=$n
                fi
            done
        fi
        REPORT_PATH="$RUNS_BASE/${dep_id}-${MAX_ATTEMPT}/report.md"
        if [ ! -f "$REPORT_PATH" ]; then
            MISSING="${MISSING}${dep_id}: report.md not found at runs/${dep_id}-${MAX_ATTEMPT}/report.md
"
        fi
    done

    if [ -n "$MISSING" ]; then
        rm -f "$PROMPT_PATH"
        echo "Handoff guard failed:" >&2
        echo -n "$MISSING" >&2
        exit 2
    fi
fi

# --- Build handoff reports ---
HANDOFF_REPORTS=""
if [ -n "$DEPS" ]; then
    HANDOFF_REPORTS="## 前提タスクの成果(引き継ぎ)
"
    FIRST_DEP=true
    IFS=',' read -ra DEP_ARRAY <<< "$DEPS"
    for dep_id in "${DEP_ARRAY[@]}"; do
        dep_title=$(get_task_title "$dep_id")
        MAX_ATTEMPT=0
        if [ -d "$RUNS_BASE" ]; then
            for d in "$RUNS_BASE"/${dep_id}-*; do
                [ -d "$d" ] || continue
                dirname=$(basename "$d")
                n=$(echo "$dirname" | sed "s/^${dep_id}-//")
                if [ "$n" -gt "$MAX_ATTEMPT" ] 2>/dev/null; then
                    MAX_ATTEMPT=$n
                fi
            done
        fi
        REPORT_PATH="$RUNS_BASE/${dep_id}-${MAX_ATTEMPT}/report.md"
        REPORT_CONTENT=$(cat "$REPORT_PATH")
        if [ "$FIRST_DEP" = true ]; then
            FIRST_DEP=false
        else
            HANDOFF_REPORTS="${HANDOFF_REPORTS}
"
        fi
        HANDOFF_REPORTS="${HANDOFF_REPORTS}
### ${dep_id}: ${dep_title}
${REPORT_CONTENT}"
    done
    HANDOFF_REPORTS="${HANDOFF_REPORTS}
"
fi

# --- Fix notes (retry mode) ---
FIX_NOTES=""
if [ "$ATTEMPT" -ge 2 ]; then
    FIX_NOTES_PATH="$RUN_DIR/fix-notes.md"
    if [ ! -f "$FIX_NOTES_PATH" ]; then
        echo "fix-notes.md not found: $FIX_NOTES_PATH" >&2
        exit 3
    fi
    FIX_CONTENT=$(cat "$FIX_NOTES_PATH")
    FIX_NOTES="## レビュー指摘事項(最優先で対応)
${FIX_CONTENT}"
fi

# --- Build verify instruction ---
VERIFY_LINES=""
HAS_VERIFY=false

if command -v python3 > /dev/null 2>&1; then
    VERIFY_LINES=$(python3 -c "
import json
with open('$CONFIG_PATH_PY') as f:
    cfg = json.load(f)
lines = []
qg = cfg.get('quality_gate', {})
if qg:
    cdc = qg.get('child_dispatch_command', '')
    if cdc:
        lines.append('- ' + cdc)
    else:
        for step in qg.get('steps', []):
            if step.get('blocking'):
                lines.append('- ' + step['name'] + ': ' + step['command'])
tc = cfg.get('test_command', '')
if tc:
    lines.append('- ' + tc)
if not lines:
    lines.append('(設定ファイルの test_command / quality_gate で検証コマンドを指定してください)')
print('\n'.join(lines))
" 2>/dev/null)
    HAS_VERIFY=true
fi

if [ "$HAS_VERIFY" = false ]; then
    VERIFY_LINES="- (設定ファイルの test_command / quality_gate で検証コマンドを指定してください)"
fi

# --- Generate prompt ---
mkdir -p "$RUN_DIR"
rm -f "$PROMPT_PATH"

python3 -c "
import sys
with open('$TEMPLATE_PATH_PY', encoding='utf-8') as f:
    template = f.read()
fix_notes = sys.argv[1]
task_section = sys.argv[2]
handoff_reports = sys.argv[3]
verify_instruction = sys.argv[4]
result = template.replace('{fix_notes}', fix_notes)
result = result.replace('{task_section}', task_section)
result = result.replace('{handoff_reports}', handoff_reports)
result = result.replace('{verify_instruction}', verify_instruction)
with open('$PROMPT_PATH_PY', 'w', encoding='utf-8', newline='\n') as f:
    f.write(result)
" "$FIX_NOTES" "$TASK_SECTION" "$HANDOFF_REPORTS" "$VERIFY_LINES"

echo "Generated: $PROMPT_PATH"
