#!/bin/bash
# #27: task-state(state.json の状態遷移, POSIX版)
source "$(dirname "$0")/lib.sh"

state_text() { cat "$PROJ/.agents/workflow/state.json"; }

expect_ok() { # $1=期待 status, 残り=task-state の引数
    local want="$1"; shift
    run_script task-state.sh "$@"
    assert_eq 0 "$CODE" "task-state $* exit: $ERR"
    assert_eq "$want" "$(state_get T1 status)" "task-state $* status"
}

expect_reject() { # $1=期待 exit, 残り=task-state の引数
    local want="$1"; shift
    local before
    before="$(state_text)"
    run_script task-state.sh "$@"
    assert_eq "$want" "$CODE" "task-state $* rejected"
    assert_eq "$before" "$(state_text)" "task-state $* leaves state.json unchanged"
}

t_start() {
    write_state "T1:pending"
    expect_ok in_progress T1 start
    assert_not_contains "$(state_text)" "2026-01-01T00:00:00+09:00" "updated_at refreshed"
    expect_ok in_progress T1 start
}

t_start_from_done_rejected() {
    write_state "T1:done"
    expect_reject 1 T1 start
}

t_review() {
    write_state "T1:in_progress"
    expect_ok in_review T1 review
    write_state "T1:pending"
    expect_reject 1 T1 review
}

t_done() {
    write_state "T1:in_review"
    expect_reject 1 T1 done
    expect_reject 1 T1 done --commit "not-a-hash"
    expect_ok done T1 done --commit abc1234
    assert_eq abc1234 "$(state_get T1 commit)" "commit recorded"
    write_state "T1:in_progress"
    expect_reject 1 T1 done --commit abc1234
}

t_retry() {
    write_state "T1:in_review:1"
    expect_ok in_progress T1 retry
    assert_eq 2 "$(state_get T1 retries)" "retries incremented"
}

t_retry_limit() {
    write_state "T1:in_review:2"   # config テンプレートの max_fix_retries は 2
    expect_reject 4 T1 retry
}

t_fail_and_reset() {
    write_state "T1:pending"
    expect_reject 1 T1 fail
    write_state "T1:in_progress:2"
    expect_ok failed T1 fail
    expect_ok pending T1 reset
    assert_eq 0 "$(state_get T1 retries)" "reset clears retries"
    write_state "T1:in_progress"
    expect_reject 1 T1 reset
}

t_invalid_args() {
    write_state "T1:pending"
    expect_reject 1 T9 start
    expect_reject 1 T1 explode
    expect_reject 1 "../x" start
}

t_other_tasks_untouched() {
    write_state "T1:pending" "T2:in_review:1"
    run_script task-state.sh T1 start
    assert_eq in_review "$(state_get T2 status)" "T2 status kept"
    assert_eq 1 "$(state_get T2 retries)" "T2 retries kept"
}

echo "test-task-state.sh"
test_case "start" t_start
test_case "start: done からは拒否" t_start_from_done_rejected
test_case "review" t_review
test_case "done: --commit 必須" t_done
test_case "retry" t_retry
test_case "retry: 上限超過は exit 4" t_retry_limit
test_case "fail / reset" t_fail_and_reset
test_case "不正な引数" t_invalid_args
test_case "他のタスクは変えない" t_other_tasks_untouched
summary
