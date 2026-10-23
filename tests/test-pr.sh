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
    assert_contains "$prompt" 'gh api -X PATCH "repos/{owner}/{repo}/pulls/' "update existing PR via gh api"
    assert_contains "$prompt" "-F body=@.agents/workflow/runs/pr-1-1/pr-body.md" "body file for update"
    assert_not_contains "${prompt//\{owner\}\/\{repo\}/}" "{" "all placeholders replaced except {owner}/{repo}"
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

set_base_branch() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['base_branch'] = sys.argv[2]
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
PY
}

t_pr_base_branch() {
    setup_branch
    (cd "$PROJ" && git push -q origin main:release/v1)
    set_base_branch release/v1
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 0 "$CODE" "exit code: $ERR"
    local prompt
    prompt="$(cat "$PROJ/.agents/workflow/runs/pr-1-1/prompt.md")"
    assert_contains "$prompt" "--base release/v1" "base branch"
    assert_contains "$prompt" "origin/release/v1" "compares with origin/release/v1"
    assert_contains "$prompt" "T1:" "branch task listed"
    assert_contains "$prompt" "T4:" "T4 included because range changed"
}

t_pr_base_branch_on_main_rejected() {
    setup_branch
    set_base_branch release/v1
    (cd "$PROJ" && git checkout -q main)
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 1 "$CODE" "exit code"
}

t_pr_on_base_branch_rejected() {
    setup_branch
    set_base_branch release/v1
    (cd "$PROJ" && git checkout -q -b release/v1 main)
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 1 "$CODE" "exit code"
}

t_task_id_omitted() {
    run_script dispatch-prompt-gen.sh
    assert_eq 1 "$CODE" "exit code"
}

t_pr_no_origin_rejected() {
    setup_branch
    (cd "$PROJ" && git remote remove origin)
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 1 "$CODE" "no origin -> exit 1"
}

t_pr_requirements() {
    setup_branch
    write_tasks <<'EOF'
## 要件
- R1: 要望1
- R2: 要望2

## T1: ブランチ上のタスク
- **要件**: R1
- **依存**: なし

## T2: マージ済みのタスク
- **要件**: R2
- **依存**: なし

## T3: 未着手のタスク
- **要件**: R1
- **依存**: なし

## T4: 別PRでマージ済みのタスク
- **要件**: なし
- **依存**: なし
EOF
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 0 "$CODE" "exit code: $ERR"
    local prompt
    prompt="$(cat "$PROJ/.agents/workflow/runs/pr-1-1/prompt.md")"
    assert_contains "$prompt" "- R1: 要望1(この PR: T1 / 他の PR: T3)" "requirement line"
    assert_not_contains "$prompt" "- R2:" "requirement of merged task excluded"
}

t_pr_no_requirements() {
    setup_branch
    run_script dispatch-prompt-gen.sh --pr
    assert_eq 0 "$CODE" "exit code: $ERR"
    local prompt
    prompt="$(cat "$PROJ/.agents/workflow/runs/pr-1-1/prompt.md")"
    assert_contains "$prompt" "- なし(tasks.md に要件の節が無い、またはこの PR のタスクに対応する要件が無い)" "none text"
    assert_not_contains "$prompt" "{requirement_list}" "placeholder replaced"
}

echo "test-pr.sh"
test_case "pr: プロンプト生成" t_pr_generates
test_case "pr: 連番" t_pr_increments
test_case "pr: main上はexit 1" t_pr_on_main_rejected
test_case "pr: 対象タスクなしはexit 1" t_pr_no_tasks_rejected
test_case "pr: base_branch があればその向きで比較する" t_pr_base_branch
test_case "pr: base_branch が main 以外でも main 上は exit 1" t_pr_base_branch_on_main_rejected
test_case "pr: base_branch の上は exit 1" t_pr_on_base_branch_rejected
test_case "TaskId省略はexit 1" t_task_id_omitted
test_case "pr: origin が無ければexit 1" t_pr_no_origin_rejected
test_case "pr: 要件の対応をプロンプトに載せる" t_pr_requirements
test_case "pr: 要件の節が無ければなしと書く" t_pr_no_requirements
summary
