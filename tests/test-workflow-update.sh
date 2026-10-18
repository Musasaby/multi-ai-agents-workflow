#!/bin/bash
# #61: workflow-update(upstream の更新取り込み, POSIX版)
source "$(dirname "$0")/lib.sh"

UPSTREAM_DIR=""

# 利用先に upstream 用の別リポジトリを作り、そこから .agents/skills を subtree add する
setup_project_with_upstream() {
    UPSTREAM_DIR="$PROJ/.agents/upstream"
    mkdir -p "$UPSTREAM_DIR"
    cp -r "$REPO_ROOT/_templates" "$UPSTREAM_DIR/_templates"
    git -C "$UPSTREAM_DIR" init -q -b main
    assert_own_repo "$UPSTREAM_DIR"
    (
        cd "$UPSTREAM_DIR" || exit 1
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        git add -A
        git commit -q -m "upstream init"
    ) || exit 1
    (
        cd "$PROJ" || exit 1
        printf '.agents/upstream/\n.agents/workflow/\n' > .gitignore
        git add .gitignore
        git commit -q -m "gitignore"
        git subtree add -q --prefix=.agents/skills .agents/upstream main --squash
    ) || exit 1
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['upstream'] = {'url': '.agents/upstream', 'branch': 'main'}
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# upstream で <file> の内容を <content> にしてコミットする
upstream_commit() {
    (
        cd "$UPSTREAM_DIR" || exit 1
        mkdir -p "$(dirname "$1")"
        printf '%s\n' "$2" > "$1"
        git add -A
        git commit -q -m "upstream change"
    ) || exit 1
}

run_update() {
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$PROJ" && bash .agents/skills/_templates/workflow/scripts/workflow-update.sh "$@") > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

t_update() {
    setup_project_with_upstream
    upstream_commit "_templates/new.txt" "new"
    run_update
    if [ "$CODE" -eq 0 ] || [ "$CODE" -eq 3 ]; then _record ok; else _record ng "exit 0 or 3 (got $CODE): $OUT $ERR"; fi
    assert_file_exists "$PROJ/.agents/skills/_templates/new.txt" "new.txt pulled"
    assert_contains "$OUT" "Upstream: .agents/upstream main" "Upstream line"
}

t_dirty() {
    setup_project_with_upstream
    printf 'x\n' > "$PROJ/untracked.txt"
    run_update
    assert_eq 20 "$CODE" "exit 20"
    assert_eq "Next: escalate reason=dirty-tree" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
}

t_conflict() {
    setup_project_with_upstream
    (
        cd "$PROJ" || exit 1
        { printf 'project side\n'; tail -n +2 .agents/skills/_templates/AGENTS.md; } > .agents/skills/_templates/AGENTS.md.new
        mv .agents/skills/_templates/AGENTS.md.new .agents/skills/_templates/AGENTS.md
        git add -A
        git commit -q -m "project change"
    ) || exit 1
    upstream_commit "_templates/AGENTS.md" "upstream side
$(tail -n +2 "$UPSTREAM_DIR/_templates/AGENTS.md")"
    run_update
    assert_eq 2 "$CODE" "exit 2: $OUT $ERR"
    assert_contains "$OUT" "CONFLICT .agents/skills/_templates/AGENTS.md" "CONFLICT line"
    assert_eq "Next: escalate reason=conflict" "$(printf '%s\n' "$OUT" | tail -n 1)" "last line"
}

echo "test-workflow-update.sh"
test_case "update: upstream の更新を取り込む" t_update
test_case "update: 作業ツリーが汚れていれば exit 20" t_dirty
test_case "update: コンフリクトは CONFLICT 行と exit 2" t_conflict
summary
