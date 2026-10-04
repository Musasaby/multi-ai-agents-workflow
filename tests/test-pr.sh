#!/bin/bash
# #15: dispatch-prompt-gen --pr(PR作成プロンプトの機械生成, POSIX版)
source "$(dirname "$0")/lib.sh"

# main に1コミット(T2)、develop/feature に1コミット(T1)を作り、state.json に記録する
setup_branch() {
    (
        cd "$PROJ"
        printf 'a\n' > a.txt; git add a.txt; git commit -q -m "feat: T2"
        git checkout -q -b develop/feature
        printf 'b\n' > b.txt; git add b.txt; git commit -q -m "feat: T1"
    )
    MAIN_HASH="$(cd "$PROJ" && git rev-parse --short main)"
    BRANCH_HASH="$(cd "$PROJ" && git rev-parse --short HEAD)"
    write_tasks <<'EOF'
## T1: ブランチ上のタスク
- **依存**: なし

## T2: マージ済みのタスク
- **依存**: なし

## T3: 未着手のタスク
- **依存**: なし
EOF
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$BRANCH_HASH" "$MAIN_HASH" <<'PY'
import json, sys
path, h1, h2 = sys.argv[1:4]
state = {'source': 'test', 'branch': 'develop/feature', 'updated_at': 'x', 'tasks': [
    {'id': 'T1', 'title': 'ブランチ上のタスク', 'status': 'done', 'retries': 0, 'commit': h1},
    {'id': 'T2', 'title': 'マージ済みのタスク', 'status': 'done', 'retries': 0, 'commit': h2},
    {'id': 'T3', 'title': '未着手のタスク', 'status': 'pending', 'retries': 0, 'commit': None},
]}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(state, f, ensure_ascii=False)
PY
}

t_pr_generates() {
    setup_branch
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "RunId: pr-1" "run id"
    local prompt
    prompt="$(cat "$PROJ/.agents/workflow/runs/pr-1-1/prompt.md")"
    assert_contains "$prompt" "T1: ブランチ上のタスク" "branch task listed"
    assert_not_contains "$prompt" "T2:" "merged task excluded"
    assert_not_contains "$prompt" "T3:" "pending task excluded"
    assert_contains "$prompt" "develop/feature" "branch name"
    assert_contains "$prompt" "--base main" "base branch"
    assert_contains "$prompt" "日本語" "japanese title/body instruction"
    assert_contains "$prompt" "git push -u" "push instruction"
    assert_not_contains "$prompt" "{" "all placeholders replaced"
}

t_pr_increments() {
    setup_branch
    run_script dispatch-prompt-gen.sh --pr
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 0 "$CODE" "exit code"
    assert_contains "$OUT" "RunId: pr-2" "second run id"
    assert_file_exists "$PROJ/.agents/workflow/runs/pr-2-1/prompt.md" "second prompt"
}

t_pr_on_main_rejected() {
    setup_branch
    (cd "$PROJ" && git checkout -q main)
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 1 "$CODE" "exit code"
}

t_pr_no_tasks_rejected() {
    setup_branch
    (cd "$PROJ" && git checkout -q -b develop/empty main)
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 1 "$CODE" "exit code"
}

echo "test-pr.sh"
test_case "pr: プロンプト生成" t_pr_generates
test_case "pr: 連番" t_pr_increments
test_case "pr: main上はexit 1" t_pr_on_main_rejected
test_case "pr: 対象タスクなしはexit 1" t_pr_no_tasks_rejected
summary
