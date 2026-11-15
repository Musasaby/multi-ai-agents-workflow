#!/bin/bash
set -uo pipefail

# 1グループ分のタスクを、タスクの起動と実装の run の完了待ちまで進める(レビュー以降の段階は
# T13〜T15 で足す)。進行中(in_progress / in_review)のタスクを run-phase の段階に応じて1つずつ
# 進め、next-task で空きの分だけ新しいタスクを起動する。--max-wait 秒に達するか、グループが
# 終わるか、止まるまで動く(常駐はしない。呼び直せば state.json と runs/ から続きを再開する)。
# Usage: workflow-run.sh [--max-wait <秒>] [--interval <秒>]
#   --max-wait の既定は 480(1回の呼び出しで進める上限。0 は上限なし) /
#   --interval の既定は 15(状態を確かめ直す間隔)
# exit: 0 = グループが終わった(Next: group-advance / Next: finish。next-task の結果)
#       1 = 使い方の誤り、または state.json が無い(Next: 行は出さない)
#       2 = --max-wait に達した(Next: wait)
#       3 = 止まった(Next: escalate reason=<理由>。段階が manual のときだけ Next: review <ID>)
#       4 = 使える条件を満たさない(Next: escalate reason=runner-unsupported)
#       5 = 別の workflow-run が実行中(Next: escalate reason=already-running)
# 使える条件: config.json の review.mode が dispatch、review.command_template が空でない、
#   max_parallel が 2 以上の整数。どれかを満たさなければ stderr に理由を出して exit 4 する。
# stdout の行(詳細は runs/workflow-run/last-output.log):
#   Started: <ID>-<N>            実装の run を起動した
#   Checked: <ID>-<N>            実装の run が dispatch-check を通った
#   Review started: <ID>-<N>     レビューの run を起動した
#   Review: <ID>-<N> <pass|fail> レビューの run の結果
#   Collected: <ID>-<N>          実装の run を取り込んだ
#   Undeclared: <ID> <パス>      変更対象に宣言していないファイル
#   Gate warning: <ID> <ステップ> 非 blocking の品質ゲートが失敗した
#   Done: <ID> <ハッシュ7桁> retries=<n>  コミットした
#   Stopped: <ID> reason=<理由>  止まった(タスクIDが無ければ -)
#   Finished: <Next の値>        グループが終わった
#   In flight: <ID>-<N> <段階>   実行中のタスク(記録には書かない)
#   Detail: <last-output.log のパス>  止まったときの詳細(記録には書かない)
# Started:・Checked:・Review started:・Review:・Collected:・Undeclared:・Gate warning:・Done:・
# Stopped:・Finished: は runs/workflow-run/progress.log にも時刻付きで書く。
# 止まる理由には review-invalid(レビューの完了報告が無効・異常終了・時間超過など)・
#   conflict(collect の衝突)・quality-gate(品質ゲートの失敗)・quality-gate-error(品質ゲートの異常終了)・
#   commit-format(type か要約が不正)・task-state(状態遷移の失敗)がある。
# ロック: runs/workflow-run/lock/pid に自分の PID を書いて実行する。ロックがあり、そのプロセスが
#   生きていれば exit 5、死んでいれば引き継ぐ。

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1

USAGE="Usage: workflow-run.sh [--max-wait <秒>] [--interval <秒>]"
MAX_WAIT=480
INTERVAL=15
while [ $# -gt 0 ]; do
    case "$1" in
        --max-wait|--interval)
            if [ $# -lt 2 ]; then echo "$1 requires a value" >&2; echo "$USAGE" >&2; exit 1; fi
            if [ "$1" = --max-wait ]; then MAX_WAIT="$2"; else INTERVAL="$2"; fi
            shift 2 ;;
        *) echo "Unknown argument: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
done
if ! [[ "$MAX_WAIT" =~ ^[0-9]+$ ]] || ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "Invalid --max-wait/--interval: '$MAX_WAIT' '$INTERVAL'" >&2
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

# 使える条件(config.json)をロックの前に確かめる。満たさなければ理由を stderr に出して exit 4
UNSUPPORTED="$(python3 - "$(to_py_path "$CONFIG_PATH")" <<'PY' 2> /dev/null | tr -d '\r'
import json, sys

