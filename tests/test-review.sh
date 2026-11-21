#!/bin/bash
# dispatch-prompt-gen --review(レビュー用プロンプトの機械生成, POSIX版)
source "$(dirname "$0")/lib.sh"

write_review_tasks() {
    write_tasks <<'EOF'
## T1: レビュー対象のタスク
- **依存**: なし
EOF
}

# comprehension_check を有効にする
enable_comprehension_check() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['comprehension_check'] = {'enabled': True, 'questions_per_task': 2}
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# 子が本体の state.json の 1 タスクの欄を書き換えるためのスクリプトを置く
# 使い方(子から): python3 ./setstate.py <state.json> <ID> <status> [<retries>]
write_setstate_py() {
    cat > "$PROJ/setstate.py" <<'PY'
import json, sys
p, tid, status = sys.argv[1:4]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
for e in s['tasks']:
    if e['id'] == tid:
        e['status'] = status
        if len(sys.argv) > 4:
            e['retries'] = int(sys.argv[4])
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f)
PY
}

# 完了報告を echo するスタブの子で review の run を dispatch-run に作らせる
make_review_run() { # $1 = 完了報告の本文, $2 = 子に追加で実行させるコマンド(任意)
    local report="$1" extra="${2:-}"
    {
        printf '#!/bin/bash\n'
        printf "cat <<'REVIEW_REPORT'\n"
        printf '%s\n' "$report"
        printf 'REVIEW_REPORT\n'
        if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    } > "$PROJ/review-child.sh"
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['review'] = {'command_template': 'bash ./review-child.sh "{prompt}"'}
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
    mkdir -p "$PROJ/.agents/workflow/runs/review-T1-1"
    printf 'prompt\n' > "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md"
    run_script dispatch-run.sh review-T1 1
}

t_review_generates() {
    write_review_tasks
    write_report T1 1
    run_script dispatch-prompt-gen.sh --review T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "RunId: review-T1" "run id"
    local prompt
    prompt="$(cat "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md")"
    assert_contains "$prompt" "レビュー対象のタスク" "task title"
    assert_contains "$prompt" ".agents/workflow/runs/T1-1/report.md" "report path"
    assert_contains "$prompt" ".agents/workflow/runs/T1-2/fix-notes.md" "fix notes path"
    assert_contains "$prompt" "質問ファイルは作らない" "comprehension disabled instruction"
}

t_review_worktree() {
    write_review_tasks
    write_report T1 1
    local wt
    wt="$(py_path "$PROJ")/wt"
    mkdir -p "$PROJ/.agents/workflow/runs/review-T1-1"
    {
        printf 'path %s\n' "$wt"
        printf 'branch refs/heads/agents-run/T1-1\n'
        printf 'base HEAD\n'
    } > "$PROJ/.agents/workflow/runs/review-T1-1/worktree.txt"
    run_script dispatch-prompt-gen.sh --review T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    local prompt main_root
    prompt="$(cat "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md")"
    main_root="$(py_path "$PROJ")"
    assert_contains "$prompt" "## worktree でレビューする場合の追加の指示" "worktree section"
    assert_contains "$prompt" "$wt" "worktree path"
    assert_contains "$prompt" "$main_root/.agents/workflow/runs/T1-2/fix-notes.md" "fix notes path"
    assert_contains "$prompt" "$main_root/.agents/workflow/runs/T1-1/report.md" "report path"
    assert_not_contains "$prompt" "{workdir}" "workdir placeholder replaced"
    assert_not_contains "$prompt" "{main_root}" "main_root placeholder replaced"
}

t_review_report_missing() {
    write_review_tasks
    run_script dispatch-prompt-gen.sh --review T1 1
    assert_eq 2 "$CODE" "missing report -> exit 2"
}

t_review_comprehension_enabled() {
    write_review_tasks
    write_report T1 1
    enable_comprehension_check
    run_script dispatch-prompt-gen.sh --review T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    local prompt
    prompt="$(cat "$PROJ/.agents/workflow/runs/review-T1-1/prompt.md")"
    assert_contains "$prompt" ".agents/workflow/comprehension/T1.md" "question file path"
    assert_contains "$prompt" "2 問" "question count"
}

t_check_review_pass() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外'
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Next: commit T1" "next commit"
    assert_contains "$OUT" "Review summary: 問題なし" "review summary"
}

t_check_review_type_valid() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- type: feat\n- fix-notes: なし\n- 理解確認: 対象外'
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Review type: feat" "review type"
    assert_eq "Next: commit T1" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
}

t_check_review_type_invalid() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外'
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "missing type -> exit 0: $ERR"
    assert_contains "$OUT" "Review type: invalid" "missing type -> invalid"
    assert_eq "Next: commit T1" "$(printf '%s\n' "$OUT" | tail -1)" "last line"

    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- type: bogus\n- fix-notes: なし\n- 理解確認: 対象外'
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "bogus type -> exit 0: $ERR"
    assert_contains "$OUT" "Review type: invalid" "bogus type -> invalid"
    assert_eq "Next: commit T1" "$(printf '%s\n' "$OUT" | tail -1)" "last line"
}

