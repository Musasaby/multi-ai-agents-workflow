#!/bin/bash
# #61: workflow-update(npx skills 導入の確認と配置済みスクリプトとの差分確認, POSIX版)
source "$(dirname "$0")/lib.sh"

# 利用先にテンプレートを .agents/skills/ としてコピーし、skills-lock.json を置く
setup_project_npx() {
    mkdir -p "$PROJ/.agents/skills/agents-md-setup"
    cp -r "$REPO_ROOT/agents-md-setup/templates" "$PROJ/.agents/skills/agents-md-setup/templates"
    cp "$REPO_ROOT/agents-md-setup/templates/workflow/README.md" "$PROJ/.agents/workflow/README.md"
    printf '{"version": 1, "skills": {}}\n' > "$PROJ/skills-lock.json"
}

run_update() {
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$PROJ" && bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh "$@") > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

t_no_lock() {
    setup_project_npx
    rm -f "$PROJ/skills-lock.json"
    run_update
    assert_eq 2 "$CODE" "exit 2: $OUT $ERR"
    assert_eq "Next: escalate reason=not-npx" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
    assert_contains "$ERR" "skills-lock.json" "stderr"
    assert_contains "$ERR" "workflow-update/references/migrations.md" "stderr points to migrations"
}

t_no_diff() {
    setup_project_npx
    run_update
    assert_eq 0 "$CODE" "exit 0: $OUT $ERR"
    assert_eq "Next: continue" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
}

t_diff() {
    setup_project_npx
    printf '#!/bin/bash\necho old\n' > "$PROJ/.agents/workflow/scripts/dispatch-run.sh"
    run_update
    assert_eq 3 "$CODE" "exit 3: $OUT $ERR"
    assert_contains "$OUT" "differs  scripts/dispatch-run.sh" "differs line"
    assert_eq "Next: confirm" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
}

t_sync_failed() {
    setup_project_npx
    printf 'exit 1\n' > "$PROJ/.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh"
    run_update
    assert_eq 22 "$CODE" "exit 22: $OUT $ERR"
    assert_eq "Next: escalate reason=sync-failed" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
    assert_contains "$ERR" "workflow-sync-scripts.sh failed" "stderr"
}

echo "test-workflow-update.sh"
test_case "update: skills-lock.json が無ければ exit 2" t_no_lock
test_case "update: 差分が無ければ exit 0" t_no_diff
test_case "update: 配置済みスクリプトに差分があれば exit 3" t_diff
test_case "update: 差分の確認に失敗したら exit 22" t_sync_failed
summary