try:
    with open(sys.argv[1], encoding='utf-8') as f:
        cfg = json.load(f)
except Exception as e:
    print('config.json cannot be read: ' + str(e))
    sys.exit(0)

review = cfg.get('review')
if not isinstance(review, dict):
    review = {}
mode = review.get('mode')
mp = cfg.get('max_parallel')
if mode != 'dispatch':
    print("review.mode is not 'dispatch' (review.mode: " + ('<absent>' if mode is None else str(mode)) + ')')
elif not review.get('command_template'):
    print('review.command_template is empty')
elif isinstance(mp, bool) or not isinstance(mp, int) or mp < 2:
    print('max_parallel must be an integer >= 2 (max_parallel: ' + ('<absent>' if mp is None else str(mp)) + ')')
PY
)"
if [ -n "$UNSUPPORTED" ]; then
    echo "$UNSUPPORTED" >&2
    echo "Next: escalate reason=runner-unsupported"
    exit 4
fi

RUNS=.agents/workflow/runs
RUNNER_DIR=$RUNS/workflow-run
LOCK_DIR=$RUNNER_DIR/lock
PROGRESS=$RUNNER_DIR/progress.log
LAST=$RUNNER_DIR/last-output.log

mkdir -p "$RUNNER_DIR"
if ! mkdir "$LOCK_DIR" 2> /dev/null; then
    OLD_PID="$(tr -d '[:space:]' < "$LOCK_DIR/pid" 2> /dev/null)"
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2> /dev/null; then
        echo "workflow-run is already running (pid $OLD_PID)" >&2
        echo "Next: escalate reason=already-running"; exit 5
    fi
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || exit 1    # 死んだプロセスのロックは引き継ぐ
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# stdout に出し、progress.log にも時刻付きで書く
emit() { echo "$1"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$PROGRESS"; }

# スクリプトを呼び、出力を $LAST に書く。CALL_CODE に exit code、CALL_NEXT に最後の `Next: ` 行の値を入れる
call() { bash "$SCRIPT_DIR/$1" "${@:2}" > "$LAST" 2>&1; CALL_CODE=$?
         CALL_NEXT="$(tr -d '\r' < "$LAST" | sed -n 's/^Next: //p' | tail -n 1)"; }

# CALL_NEXT が `escalate reason=X` なら X、そうでなければ $1 を出す
next_reason() { case "$CALL_NEXT" in "escalate reason="*) echo "${CALL_NEXT#escalate reason=}" ;; *) echo "$1" ;; esac; }

# state.json のタスク $1 のキー $2 の値を出す(無ければ空)
state_field() {
    python3 - "$(to_py_path "$STATE_PATH")" "$1" "$2" <<'PY' 2> /dev/null | tr -d '\r'
import json, sys
state_path, task_id, key = sys.argv[1:4]
with open(state_path, encoding='utf-8') as f:
    state = json.load(f)
for t in state.get('tasks', []):
    if t.get('id') == task_id:
        v = t.get(key)
        if v is None:
            print('')
        elif isinstance(v, bool):
            print('true' if v else 'false')
        else:
            print(v)
        break
PY
}

# status が in_progress / in_review のタスクIDを state.json の順に、空白区切りで出す
active_ids() {
    python3 - "$(to_py_path "$STATE_PATH")" <<'PY' 2> /dev/null | tr -d '\r'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    state = json.load(f)
print(' '.join(t['id'] for t in state.get('tasks', []) if t.get('status') in ('in_progress', 'in_review')))
PY
}

# run-phase の `Phase: ` の後ろ("<段階> <N>")を出す
phase_of() { bash "$SCRIPT_DIR/run-phase.sh" "$1" | sed -n 's/^Phase: //p' | tr -d '\r'; }

# 実行中のタスクを `In flight: <ID>-<N> <段階>` で出す(記録には書かない)
print_in_flight() {
    local id phase n
    for id in $(active_ids); do
        read -r phase n <<< "$(phase_of "$id")"
        echo "In flight: $id-$n $phase"
    done
}

