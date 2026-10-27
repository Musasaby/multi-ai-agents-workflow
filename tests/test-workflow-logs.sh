#!/bin/bash
# workflow-logs.sh(複数 run のログを1つの画面に流す)
source "$(dirname "$0")/lib.sh"

# 子を起動せずに run ディレクトリを作る($1 = run 名, $2 = output.log の内容, $3 = done の EXIT 値(省略時は done 無し))
make_run() {
    local d="$PROJ/.agents/workflow/runs/$1"
    mkdir -p "$d"
    : > "$d/guard.sha256"
    printf '%s\n' "$2" > "$d/output.log"
    if [ -n "${3-}" ]; then
        printf 'EXIT:%s\nEND:2026-01-01T00:00:00+09:00\n' "$3" > "$d/done"
    fi
}

t_once_running_only() {
    make_run T1-1 $'t1 line a\nt1 line b'
    make_run T2-1 't2 line a'
    make_run T3-1 't3 line a' 0
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    printf 'refine line\n' > "$PROJ/.agents/workflow/runs/refine/output.log"
    run_script workflow-logs.sh --once
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T1-1] t1 line b" "T1-1 の行"
    assert_contains "$OUT" "[T2-1] t2 line a" "T2-1 の行"
    assert_not_contains "$OUT" "[T3-1] " "done のある run は出さない"
    assert_not_contains "$OUT" "[refine] " "guard.sha256 の無い run は出さない"
}

t_once_run_filter() {
    make_run T1-1 't1 line a'
    make_run T2-1 't2 line a'
    run_script workflow-logs.sh --once --run T2-1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T2-1] t2 line a" "T2-1 の行"
    assert_not_contains "$OUT" "[T1-1] " "指定外の run は出さない"
}

t_follow_appended() {
    make_run T1-1 'first line'
    local out_file
    out_file="$(mktemp)"
    (cd "$PROJ" && .agents/workflow/scripts/workflow-logs.sh --run T1-1 --interval 0.5) > "$out_file" 2> /dev/null &
    local pid=$!
    sleep 1
    printf 'added line\n' >> "$PROJ/.agents/workflow/runs/T1-1/output.log"
    sleep 1
    printf 'EXIT:0\nEND:2026-01-01T00:00:00+09:00\n' > "$PROJ/.agents/workflow/runs/T1-1/done"
    local i=0 finished=1
    while [ "$i" -lt 60 ]; do
        if ! kill -0 "$pid" 2> /dev/null; then finished=0; break; fi
        sleep 0.5
        i=$((i + 1))
    done
    if [ "$finished" -ne 0 ]; then kill "$pid" 2> /dev/null; fi
    assert_eq 0 "$finished" "30 秒以内に自分で終わる"
    local wait_code=0
    wait "$pid" 2> /dev/null || wait_code=$?
    assert_eq 0 "$wait_code" "自分で exit 0 で終わる"
    local out
    out="$(cat "$out_file")"
    rm -f "$out_file"
    assert_contains "$out" "[T1-1] first line" "既存の行"
    assert_contains "$out" "[T1-1] added line" "追跡中に足した行"
    assert_contains "$out" "[T1-1] --- finished (0)" "終了行"
}

t_tail_one() {
    make_run T1-1 $'line a\nline b\nline c'
    run_script workflow-logs.sh --once --tail 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T1-1] line c" "最後の行"
    assert_not_contains "$OUT" "line a" "古い行は出さない"
    assert_not_contains "$OUT" "line b" "古い行は出さない"
}

t_unknown_arg() {
    run_script workflow-logs.sh --bogus
    assert_eq 1 "$CODE" "exit code: $ERR"
}

t_utf16le_bom() {
    local d="$PROJ/.agents/workflow/runs/T1-1"
    mkdir -p "$d"
    : > "$d/guard.sha256"
    python3 -c 'import sys; sys.stdout.buffer.write(b"\xff\xfe" + "こんにちは\nline2 テスト\n".encode("utf-16-le"))' > "$d/output.log"
    run_script workflow-logs.sh --once
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T1-1] こんにちは" "UTF-16LE の1行目"
    assert_contains "$OUT" "[T1-1] line2 テスト" "UTF-16LE の2行目"
    assert_not_contains "$OUT" $'\xef\xbf\xbd' "文字化けしない"
}

t_utf8_bom() {
    local d="$PROJ/.agents/workflow/runs/T1-1"
    mkdir -p "$d"
    : > "$d/guard.sha256"
    printf '\xef\xbb\xbffirst line\nsecond line\n' > "$d/output.log"
    run_script workflow-logs.sh --once
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T1-1] first line" "最初の行"
    assert_not_contains "$OUT" $'\xef\xbb\xbf' "BOM が残らない"
}

t_stale_run() {
    make_run T1-1 'old line'
    make_run T2-1 'fresh line'
    touch -d '2 hours ago' "$PROJ/.agents/workflow/runs/T1-1/output.log"
    run_script workflow-logs.sh --once
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T2-1] fresh line" "新しい run は出る"
    assert_not_contains "$OUT" "[T1-1] " "止まった run は出さない"
    run_script workflow-logs.sh --once --run T1-1
    assert_eq 0 "$CODE" "exit code (--run): $ERR"
    assert_contains "$OUT" "[T1-1] old line" "--run で指定すれば出る"
}

t_interval_zero() {
    make_run T1-1 'line'
    run_script workflow-logs.sh --once --interval 0
    assert_eq 1 "$CODE" "exit code: $ERR"
}

t_done_without_exit() {
    make_run T1-1 'line a'
    printf 'END:2026-01-01T00:00:00+09:00\n' > "$PROJ/.agents/workflow/runs/T1-1/done"
    run_script workflow-logs.sh --run T1-1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "[T1-1] --- finished (unknown)" "EXIT: 行が無い done"
}

echo "test-workflow-logs.sh"

test_case "logs: --once は実行中の run だけを接頭辞付きで出す" t_once_running_only
test_case "logs: --run で指定した run だけを出す" t_once_run_filter
test_case "logs: 追跡中に足した行と finished を出す" t_follow_appended
test_case "logs: --tail 1 は末尾の1行だけ出す" t_tail_one
test_case "logs: 未知の引数は exit 1" t_unknown_arg
test_case "logs: BOM 付き UTF-16LE のログを正しい文字で出す" t_utf16le_bom
test_case "logs: UTF-8 の BOM は出力に残らない" t_utf8_bom
test_case "logs: 止まった run は探索から外し --run なら出す" t_stale_run
test_case "logs: --interval 0 は exit 1" t_interval_zero
test_case "logs: EXIT: 行の無い done は finished (unknown)" t_done_without_exit
summary
