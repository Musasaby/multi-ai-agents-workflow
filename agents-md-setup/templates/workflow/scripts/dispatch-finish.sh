#!/bin/bash
set -uo pipefail

# サブエージェントの run(runs/<ID>-<N>/launcher が subagent)を完了させる。
# 親がサブエージェントの最終応答を output.log に書いた後に呼ぶ。done が無ければ dispatch-run と
# 同じ形式(EXIT:<値> / END:<ISO 8601>)で書き、dispatch-check の結果をそのまま返す。
# done が既にあれば上書きしない。
# Usage: dispatch-finish.sh <TaskId> <Attempt> [--exit <値>]
#   --exit の既定は 0
# exit: 1 = 使い方不備・launcher が subagent でない・output.log が無い
#       それ以外 = dispatch-check.sh の exit code をそのまま(stdout・stderr もそのまま)

USAGE="Usage: dispatch-finish.sh <TaskId> <Attempt> [--exit <値>]"
TASK_ID="${1:-}"
ATTEMPT="${2:-}"
if [ -z "$TASK_ID" ] || [ -z "$ATTEMPT" ]; then
    echo "$USAGE" >&2
    exit 1
fi
shift 2
EXIT_VALUE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --exit)
            if [ $# -lt 2 ]; then echo "--exit requires a value" >&2; exit 1; fi
            EXIT_VALUE="$2"
            shift 2 ;;
        *) echo "Unknown argument: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
done
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] \
    || ! [[ "$EXIT_VALUE" =~ ^[0-9]+$ ]]; then
    echo "Invalid TaskId/Attempt/--exit: '$TASK_ID' '$ATTEMPT' '$EXIT_VALUE'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
DONE_PATH="$RUN_DIR/done"
LOG_PATH="$RUN_DIR/output.log"

if [ ! -f "$RUN_DIR/launcher" ] || [ "$(tr -d '[:space:]' < "$RUN_DIR/launcher")" != "subagent" ]; then
    echo "not a subagent run: $RUN_DIR (launcher is not subagent)" >&2
    exit 1
fi
if [ ! -f "$LOG_PATH" ]; then
    echo "output.log not found: $LOG_PATH (write the subagent's final response to it)" >&2
    exit 1
fi

if [ ! -f "$DONE_PATH" ]; then
    END_TIME=$(date -Iseconds)
    printf "EXIT:%s\nEND:%s\n" "$EXIT_VALUE" "$END_TIME" > "$DONE_PATH"
fi

bash "$SCRIPT_DIR/dispatch-check.sh" "$TASK_ID" "$ATTEMPT"
exit $?
