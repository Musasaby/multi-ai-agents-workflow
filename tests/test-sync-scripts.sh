#!/bin/bash
# #17: workflow-sync-scripts(テンプレートと配置先の差分検出・反映, POSIX版)
source "$(dirname "$0")/lib.sh"

# 利用先の構成を再現する: テンプレートは .agents/skills/_templates/workflow/ 配下、
# 配置先は .agents/workflow/ 配下(new_project が全スクリプトを配置済み)
setup_user_project() {
    local tpl="$PROJ/.agents/skills/_templates/workflow"
    mkdir -p "$tpl/scripts"
    cp "$TEMPLATE_SCRIPTS"/* "$tpl/scripts/"
    cp "$REPO_ROOT/_templates/workflow/README.md" "$tpl/README.md"
    cp "$REPO_ROOT/_templates/workflow/README.md" "$PROJ/.agents/workflow/README.md"
    # 差分を作る: next-task.sh は未配置、dispatch-run.sh は古い版、README.md は CRLF だけが違う
    rm "$PROJ/.agents/workflow/scripts/next-task.sh"
    printf '#!/bin/bash\necho old\n' > "$PROJ/.agents/workflow/scripts/dispatch-run.sh"
    sed -i 's/$/\r/' "$PROJ/.agents/workflow/README.md"
}

run_sync() {
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$PROJ" && bash .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh "$@") > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

t_list() {
    setup_user_project
    run_sync
    assert_eq 3 "$CODE" "differences -> exit 3: $ERR"
    assert_contains "$OUT" "missing  scripts/next-task.sh" "missing listed"
    assert_contains "$OUT" "differs  scripts/dispatch-run.sh" "differs listed"
    assert_not_contains "$OUT" "README.md" "CRLF-only difference ignored"
    assert_not_contains "$OUT" "state-sync.sh" "identical file not listed"
    assert_file_absent "$PROJ/.agents/workflow/scripts/next-task.sh" "list mode changes nothing"
}

t_in_sync() {
    setup_user_project
    cp "$TEMPLATE_SCRIPTS/next-task.sh" "$TEMPLATE_SCRIPTS/dispatch-run.sh" "$PROJ/.agents/workflow/scripts/"
    run_sync
    assert_eq 0 "$CODE" "in sync -> exit 0: $OUT"
}

t_copy_missing() {
    setup_user_project
    run_sync --copy-missing
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_file_exists "$PROJ/.agents/workflow/scripts/next-task.sh" "missing file copied"
    assert_eq "echo old" "$(sed -n 2p "$PROJ/.agents/workflow/scripts/dispatch-run.sh")" "differing file untouched"
}

t_copy_missing_creates_dir() {
    setup_user_project
    rm -rf "$PROJ/.agents/workflow/scripts"
    run_sync --copy-missing
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_file_exists "$PROJ/.agents/workflow/scripts/state-sync.sh" "scripts dir created"
}

t_overwrite() {
    setup_user_project
    run_sync --overwrite scripts/dispatch-run.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "$(cat "$TEMPLATE_SCRIPTS/dispatch-run.sh")" "$(cat "$PROJ/.agents/workflow/scripts/dispatch-run.sh")" "overwritten"
    assert_file_absent "$PROJ/.agents/workflow/scripts/next-task.sh" "other files untouched"
}

t_overwrite_unknown_rejected() {
    setup_user_project
    run_sync --overwrite scripts/dispatch-run.sh,scripts/nope.sh
    assert_eq 1 "$CODE" "exit code"
    assert_eq "echo old" "$(sed -n 2p "$PROJ/.agents/workflow/scripts/dispatch-run.sh")" "nothing overwritten"
}

t_diff() {
    setup_user_project
    run_sync --diff scripts/dispatch-run.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "echo old" "diff shows old content"
}

t_run_from_dest_rejected() {
    setup_user_project
    local code
    (cd "$PROJ" && bash .agents/workflow/scripts/workflow-sync-scripts.sh) > /dev/null 2>&1
    code=$?
    assert_eq 1 "$code" "running the deployed copy is rejected"
}

echo "test-sync-scripts.sh"
test_case "一覧: missing/differs を表示しexit 3" t_list
test_case "一覧: 一致ならexit 0" t_in_sync
test_case "--copy-missing" t_copy_missing
test_case "--copy-missing: scripts/ 未作成" t_copy_missing_creates_dir
test_case "--overwrite" t_overwrite
test_case "--overwrite: 不明な名前は拒否" t_overwrite_unknown_rejected
test_case "--diff" t_diff
test_case "配置先のコピーからの実行は拒否" t_run_from_dest_rejected
summary
