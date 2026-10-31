#!/bin/bash
set -uo pipefail

# 子エージェントの起動までの事前チェックを順に行い、デタッチ起動する。失敗した段階で止める
# (止めたときは state.json を変えず、子も起動しない)。
# Usage: dispatch-start.sh <TaskId> [Attempt] | dispatch-start.sh --pr
#   --pr: PR 作成の run(pr-<N>-1)を起動する(タスクの状態確認・task-state は行わず、ウォームアップもしない)
# config.json の max_parallel が 2 以上で --pr でないときは、作業ツリーの確認を飛ばし、
# タスクの状態の確認の後に dispatch-worktree create で worktree の run にする(Carried: 行と Worktree: 行を出す)
# exit:
#   0=起動した / 1=使い方不備
#   11〜15=branch-check --state の 1〜5(stdout の Next: 行はそのまま流す)
#   20=作業ツリーが汚れている(試行回数 2 以上で fix-notes.md がある場合は確認しない) / 21=タスクの状態が不正(pending / in_progress 以外、タスク無しを含む)
#   30=疎通確認(healthcheck_command)の失敗 / 31=ウォームアップ(warmup_command)の失敗
#   41〜43=dispatch-prompt-gen の 1〜3(依存未完了・report.md の欠落は 42)
#   22=max_parallel が 2 以上で、worktree の作成が dirty-tree(dispatch-worktree の exit 20)
#   50=task-state の失敗
#   61=max_parallel が 2 以上で、worktree の作成に失敗(dispatch-worktree の exit 20 以外)
#   60=dispatch-run の起動を確認できない(guard.sha256 が上限秒数内に現れない)
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / escalate reason=<理由> 等。
# 使い方不備の exit 1 では出さない)

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PR_MODE=false
if [ "${1:-}" = "--pr" ]; then
    PR_MODE=true
    TASK_ID="pr"
    ATTEMPT=1
else
    TASK_ID="${1:?Usage: dispatch-start.sh <TaskId> [Attempt] | dispatch-start.sh --pr}"
    ATTEMPT="${2:-1}"
fi
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid TaskId/Attempt: '$TASK_ID' '$ATTEMPT'" >&2
    exit 1
fi

# state.json・config.json の読み取りに python3 が要る(無いと状態が読めず、
# 誤って「タスク無し」(exit 21)になるため始めに止める)
if ! command -v python3 > /dev/null 2>&1; then
    echo "python3 not found (required to read state.json and config.json)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"

# 1. ブランチ
OUT="$(bash "$SCRIPT_DIR/branch-check.sh" --state)"
CODE=$?
if [ "$CODE" -ne 0 ]; then
    printf '%s\n' "$OUT"
    exit $((10 + CODE))
fi

# max_parallel(config.json。整数で 2 以上のときだけ並列。それ以外は 1)
MAX_PARALLEL="$(python3 -c "
import json
try:
    with open('.agents/workflow/config.json', encoding='utf-8') as f:
        v = json.load(f).get('max_parallel', 1)
except Exception:
    v = 1
print(v if isinstance(v, int) and not isinstance(v, bool) and v >= 1 else 1)
" 2> /dev/null | tr -d '\r')"
PARALLEL=false
if [ "$PR_MODE" = false ] && [ "${MAX_PARALLEL:-1}" -ge 2 ] 2> /dev/null; then PARALLEL=true; fi

# 2. 作業ツリー(並列のときは本体に別タスクの変更があってよいので確認しない)
if [ "$PARALLEL" = true ]; then
    :
elif [ "$PR_MODE" = false ] && [ "$ATTEMPT" -ge 2 ] && [ -f "$RUN_DIR/fix-notes.md" ]; then
    echo "Retry (attempt $ATTEMPT, fix-notes.md found): keeping the working tree changes from the previous attempt" >&2
else
    DIRTY="$(git status --porcelain)"
    if [ -n "$DIRTY" ]; then
        echo "Working tree is not clean:" >&2
        printf '%s\n' "$DIRTY" >&2
        if [ "$PR_MODE" = false ] && [ "$ATTEMPT" -ge 2 ] && [ ! -f "$RUN_DIR/fix-notes.md" ]; then
            echo "fix-notes.md not found: $RUN_DIR/fix-notes.md (a retry with attempt >= 2 needs fix-notes.md)" >&2
        fi
        echo "Next: escalate reason=dirty-tree"
        exit 20
    fi
fi

# 3. タスクの状態(--pr では行わない)
STATE_PATH=".agents/workflow/state.json"
if command -v cygpath > /dev/null 2>&1; then STATE_PATH="$(cygpath -m "$PWD/$STATE_PATH")"; fi
STATUS="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    s = json.load(f)
for t in s['tasks']:
    if t['id'] == sys.argv[2]:
        print(t['status']); break
" "$STATE_PATH" "$TASK_ID" 2> /dev/null)"
case "$PR_MODE:$STATUS" in
    true:*|*:pending|*:in_progress) ;;
    *)
        echo "Task $TASK_ID cannot be started (status: ${STATUS:-<absent>})" >&2
        echo "Next: escalate reason=task-status"
        exit 21
        ;;
esac

