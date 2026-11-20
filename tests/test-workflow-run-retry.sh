#!/bin/bash
# workflow-run.sh の collect 後に止まる場合と再 dispatch(POSIX版)
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/workflow-run-lib.sh"

t_commit_format() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    set_review_body 'run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
id="${id#review-}"
echo "## 完了報告"
echo "- Verdict: pass"
echo "- 指摘: 0件(なし)"
echo "- 要約: $id を変える"
echo "- type: bogus"
echo "- fix-notes: なし"
echo "- 理解確認: なし"'
    run_until_not_wait
    local runs="$PROJ/.agents/workflow/runs"
    assert_eq 3 "$CODE" "exit 3: $ERR"
    assert_contains "$OUT" "Stopped: T1 reason=commit-format" "commit-format で止まる"
    assert_eq "Next: escalate reason=commit-format" "$(last_line)" "最後の行"
    assert_eq "in_review" "$(state_get T1 status)" "T1 の状態は in_review のまま"
    assert_file_exists "$runs/T1-1/collected" "collect 済み"
}

t_retry_after_review_fail() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    : > "$PROJ/.agents/review-fail-T1"
    run_until_not_wait
    local runs="$PROJ/.agents/workflow/runs"
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_eq "done" "$(state_get T1 status)" "T1 の状態"
    assert_eq "1" "$(state_get T1 retries)" "T1 の retries"
    assert_file_exists "$runs/T1-1/carry" "前の試行の変更を持ち越す"
    assert_file_exists "$runs/T1-1/superseded" "前の試行を superseded にする"
    assert_eq 2 "$(grep -c '^line$' "$PROJ/T1.txt")" "試行1と試行2の変更が両方ある"
    assert_contains "$(cat "$runs/workflow-run/progress.log")" "Retry: T1 1/2 (review)" "progress.log に Retry"
}

t_retry_after_gate() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['verify_before_commit'] = True
cfg['quality_gate'] = {'steps': [{
    'name': 'check',
    'command': 'test ! -f .agents/gate-fail-once || { rm .agents/gate-fail-once; exit 1; }',
    'blocking': True,
}]}
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
    : > "$PROJ/.agents/gate-fail-once"
    run_until_not_wait
    local runs="$PROJ/.agents/workflow/runs"
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_eq "done" "$(state_get T1 status)" "T1 の状態"
    assert_eq "1" "$(state_get T1 retries)" "T1 の retries"
    assert_file_exists "$runs/T1-2/fix-notes.md" "次の試行の fix-notes.md"
    local notes; notes="$(cat "$runs/T1-2/fix-notes.md")"
    assert_contains "$notes" "品質ゲート FAIL" "原因種別"
    assert_contains "$notes" "FAIL check (blocking)" "品質ゲートの出力"
}

t_retry_limit() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['max_fix_retries'] = 0
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
    : > "$PROJ/.agents/review-fail-T1"
    run_until_not_wait
    local runs="$PROJ/.agents/workflow/runs"
    assert_eq 3 "$CODE" "exit 3: $ERR"
    assert_eq "Next: escalate reason=retry-limit" "$(last_line)" "最後の行"
    assert_eq "in_review" "$(state_get T1 status)" "T1 の状態"
    assert_file_exists "$runs/T1-1/collected" "collect 済み"
}

t_conflict_redo() {
    setup_runner
    write_state "T1:in_progress" "T2:done"
    set_state_branch develop/t
    ( cd "$PROJ" && bash .agents/workflow/scripts/dispatch-worktree.sh create T1 1 > /dev/null )
    local runs="$PROJ/.agents/workflow/runs" wt
    wt="$(sed -n 's/^path //p' "$runs/T1-1/worktree.txt" | head -n 1 | tr -d '\r')"
    printf 'worktree-change\n' > "$wt/T1.txt"
    printf 'main-change\n' > "$PROJ/T1.txt"
    git -C "$PROJ" add T1.txt
    git -C "$PROJ" commit -q -m "main change"
    : > "$runs/T1-1/guard.sha256"
    : > "$runs/T1-1/checked"
    mkdir -p "$runs/review-T1-1"
    : > "$runs/review-T1-1/guard.sha256"
    printf 'pass\nfeat\nT1 を変える\n' > "$runs/review-T1-1/verdict"
    run_script workflow-run.sh --max-wait 1 --interval 1
    assert_contains "$OUT" "Redo: T1-2 (conflict)" "Redo を出す"
    assert_contains "$OUT" "Started: T1-2" "次の試行を起動した"
    assert_file_exists "$runs/T1-2/fix-notes.md" "次の試行の fix-notes.md"
    assert_contains "$(cat "$runs/T1-2/fix-notes.md")" "changes.patch" "changes.patch のパスを案内"
    assert_file_exists "$runs/T1-1/superseded" "前の試行を superseded にする"
    assert_file_absent "$runs/T1-1/carry" "衝突のやり直しでは carry を書かない"

    # 子(デタッチ起動)が終わってから一時ディレクトリを片付ける
    wait_done T1-2
    assert_file_exists "$runs/T1-2/done" "T1-2 の done"
}

echo "test-workflow-run-retry.sh"
test_case "run: type が無効なら commit-format で止まり、in_review のまま残る" t_commit_format
test_case "run: レビュー不合格なら変更を持ち越して再 dispatch する" t_retry_after_review_fail
test_case "run: 品質ゲートが FAIL なら fix-notes.md を機械的に書いて再 dispatch する" t_retry_after_gate
test_case "run: リトライの上限でレビュー不合格なら collect して retry-limit で止まる" t_retry_limit
test_case "run: collect が衝突したら最新の HEAD からやり直す" t_conflict_redo
summary
