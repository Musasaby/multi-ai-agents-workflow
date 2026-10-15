#!/bin/bash
# workflow-archive(workflow 状態のアーカイブ移動, POSIX版)
source "$(dirname "$0")/lib.sh"

# "Archived: <dir> (<names>)" から <dir> を取り出す
archive_dir_of() {
    local rest="${OUT#"Archived: "}"
    echo "${rest%% (*}"
}

t_all_targets() {
    write_tasks "# tasks"
    write_state "T1:done"
    mkdir -p "$PROJ/.agents/workflow/runs/T0-1" "$PROJ/.agents/workflow/comprehension"
    printf 'r\n' > "$PROJ/.agents/workflow/runs/T0-1/report.md"
    printf 'q\n' > "$PROJ/.agents/workflow/comprehension/questions.md"
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    local dir
    dir="$(archive_dir_of)"
    assert_contains "$OUT" "(tasks.md, state.json, runs, comprehension)" "output lists all targets"
    assert_file_exists "$dir/tasks.md" "tasks.md moved"
    assert_file_exists "$dir/state.json" "state.json moved"
    assert_file_exists "$dir/runs/T0-1/report.md" "runs moved"
    assert_file_exists "$dir/comprehension/questions.md" "comprehension moved"
    assert_file_absent "$PROJ/.agents/workflow/tasks.md" "tasks.md removed from workflow dir"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json removed from workflow dir"
}

t_partial_targets() {
    write_state "T1:done"
    run_script workflow-archive.sh myslug
    assert_eq 0 "$CODE" "exit: $ERR"
    local dir
    dir="$(archive_dir_of)"
    assert_contains "$OUT" "(state.json, runs)" "output lists state.json and runs"
    assert_not_contains "$OUT" "tasks.md" "output lists only existing targets"
    assert_file_exists "$dir/state.json" "state.json moved"
    assert_file_absent "$dir/tasks.md" "tasks.md untouched"
    assert_file_absent "$PROJ/.agents/workflow/state.json" "state.json removed from workflow dir"
}

t_slug_required() {
    write_state "T1:done"
    run_script workflow-archive.sh
    assert_eq 1 "$CODE" "no slug rejected"
    assert_contains "$ERR" "使い方" "usage message"
    assert_file_exists "$PROJ/.agents/workflow/state.json" "nothing moved"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

t_slug_with_path_chars() {
    write_state "T1:done"
    local slug
    for slug in "a/b" 'a\b' "a..b" ".."; do
        run_script workflow-archive.sh "$slug"
        assert_eq 1 "$CODE" "slug '$slug' rejected"
        assert_file_exists "$PROJ/.agents/workflow/state.json" "nothing moved for '$slug'"
        assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created for '$slug'"
    done
}

t_no_targets() {
    mkdir -p "$PROJ/.agents/workflow"
    rm -rf "$PROJ/.agents/workflow/runs"
    run_script workflow-archive.sh myslug
    assert_eq 1 "$CODE" "no targets rejected"
    assert_contains "$ERR" "移動対象がありません" "message"
    assert_file_absent "$PROJ/.agents/workflow/archive" "no archive dir created"
}

echo "test-workflow-archive.sh"
test_case "全対象の移動と Archived: の出力" t_all_targets
test_case "一部の対象だけ移動" t_partial_targets
test_case "スラッグなしは exit 1" t_slug_required
test_case "パス区切り・.. を含むスラッグは exit 1" t_slug_with_path_chars
test_case "移動対象なしは exit 1" t_no_targets
summary
