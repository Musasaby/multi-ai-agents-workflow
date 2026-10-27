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
    (cd "$PROJ" && .agents/workflow/scripts/workflow-logs.sh --run T1-1 --duration 3 --interval 0.5) > "$out_file" 2> /dev/null &
    local pid=$!
    sleep 1
    printf 'added line\n' >> "$PROJ/.agents/workflow/runs/T1-1/output.log"
    sleep 1
    printf 'EXIT:0\nEND:2026-01-01T00:00:00+09:00\n' > "$PROJ/.agents/workflow/runs/T1-1/done"
    wait "$pid"
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

echo "test-workflow-logs.sh"

test_case "logs: --once は実行中の run だけを接頭辞付きで出す" t_once_running_only
test_case "logs: --run で指定した run だけを出す" t_once_run_filter
test_case "logs: 追跡中に足した行と finished を出す" t_follow_appended
test_case "logs: --tail 1 は末尾の1行だけ出す" t_tail_one
test_case "logs: 未知の引数は exit 1" t_unknown_arg
summary
