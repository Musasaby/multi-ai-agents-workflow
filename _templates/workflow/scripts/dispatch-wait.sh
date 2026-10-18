#!/bin/bash
set -uo pipefail

# 子エージェントの run(runs/<ID>-<N>/)の完了をポーリングで待つ(#56。親が書いていた
# 待ちループの置き換え)。1回の呼び出しで --max-wait 秒まで待つ(親ツールのコマンド実行
# 上限に合わせて呼び出し側から渡す。exit 2 で返れば、再度このスクリプトを呼んで待ちを
# 続ける)。経過秒数の基準(= run の開始時刻)は dispatch-run が起動時に作る
# runs/<ID>-<N>/guard.sha256 の最終更新時刻。done マーカーがあれば dispatch-check.sh に
# 判定を任せ、その結果をそのまま返す。
# Usage: dispatch-wait.sh <TaskId> [Attempt] [--max-wait <秒>] [--interval <秒>]
#   Attempt の既定は 1 / --max-wait の既定は 480(1回の呼び出しで待つ上限) /
#   --interval の既定は 15(ポーリング間隔)
# exit: 0/4/5/6/7/8 = dispatch-check.sh の結果をそのまま(done があった場合)
#       1 = 使い方不備、または run が起動されていない(guard.sha256 が無い)
#       2 = まだ実行中(この呼び出しの待ち時間が --max-wait に達した)
#       3 = 経過が config.json の child_agent.timeout_seconds を超えた
# exit 2/3 のとき、stdout に状況行(Run / Status: running / Elapsed / Log idle / Log)を
# 出し、最後の行に Next: wait / Next: escalate reason=timeout を出す

TASK_ID="${1:-}"
ATTEMPT=""
MAX_WAIT=480
INTERVAL=15
USAGE="Usage: dispatch-wait.sh <TaskId> [Attempt] [--max-wait <秒>] [--interval <秒>]"
if [ -z "$TASK_ID" ]; then
    echo "$USAGE" >&2
    exit 1
fi
shift
# Attempt は TaskId の直後(オプションの前)にだけ置ける
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    ATTEMPT="$1"
    shift
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --max-wait|--interval)
            if [ $# -lt 2 ]; then echo "$1 requires a value" >&2; exit 1; fi
            if [ "$1" = --max-wait ]; then MAX_WAIT="$2"; else INTERVAL="$2"; fi
            shift 2 ;;
        *) echo "Unknown argument: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
done
ATTEMPT="${ATTEMPT:-1}"
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] \
    || ! [[ "$MAX_WAIT" =~ ^[0-9]+$ ]] || ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "Invalid TaskId/Attempt/--max-wait/--interval: '$TASK_ID' '$ATTEMPT' '$MAX_WAIT' '$INTERVAL'" >&2
    exit 1
fi

# 経過秒数の計算に python3 が要る(bash だけではファイル時刻の移植性のある取得方法が
# 無い。python3 が無いまま静かに待ち続けると、時間超過を検知できなくなるため始めに止める)
if ! command -v python3 > /dev/null 2>&1; then
    echo "python3 not found (required to compute elapsed time)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
DONE_PATH="$RUN_DIR/done"
LOG_PATH="$RUN_DIR/output.log"
GUARD_PATH="$RUN_DIR/guard.sha256"

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

# <ファイル> の最終更新からの経過秒数(取れなければ 0)
seconds_since() {
    local out
    out="$(python3 -c 'import os,sys,time; print(int(time.time() - os.path.getmtime(sys.argv[1])))' \
        "$(to_py_path "$1")" 2>/dev/null | tr -d '\r')"
    if [[ "$out" =~ ^[0-9]+$ ]]; then echo "$out"; else echo 0; fi
}

# run が dispatch-run で起動されていなければ待てない(guard.sha256 は dispatch-run が
# 起動時に作る。done より先に確かめる = 開始時刻が無ければ経過秒数も出せないため)
if [ ! -f "$GUARD_PATH" ]; then
    echo "guard.sha256 not found: $GUARD_PATH (the run was not started by dispatch-run)" >&2
    exit 1
fi

# config.json の child_agent.timeout_seconds(無い・読めなければ 1800。0 以下は無効 = 判定しない)
TIMEOUT_SECONDS="$(python3 -c "import json
try: v = json.load(open('.agents/workflow/config.json', encoding='utf-8'))['child_agent'].get('timeout_seconds')
except Exception: v = None
print(1800 if not isinstance(v, (int, float)) or isinstance(v, bool) else int(v))" 2>/dev/null | tr -d '\r')"
if ! [[ "$TIMEOUT_SECONDS" =~ ^-?[0-9]+$ ]]; then
    TIMEOUT_SECONDS=1800
fi
if [ "$TIMEOUT_SECONDS" -le 0 ]; then
    TIMEOUT_SECONDS=0
fi

# 状況行(exit 2/3 のときに stdout へ出す。$1 = 経過秒数)
print_status() {
    local log_idle
    if [ -f "$LOG_PATH" ]; then
        log_idle="$(seconds_since "$LOG_PATH")s"
    else
        log_idle=-
    fi
    echo "Run: ${TASK_ID}-${ATTEMPT}"
    echo "Status: running"
    echo "Elapsed: ${1}s"
    echo "Log idle: ${log_idle}"
    echo "Log: $LOG_PATH"
}

# --- ポーリングループ((a) done → (b) timeout_seconds → (c) --max-wait → (d) sleep) ---
WAIT_START="$(date +%s)"
while :; do
    # (a) done があれば dispatch-check に判定させる。stdout/stderr はそのまま流し、
    # exit code も dispatch-check のものをそのまま返す
    if [ -f "$DONE_PATH" ]; then
        bash "$SCRIPT_DIR/dispatch-check.sh" "$TASK_ID" "$ATTEMPT"
        exit $?
    fi
    ELAPSED="$(seconds_since "$GUARD_PATH")"
    # (b) 経過が timeout_seconds(有効なときだけ)を超えていれば、時間超過として親に返す
    if [ "$TIMEOUT_SECONDS" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
        print_status "$ELAPSED"
        echo "Next: escalate reason=timeout"
        exit 3
    fi
    # (c) この呼び出しで待った秒数が --max-wait に達していれば、まだ実行中として親に返す
    # (親は再度このスクリプトを呼んで待ちを続ける)
    if [ $(( $(date +%s) - WAIT_START )) -ge "$MAX_WAIT" ]; then
        print_status "$ELAPSED"
        echo "Next: wait"
        exit 2
    fi
    # (d) ポーリング間隔だけ待って (a) に戻る(最初の確認はこの sleep の前に行う)
    sleep "$INTERVAL"
done
