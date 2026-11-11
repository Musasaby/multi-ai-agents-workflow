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

echo "test-review.sh"
test_case "review のプロンプトを生成する" t_review_generates
test_case "report.md が無いと exit 2" t_review_report_missing
test_case "理解確認が有効なら質問ファイルの指示を入れる" t_review_comprehension_enabled
summary