# 3'. worktree の作成(並列のとき。task-state の前に置き、失敗しても state.json を変えない)
if [ "$PARALLEL" = true ]; then
    WT_OUT="$(bash "$SCRIPT_DIR/dispatch-worktree.sh" create "$TASK_ID" "$ATTEMPT")"
    CODE=$?
    if [ "$CODE" -ne 0 ]; then
        printf '%s\n' "$WT_OUT" | grep -v '^Next:'
        if [ "$CODE" -eq 20 ]; then
            echo "Next: escalate reason=dirty-tree"
            exit 22
        fi
        echo "Next: escalate reason=worktree"
        exit 61
    fi
fi

# config.json の child_agent.<キー> を読む(読めなければ空)。bool は true のとき true と出す
cfg_get() {
    python3 -c "
import json, sys
try:
    with open('.agents/workflow/config.json', encoding='utf-8') as f:
        v = json.load(f)['child_agent'].get(sys.argv[1])
except Exception:
    v = None
if v is True:
    print('true')
elif isinstance(v, str):
    print(v)
" "$1" 2> /dev/null | tr -d '\r'
}

# 並列のとき、子の起動前の失敗で作った worktree を片付ける(出力は stderr へ)
abort_worktree() {
    if [ "$PARALLEL" = true ]; then
        bash "$SCRIPT_DIR/dispatch-worktree.sh" abort "$TASK_ID" "$ATTEMPT" >&2
    fi
}

# コマンドを実行し、失敗したら出力の末尾20行を stderr に出す($1=コマンド)
run_check_command() {
    local out code
    out="$(
        if [ "$(cfg_get isolate_xdg)" = true ]; then
            export XDG_CONFIG_HOME=".agents/workflow/.config"
            export XDG_DATA_HOME=".agents/workflow/.config"
        fi
        bash -c "$1" 2>&1
    )"
    code=$?
    if [ "$code" -ne 0 ]; then
        printf '%s\n' "$out" | tail -n 20 >&2
    fi
    return "$code"
}

# 3a. 疎通確認
HEALTHCHECK="$(cfg_get healthcheck_command)"
if [ -n "$HEALTHCHECK" ]; then
    if ! run_check_command "$HEALTHCHECK"; then
        abort_worktree
        echo "Next: escalate reason=healthcheck"
        exit 30
    fi
fi

# 3b. ウォームアップ(このサイクルの最初の dispatch のときだけ)
WARMUP="$(cfg_get warmup_command)"
if [ "$PR_MODE" = false ] && [ -n "$WARMUP" ] && ! compgen -G ".agents/workflow/runs/*/guard.sha256" > /dev/null; then
    if ! run_check_command "$WARMUP"; then
        abort_worktree
        echo "Next: escalate reason=warmup"
        exit 31
    fi
fi

# 4. プロンプト生成
if [ "$PR_MODE" = true ]; then
    GEN_OUT="$(bash "$SCRIPT_DIR/dispatch-prompt-gen.sh" --pr)"
else
    GEN_OUT="$(bash "$SCRIPT_DIR/dispatch-prompt-gen.sh" "$TASK_ID" "$ATTEMPT")"
fi
CODE=$?
if [ "$CODE" -ne 0 ]; then
    abort_worktree
    echo "Next: escalate reason=prompt-gen"
    exit $((40 + CODE))
fi

if [ "$PR_MODE" = true ]; then
    TASK_ID="$(printf '%s\n' "$GEN_OUT" | sed -n 's/^RunId: //p' | tr -d '\r' | head -n 1)"
    if [ -z "$TASK_ID" ]; then
        echo "dispatch-prompt-gen --pr did not report a RunId" >&2
        abort_worktree
        echo "Next: escalate reason=prompt-gen"
        exit 41
    fi
    RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
else
    # 5. 状態を in_progress にする
    if ! bash "$SCRIPT_DIR/task-state.sh" "$TASK_ID" start; then
        abort_worktree
        echo "Next: escalate reason=task-state"
        exit 50
    fi
fi

# 6. デタッチ起動
rm -f "$RUN_DIR/guard.sha256"
nohup bash "$SCRIPT_DIR/dispatch-run.sh" "$TASK_ID" "$ATTEMPT" > /dev/null 2>&1 &

# dispatch-run が guard.sha256 を作る(起動した)まで待つ
LAUNCH_TIMEOUT="${DISPATCH_START_LAUNCH_TIMEOUT:-30}"
if ! [[ "$LAUNCH_TIMEOUT" =~ ^[0-9]+$ ]]; then LAUNCH_TIMEOUT=30; fi
i=0
while [ ! -f "$RUN_DIR/guard.sha256" ]; do
    if [ "$i" -ge $((LAUNCH_TIMEOUT * 2)) ]; then
        echo "dispatch-run did not start: $RUN_DIR/guard.sha256 not found after ${LAUNCH_TIMEOUT}s" >&2
        echo "Next: escalate reason=launch"
        exit 60
    fi
    sleep 0.5
    i=$((i + 1))
done

echo "Run: ${TASK_ID}-${ATTEMPT}"
echo "Log: $RUN_DIR/output.log"
echo "Watch: tail -f $RUN_DIR/output.log"
echo "Watch all: bash .agents/workflow/scripts/workflow-logs.sh"
if [ "$PARALLEL" = true ]; then
    printf '%s\n' "$WT_OUT" | grep '^Carried:'
    echo "Worktree: $RUN_DIR/worktree"
fi
echo "Next: wait"
exit 0
