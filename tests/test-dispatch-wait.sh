#!/bin/bash
# T13(#56): dispatch-wait.sh(子の完了待ちポーリング)
source "$(dirname "$0")/lib.sh"

# dispatch-run と同じ形式で guard.sha256 を書き(runs/<run>/prompt.md と管理ファイル)、
# dispatch-run と同じく git-state.sh の出力で git-state.txt も書く(tests/test-dispatch.sh と同じ作り方)
write_guard() { # $1 = run 名(例: T1-1)
    local run="$1" f h
    (
        cd "$PROJ" || exit 1
        : > ".agents/workflow/runs/$run/guard.sha256"
        for f in ".agents/workflow/runs/$run/prompt.md" .agents/workflow/state.json .agents/workflow/tasks.md .agents/workflow/config.json; do
            if [ -f "$f" ]; then h="$(sha256sum "$f" | cut -d' ' -f1)"; else h=-; fi
            printf '%s  %s\n' "$h" "$f" >> ".agents/workflow/runs/$run/guard.sha256"
        done
    )
    (cd "$PROJ" && .agents/workflow/scripts/git-state.sh) > "$PROJ/.agents/workflow/runs/$run/git-state.txt"
}

make_run() { # $1 = EXIT 値, $2 = output.log の内容, $3 = run 名(省略時 T1-1)
    local run="${3:-T1-1}"
    mkdir -p "$PROJ/.agents/workflow/runs/$run"
    printf 'prompt\n' > "$PROJ/.agents/workflow/runs/$run/prompt.md"
    printf 'EXIT:%s\nEND:2026-01-01T00:00:00+09:00\n' "$1" > "$PROJ/.agents/workflow/runs/$run/done"
    printf '%s\n' "$2" > "$PROJ/.agents/workflow/runs/$run/output.log"
    write_guard "$run"
}

# done 無しの実行中の run(runs/T1-1/ に guard.sha256・output.log だけ)
make_running_run() {
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    : > "$PROJ/.agents/workflow/runs/T1-1/guard.sha256"
    printf 'running\n' > "$PROJ/.agents/workflow/runs/T1-1/output.log"
}

REPORT=$'作業しました\n## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス'

# child_agent.timeout_seconds を設定する($1 = 秒)
set_timeout_seconds() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['timeout_seconds'] = int(v)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# <ファイル> の最終更新時刻を 60 秒前にする
mtime_60s_ago() {
    python3 - "$(py_path "$1")" <<'PY'
import os, sys, time
t = time.time() - 60
os.utime(sys.argv[1], (t, t))
PY
}

t_wait_done() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-wait.sh T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Verdict: ok" "verdict"
    assert_contains "$OUT" "Next: review T1" "next line"
}

t_wait_max_wait() {
    make_running_run
    run_script dispatch-wait.sh T1 1 --max-wait 1 --interval 1
    assert_eq 2 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Run: T1-1" "run line"
    assert_contains "$OUT" "Status: running" "status line"
    assert_contains "$OUT" "Elapsed: " "elapsed line"
    assert_contains "$OUT" "Log idle: " "log idle line"
    assert_contains "$OUT" "Log: .agents/workflow/runs/T1-1/output.log" "log line"
    assert_eq "Next: wait" "${OUT##*$'\n'}" "last line"
}

t_wait_timeout() {
    set_timeout_seconds 5
    make_running_run
    mtime_60s_ago "$PROJ/.agents/workflow/runs/T1-1/guard.sha256"
    run_script dispatch-wait.sh T1 1 --max-wait 10 --interval 1
    assert_eq 3 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Status: running" "status line"
    assert_eq "Next: escalate reason=timeout" "${OUT##*$'\n'}" "last line"
}

t_wait_not_started() {
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    printf 'running\n' > "$PROJ/.agents/workflow/runs/T1-1/output.log"
    run_script dispatch-wait.sh T1 1 --max-wait 1 --interval 1
    assert_eq 1 "$CODE" "exit code: $ERR"
    assert_contains "$ERR" "not started" "stderr"
}

echo "test-dispatch-wait.sh"

test_case "wait: done があれば dispatch-check の結果を返す" t_wait_done
test_case "wait: max-wait に達したら exit 2 と Next: wait" t_wait_max_wait
test_case "wait: 経過が timeout_seconds を超えたら exit 3" t_wait_timeout
test_case "wait: 起動されていない run は exit 1" t_wait_not_started
summary
