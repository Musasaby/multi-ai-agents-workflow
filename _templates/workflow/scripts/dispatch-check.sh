#!/bin/bash
set -uo pipefail

# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# Usage: dispatch-check.sh <TaskId> [Attempt]
# exit: 0=正常終了かつ完了報告あり / 1=done マーカーが無い・使い方不備
#       4=異常終了(非0・signal・crashed) / 5=EXIT:0 だが完了報告が無い

TASK_ID="${1:?Usage: dispatch-check.sh <TaskId> [Attempt]}"
ATTEMPT="${2:-1}"
TAIL_LINES=30

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
DONE_PATH="$RUN_DIR/done"
LOG_PATH="$RUN_DIR/output.log"

if [ ! -f "$DONE_PATH" ]; then
    echo "done marker not found: $DONE_PATH (child agent has not finished yet)" >&2
    exit 1
fi

# Windows PowerShell 5.1 の Out-File は BOM を付けるため除去してから読む
EXIT_VALUE="$(sed -n '1s/^\xEF\xBB\xBF//; s/\r$//; s/^EXIT://p' "$DONE_PATH" | head -1)"
END_VALUE="$(sed -n 's/\r$//; s/^END://p' "$DONE_PATH" | head -1)"

case "$EXIT_VALUE" in
    0) KIND=ok ;;
    signal:*) KIND=signal ;;
    crashed:*) KIND=crashed ;;
    '') KIND=unknown ;;
    *) KIND=nonzero ;;
esac

REPORT=missing
if [ -f "$LOG_PATH" ] && grep -q '^## 完了報告' "$LOG_PATH"; then
    REPORT=found
fi

if [ "$KIND" != ok ]; then
    VERDICT="abnormal-exit"
    CODE=4
elif [ "$REPORT" != found ]; then
    VERDICT="no-report"
    CODE=5
else
    VERDICT="ok"
    CODE=0
fi

echo "Run: ${TASK_ID}-${ATTEMPT}"
echo "Exit: ${EXIT_VALUE} (kind: ${KIND})"
echo "End: ${END_VALUE}"
echo "Completion report: ${REPORT}"
echo "Verdict: ${VERDICT}"
echo "--- git status --porcelain"
git status --porcelain
echo "--- git diff --stat"
git diff --stat
echo "--- output.log (last ${TAIL_LINES} lines)"
if [ -f "$LOG_PATH" ]; then
    tail -n "$TAIL_LINES" "$LOG_PATH"
else
    echo "(output.log not found)"
fi

exit "$CODE"