# 止まる。$1=タスクID(無ければ -)、$2=理由、$3=最後の行(省略時は `Next: escalate reason=$2`)
stop_run() { emit "Stopped: $1 reason=$2"; echo "Detail: $LAST"; print_in_flight
             echo "${3:-Next: escalate reason=$2}"; exit 3; }

# $1=ID $2=試行回数。実装の run を起動する
start_task() {
    call dispatch-start.sh "$1" "$2"
    if [ "$CALL_CODE" -eq 0 ] && [ "$CALL_NEXT" = wait ]; then emit "Started: $1-$2"
    else stop_run "$1" "$(next_reason dispatch-start)"; fi
}

# $1=ID $2=試行回数。実装の run の完了を1回だけ確かめる
poll_impl() {
    call dispatch-wait.sh "$1" "$2" --max-wait 0
    case "$CALL_CODE" in
        2) return ;;                                     # 実行中
        0) if [ "$CALL_NEXT" = "collect $1" ]; then : > "$RUNS/$1-$2/checked"; emit "Checked: $1-$2"
           else stop_run "$1" not-worktree; fi ;;        # worktree の run ではない
        *) stop_run "$1" "$(next_reason dispatch-check)" ;;   # timeout・abnormal-exit・tampered など
    esac
}

# $1=ID $2=試行回数。レビューの run を起動する
start_review() {
    call dispatch-start.sh --review "$1" "$2"
    if [ "$CALL_CODE" -eq 0 ] && [ "$CALL_NEXT" = wait ]; then emit "Review started: $1-$2"
    else stop_run "$1" "$(next_reason review-start)"; fi
}

# $LAST から `<見出し>: ` で始まる最後の行の値を出す($1=見出し。例: "Review type")
last_field() { tr -d '\r' < "$LAST" | sed -n "s/^$1: //p" | tail -n 1; }

# $1=ID $2=試行回数。レビューの run の完了を1回だけ確かめる
poll_review() {
    local vfile="$RUNS/review-$1-$2/verdict"
    call dispatch-wait.sh "review-$1" "$2" --max-wait 0
    if [ "$CALL_CODE" -eq 2 ]; then return; fi
    if [ "$CALL_CODE" -eq 0 ] && [ "$CALL_NEXT" = "commit $1" ]; then
        printf 'pass\n%s\n%s\n' "$(last_field 'Review type')" "$(last_field 'Review summary')" > "$vfile"
        emit "Review: $1-$2 pass"
    elif [ "$CALL_CODE" -eq 0 ] && [ "$CALL_NEXT" = "retry $1" ]; then
        printf 'fail\n' > "$vfile"; emit "Review: $1-$2 fail"
    else
        stop_run "$1" review-invalid       # 完了報告が無効・異常終了・時間超過など
    fi
}

# config.json の最上位のキー $1 の値を出す(bool は true/false、文字列・数値はそのまま、無ければ空)
cfg_value() {
    python3 - "$(to_py_path "$CONFIG_PATH")" "$1" <<'PY' 2> /dev/null | tr -d '\r'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
if sys.argv[2] not in cfg or cfg[sys.argv[2]] is None:
    print('')
else:
    v = cfg[sys.argv[2]]
    if isinstance(v, bool):
        print('true' if v else 'false')
    else:
        print(v)
PY
}

# 品質ゲートの方式を出す: quality_gate があれば steps、無くて test_command が空でなければ test、どちらも無ければ none
gate_mode() {
    python3 - "$(to_py_path "$CONFIG_PATH")" <<'PY' 2> /dev/null | tr -d '\r'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        cfg = json.load(f)
except Exception:
    print('none')
    sys.exit(0)
if 'quality_gate' in cfg:
    print('steps')
elif str(cfg.get('test_command') or '').strip():
    print('test')
else:
    print('none')
PY
}

# $1=ID $2=試行回数。合格した run を取り込み、レビュー役の type と要約でコミットする
collect_task() {
    call dispatch-worktree.sh collect "$1" "$2"
    case "$CALL_CODE" in
        0) tr -d '\r' < "$LAST" | sed -n 's/^Undeclared: //p' | while IFS= read -r p; do
               [ "$p" = none ] || emit "Undeclared: $1 $p"; done
           call task-state.sh "$1" review
           [ "$CALL_CODE" -eq 0 ] || stop_run "$1" task-state
           emit "Collected: $1-$2"
           gate_and_commit "$1" "$2" ;;
        40) stop_run "$1" conflict ;;                          # T15 で redo_after_conflict に置き換える
        *) stop_run "$1" "$(next_reason collect)" ;;           # dirty-tree・worktree
    esac
}