t_check_review_fail_with_fix_notes() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: fail\n- 指摘: a.txt の修正\n- 要約: 修正が必要\n- fix-notes: あり\n- 理解確認: 対象外' \
        "mkdir -p .agents/workflow/runs/T1-2 && printf '修正点\n' > .agents/workflow/runs/T1-2/fix-notes.md"
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Next: retry T1" "next retry"
}

t_check_review_fail_without_fix_notes() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: fail\n- 指摘: a.txt の修正\n- 要約: 修正が必要\n- fix-notes: なし\n- 理解確認: 対象外'
    run_script dispatch-check.sh review-T1 1
    assert_eq 5 "$CODE" "missing fix-notes -> exit 5"
    assert_contains "$OUT" "fix-notes not found" "fix-notes not found"
}

t_check_review_invalid_verdict() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: ok\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外'
    run_script dispatch-check.sh review-T1 1
    assert_eq 5 "$CODE" "invalid verdict -> exit 5"
    assert_contains "$OUT" "Verdict must be pass or fail" "invalid verdict message"
}

t_check_review_main_tree_changed() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外' \
        "printf 'changed\n' > a.txt"
    run_script dispatch-check.sh review-T1 1
    assert_eq 8 "$CODE" "main tree changed -> exit 8"
    assert_contains "$OUT" "changed: main worktree: a.txt" "changed main worktree"
    assert_not_contains "$OUT" "(modified after the run ended)" "実行中の変更には付かない"
}

t_check_review_other_task_changed() {
    write_review_tasks
    write_state "T1:in_progress" "T2:pending"
    write_setstate_py
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外' \
        "python3 ./setstate.py .agents/workflow/state.json T2 in_progress"
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "ほかのタスクの欄を変えても tampered にならない: $OUT"
    assert_not_contains "$OUT" "changed" "changed は出ない"
    assert_eq "Next: commit T1" "$(printf '%s\n' "$OUT" | tail -n 1)" "最後の行は Next: commit T1"
}

t_check_review_target_retries_changed() {
    write_review_tasks
    write_state "T1:in_progress" "T2:pending"
    write_setstate_py
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外' \
        "python3 ./setstate.py .agents/workflow/state.json T1 in_progress 5"
    run_script dispatch-check.sh review-T1 1
    assert_eq 8 "$CODE" "対象タスクの retries を変えると exit 8: $OUT"
    assert_contains "$OUT" "changed: .agents/workflow/state.json (T1)" "state.json (T1) の changed"
}

t_check_review_python_no_bytecode() {
    write_review_tasks
    # 子の bash が WSL の bash.exe の環境では、Windows の環境変数は WSLENV に載せないと
    # 子のシェルに渡らない(WSL 以外では無視される)。dispatch-run が export した値を確かめる
    local old_wslenv="${WSLENV:-}"
    export WSLENV="${WSLENV:+$WSLENV:}PYTHONDONTWRITEBYTECODE"
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外' \
        'echo "PYC=$PYTHONDONTWRITEBYTECODE"'
    if [ -n "$old_wslenv" ]; then export WSLENV="$old_wslenv"; else unset WSLENV; fi
    run_script dispatch-check.sh review-T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/review-T1-1/output.log")" "PYC=1" "PYTHONDONTWRITEBYTECODE=1 が子に渡る"
}

t_check_review_main_tree_late() {
    write_review_tasks
    make_review_run $'## 完了報告\n- Verdict: pass\n- 指摘: なし\n- 要約: 問題なし\n- fix-notes: なし\n- 理解確認: 対象外'
    printf 'late\n' > "$PROJ/late.txt"
    python3 -c "import os,time; t=time.time()+60; os.utime(r'$(py_path "$PROJ/late.txt")',(t,t))"
    run_script dispatch-check.sh review-T1 1
    assert_eq 8 "$CODE" "終了後の変更 -> exit 8"
    assert_contains "$OUT" "changed: main worktree: late.txt (modified after the run ended)" "modified after the run ended"
}

echo "test-review.sh"
test_case "review のプロンプトを生成する" t_review_generates
test_case "worktree の run のレビューは絶対パスと追加の節を入れる" t_review_worktree
test_case "report.md が無いと exit 2" t_review_report_missing
test_case "理解確認が有効なら質問ファイルの指示を入れる" t_review_comprehension_enabled
test_case "合格なら commit を出す" t_check_review_pass
test_case "type が決まった値なら Review type に出す" t_check_review_type_valid
test_case "type が無い・決まった値でなければ Review type は invalid" t_check_review_type_invalid
test_case "不合格で fix-notes があれば retry を出す" t_check_review_fail_with_fix_notes
test_case "不合格で fix-notes が無ければ no-report" t_check_review_fail_without_fix_notes
test_case "Verdict が pass/fail 以外なら no-report" t_check_review_invalid_verdict
test_case "レビューの run が作業ツリーを変えたら tampered" t_check_review_main_tree_changed
test_case "レビューの run の子がほかのタスクの欄を変えても tampered にならない" t_check_review_other_task_changed
test_case "レビューの run の子が対象タスクの retries を変えると tampered" t_check_review_target_retries_changed
test_case "レビューの run の子に PYTHONDONTWRITEBYTECODE=1 が渡る" t_check_review_python_no_bytecode
test_case "レビューの run の後に本体を更新したファイルは modified after the run ended" t_check_review_main_tree_late
summary
