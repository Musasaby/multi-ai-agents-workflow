#!/bin/bash
set -uo pipefail

# 子エージェントの起動までの事前チェックを順に行い、デタッチ起動する。失敗した段階で止める
# (止めたときは state.json を変えず、子も起動しない)。
# Usage: dispatch-start.sh <TaskId> [Attempt]
# exit:
#   0=起動した / 1=使い方不備
#   11〜15=branch-check --state の 1〜5(stdout の Next: 行はそのまま流す)
#   20=作業ツリーが汚れている / 21=タスクの状態が不正(pending / in_progress 以外、タスク無しを含む)
#   30=疎通確認(healthcheck_command)の失敗 / 31=ウォームアップ(warmup_command)の失敗
#   41〜43=dispatch-prompt-gen の 1〜3(依存未完了・report.md の欠落は 42)
#   50=task-state の失敗
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / escalate reason=<理由> 等。
# 使い方不備の exit 1 では出さない)

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

TASK_ID="${1:?Usage: dispatch-start.sh <TaskId> [Attempt]}"
ATTEMPT="${2:-1}"
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]]; then
    echo "Invalid TaskId/Attempt: '$TASK_ID' '$ATTEMPT'" >&2
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

# 2. 作業ツリー
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
    echo "Working tree is not clean:" >&2
    printf '%s\n' "$DIRTY" >&2
    echo "Next: escalate reason=dirty-tree"
    exit 20
fi

# 3. タスクの状態
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
case "$STATUS" in
    pending|in_progress) ;;
    *)
        echo "Task $TASK_ID cannot be started (status: ${STATUS:-<absent>})" >&2
        echo "Next: escalate reason=task-status"
        exit 21
        ;;
esac

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
        echo "Next: escalate reason=healthcheck"
        exit 30
    fi
fi

# 3b. ウォームアップ(このサイクルの最初の dispatch のときだけ)
WARMUP="$(cfg_get warmup_command)"
if [ -n "$WARMUP" ] && ! compgen -G ".agents/workflow/runs/*/guard.sha256" > /dev/null; then
    if ! run_check_command "$WARMUP"; then
        echo "Next: escalate reason=warmup"
        exit 31
    fi
fi

# 4. プロンプト生成
bash "$SCRIPT_DIR/dispatch-prompt-gen.sh" "$TASK_ID" "$ATTEMPT" > /dev/null
CODE=$?
if [ "$CODE" -ne 0 ]; then
    echo "Next: escalate reason=prompt-gen"
    exit $((40 + CODE))
fi

# 5. 状態を in_progress にする
if ! bash "$SCRIPT_DIR/task-state.sh" "$TASK_ID" start; then
    echo "Next: escalate reason=task-state"
    exit 50
fi

# 6. デタッチ起動
nohup bash "$SCRIPT_DIR/dispatch-run.sh" "$TASK_ID" "$ATTEMPT" > /dev/null 2>&1 &

echo "Run: ${TASK_ID}-${ATTEMPT}"
echo "Log: $RUN_DIR/output.log"
echo "Watch: tail -f $RUN_DIR/output.log"
echo "Next: wait"
exit 0