# $1=ID $2=試行回数。品質ゲートを通し、コミットする(状態は in_review で、変更は本体にある)
gate_and_commit() {
    local vfile="$RUNS/review-$1-$2/verdict" type summary hash
    type="$(sed -n 2p "$vfile" | tr -d '\r')"; summary="$(sed -n 3p "$vfile" | tr -d '\r')"
    if [ "$(cfg_value verify_before_commit)" = true ]; then
        case "$(gate_mode)" in
            steps)
                call quality-gate.sh --out-dir "$RUNS/$1-$2/gate"
                case "$CALL_CODE" in
                    0) tr -d '\r' < "$LAST" | sed -n 's/^FAIL \([^ ]*\) (non-blocking).*/\1/p' | while IFS= read -r s; do
                           emit "Gate warning: $1 $s"; done ;;
                    3) : ;;                               # 実行するステップが無い
                    2) stop_run "$1" quality-gate ;;      # T15 で retry_after_gate に置き換える
                    *) stop_run "$1" quality-gate-error ;;
                esac ;;
            test)
                mkdir -p "$RUNS/$1-$2/gate"
                if ! bash -c "$(cfg_value test_command)" < /dev/null > "$RUNS/$1-$2/gate/test_command.log" 2>&1; then
                    cp "$RUNS/$1-$2/gate/test_command.log" "$LAST"
                    stop_run "$1" quality-gate            # T15 で retry_after_gate に置き換える
                fi ;;
        esac
    fi
    case "$type" in feat|fix|refactor|docs|test|chore|perf|ci) ;; *) stop_run "$1" commit-format ;; esac
    if [ -z "$summary" ] || [ "$summary" = "(list)" ]; then stop_run "$1" commit-format; fi
    call task-commit.sh "$1" "$type" "$summary"
    if [ "$CALL_CODE" -ne 0 ] || [ "$CALL_NEXT" != continue ]; then stop_run "$1" "$(next_reason commit)"; fi
    hash="$(tr -d '\r' < "$LAST" | sed -n 's/^Committed: \([0-9a-f]*\) .*/\1/p' | tail -n 1)"
    emit "Done: $1 $hash retries=$(state_field "$1" retries)"
}

# $1=ID。run-phase の段階に応じて1つ進める
handle_task() {
    local phase n; read -r phase n <<< "$(phase_of "$1")"
    case "$phase" in
        start)   start_task "$1" "$n" ;;
        running) poll_impl "$1" "$n" ;;
        review-start) start_review "$1" "$n" ;;
        reviewing)    poll_review "$1" "$n" ;;
        collect) collect_task "$1" "$n" ;;
        gate)    gate_and_commit "$1" "$n" ;;
        retry)   stop_run "$1" not-implemented ;;   # T15 で置き換える
        manual)  stop_run "$1" manual "Next: review $1" ;;
        *)       stop_run "$1" unknown-phase ;;
    esac
}

START="$(date +%s)"
while :; do
    for ID in $(active_ids); do handle_task "$ID"; done
    call next-task.sh
    case "$CALL_CODE" in
        0) case "$CALL_NEXT" in
               "dispatch "*) for ID in ${CALL_NEXT#dispatch }; do start_task "$ID" 1; done ;;
               *) stop_run - next-task ;;
           esac ;;
        5) : ;;                                          # 実行中のタスクの完了待ち
        3|6) emit "Finished: $CALL_NEXT"; echo "Next: $CALL_NEXT"; exit 0 ;;
        4) stop_run - blocked ;;
        *) stop_run - next-task ;;
    esac
    if [ "$MAX_WAIT" -gt 0 ] && [ $(( $(date +%s) - START )) -ge "$MAX_WAIT" ]; then
        print_in_flight; echo "Next: wait"; exit 2
    fi
    sleep "$INTERVAL"
done
