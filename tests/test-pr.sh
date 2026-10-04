#!/bin/bash
# #15: dispatch-prompt-gen --pr(PR作成プロンプトの機械生成, POSIX版)
source "$(dirname "$0")/lib.sh"

# origin(bare)を用意し、次の状態を作って state.json に記録する:
#   T2: main のコミット(origin/main にもある)
#   T4: 別の PR で origin/main にマージ済みだが、ローカルの main には未取り込み(ローカル main が古い)
#   T1: develop/feature(origin/main から分岐)上のコミット
#   T3: 未着手
setup_branch() {
    (
        cd "$PROJ"
        git init -q --bare .agents/remote.git
        git remote add origin .agents/remote.git
        printf 'a\n' > a.txt; git add a.txt; git commit -q -m "feat: T2"
        printf 'd\n' > d.txt; git add d.txt; git commit -q -m "feat: T4"
        git push -q origin main
        git reset -q --hard HEAD~1
        git checkout -q -b develop/feature origin/main
        printf 'b\n' > b.txt; git add b.txt; git commit -q -m "feat: T1"
    )
    MAIN_HASH="$(cd "$PROJ" && git rev-parse --short main)"
    T4_HASH="$(cd "$PROJ" && git rev-parse --short origin/main)"
    BRANCH_HASH="$(cd "$PROJ" && git rev-parse --short HEAD)"
    write_tasks <<'EOF'
## T1: ブランチ上のタスク
- **依存**: なし

## T2: マージ済みのタスク
- **依存**: なし

## T3: 未着手のタスク
- **依存**: なし

## T4: 別PRでマージ済みのタスク
- **依存**: なし
EOF
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$BRANCH_HASH" "$MAIN_HASH" "$T4_HASH" <<'PY'
import json, sys
path, h1, h2, h4 = sys.argv[1:5]
state = {'source': 'test', 'branch': 'develop/feature', 'updated_at': 'x', 'tasks': [
    {'id': 'T1', 'title': 'ブランチ上のタスク', 'status': 'done', 'retries': 0, 'commit': h1},
    {'id': 'T2', 'title': 'マージ済みのタスク', 'status': 'done', 'retries': 0, 'commit': h2},
    {'id': 'T3', 'title': '未着手のタスク', 'status': 'pending', 'retries': 0, 'commit': None},
    {'id': 'T4', 'title': '別PRでマージ済みのタスク', 'status': 'done', 'retries': 0, 'commit': h4},
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
    assert_not_contains "$prompt" "T4:" "task merged into origin/main excluded even if local main is stale"
    assert_contains "$prompt" "git log origin/main..HEAD" "prompt compares with origin/main"
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

t_pr_no_origin_rejected() {
    setup_branch
    (cd "$PROJ" && git remote remove origin)
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 1 "$CODE" "no origin -> exit 1"
}

echo "test-pr.sh"
test_case "pr: プロンプト生成" t_pr_generates
test_case "pr: 連番" t_pr_increments
test_case "pr: main上はexit 1" t_pr_on_main_rejected
test_case "pr: 対象タスクなしはexit 1" t_pr_no_tasks_rejected
test_case "pr: origin が無ければexit 1" t_pr_no_origin_rejected
summary
