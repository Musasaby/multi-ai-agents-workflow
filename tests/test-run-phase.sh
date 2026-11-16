#!/bin/bash
# T10: run-phase(state.json と runs/ からタスクの段階を判定, POSIX版)
source "$(dirname "$0")/lib.sh"

# runs/ 配下のファイル一覧(実行前後で増えないことを確かめる)
runs_files() {
    (cd "$PROJ" && find .agents/workflow/runs -type f 2> /dev/null | sort)
}

# expect_phase <期待する1行> [TaskId] → 出力・exit 0・state.json と runs/ が変わらないことを確かめる
expect_phase() {
    local want="$1" id="${2:-T1}" state_before runs_before
    state_before="$(cat "$PROJ/.agents/workflow/state.json")"
    runs_before="$(runs_files)"
    run_script run-phase.sh "$id"
    assert_eq 0 "$CODE" "run-phase $id exit: $ERR"
    assert_eq "$want" "$OUT" "run-phase $id output"
    assert_eq "$state_before" "$(cat "$PROJ/.agents/workflow/state.json")" "state.json unchanged"
    assert_eq "$runs_before" "$(runs_files)" "runs/ unchanged"
}

t_in_progress_from_runs() {
    local R="$PROJ/.agents/workflow/runs"
    write_state "T1:in_progress"
    expect_phase "Phase: start 1"
    mkdir -p "$R/T1-1"
    : > "$R/T1-1/guard.sha256"
    expect_phase "Phase: running 1"
    : > "$R/T1-1/checked"
    expect_phase "Phase: review-start 1"
    mkdir -p "$R/review-T1-1"
    : > "$R/review-T1-1/guard.sha256"
    expect_phase "Phase: reviewing 1"
}

t_verdict_and_marks() {
    local R="$PROJ/.agents/workflow/runs"
    write_state "T1:in_progress"
    mkdir -p "$R/T1-1" "$R/review-T1-1"
    : > "$R/T1-1/guard.sha256"
    : > "$R/T1-1/checked"
    : > "$R/review-T1-1/guard.sha256"
    printf 'pass\n' > "$R/review-T1-1/verdict"
    expect_phase "Phase: collect 1"
    printf 'fail\n' > "$R/review-T1-1/verdict"
    expect_phase "Phase: retry 1"
    : > "$R/T1-1/superseded"
    expect_phase "Phase: start 2"
    rm -f "$R/T1-1/superseded"
    : > "$R/T1-1/collected"
    expect_phase "Phase: start 2"
}

t_in_review() {
    local R="$PROJ/.agents/workflow/runs"
    write_state "T1:in_review:1"
    mkdir -p "$R/T1-1" "$R/review-T1-1"
    : > "$R/T1-1/guard.sha256"
    : > "$R/review-T1-1/guard.sha256"
    printf 'pass\n' > "$R/review-T1-1/verdict"
    : > "$R/T1-1/collected"
    expect_phase "Phase: gate 1"
    printf 'fail\n' > "$R/review-T1-1/verdict"
    rm -f "$R/T1-1/collected"
    expect_phase "Phase: retry 1"
    rm -f "$R/review-T1-1/verdict"
    expect_phase "Phase: manual 1"
}

t_other_states_and_usage() {
    write_state "T1:pending"
    expect_phase "Phase: pending 0"
    run_script run-phase.sh T9
    assert_eq 1 "$CODE" "unknown task exit 1"
    assert_contains "$ERR" "not found" "unknown task explains"
    run_script run-phase.sh
    assert_eq 1 "$CODE" "no args exit 1"
    assert_contains "$ERR" "Usage:" "no args prints usage"
    rm -f "$PROJ/.agents/workflow/state.json"
    run_script run-phase.sh T1
    assert_eq 1 "$CODE" "no state.json exit 1"
    assert_contains "$ERR" "state.json not found" "no state.json explains"
}

echo "test-run-phase.sh"
test_case "in_progress の段階を run のファイルから判定する" t_in_progress_from_runs
test_case "verdict と印から collect・retry・次の試行を判定する" t_verdict_and_marks
test_case "in_review の段階を判定する" t_in_review
test_case "対象外の状態と使い方の誤り" t_other_states_and_usage
summary
