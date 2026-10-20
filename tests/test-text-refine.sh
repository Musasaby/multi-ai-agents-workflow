#!/bin/bash
# text-refine(推敲の依頼文の生成, POSIX版)
source "$(dirname "$0")/lib.sh"

# テスト用 HOME を作る(実際のホームの導入状況に左右されないようにする)
new_home() {
    TEST_HOME="$(mktemp -d)"
}

cleanup_home() {
    [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
    TEST_HOME=""
}

# config.json の text_refine を書き換える: set_refine <skill|null> [targets(JSON配列)]
set_refine() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" "${2:-}" <<'PY'
import json, sys
path, skill, targets = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['text_refine']['skill'] = None if skill == 'null' else skill
if targets:
    cfg['text_refine']['targets'] = json.loads(targets)
with open(path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

write_skill_md() { # path name
    mkdir -p "$(dirname "$1")"
    printf -- '---\nname: %s\n---\n' "$2" > "$1"
}

t_off_when_null() {
    new_home
    set_refine null
    HOME="$TEST_HOME" run_script text-refine.sh pr_body x.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Refine: off" "推敲しない"
    assert_contains "$OUT" "Next: continue" "続行"
    assert_not_contains "$OUT" "Hint:" "導入が無ければ Hint を出さない"
    cleanup_home
}

t_detect_installed() {
    new_home
    set_refine null
    write_skill_md "$PROJ/.claude/skills/yomiyasu/SKILL.md" yomiyasu
    write_skill_md "$TEST_HOME/.config/opencode/skills/yomiyasu/SKILL.md" yomiyasu
    write_skill_md "$TEST_HOME/.gemini/skills/yomiyasu/SKILL.md" yomiyasu
    write_skill_md "$PROJ/.cursor/skills/yomiyasu/SKILL.md" other
    mkdir -p "$TEST_HOME/.claude/plugins"
    printf '{"version":2,"plugins":{"yomiyasu@yomiyasu":[]}}\n' > "$TEST_HOME/.claude/plugins/installed_plugins.json"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body x.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Found: .claude/skills/yomiyasu/SKILL.md" "プロジェクトの .claude"
    assert_contains "$OUT" "Found: ~/.config/opencode/skills/yomiyasu/SKILL.md" "ホームの opencode"
    assert_contains "$OUT" "Found: ~/.gemini/skills/yomiyasu/SKILL.md" "ホームの gemini"
    assert_contains "$OUT" "Found: ~/.claude/plugins/installed_plugins.json (yomiyasu@yomiyasu)" "プラグイン"
    assert_contains "$OUT" "Hint: yomiyasu is installed but text_refine.skill is not set" "Hint"
    assert_not_contains "$OUT" ".cursor/" "別名の skill は対象外"
    cleanup_home
}

t_enabled_request() {
    new_home
    set_refine "yomiyasu:yomiyasu"
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    echo "本文" > "$PROJ/.agents/workflow/runs/refine/pr_body.md"
    echo "古い出力" > "$PROJ/.agents/workflow/runs/refine/pr_body.refined.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body .agents/workflow/runs/refine/pr_body.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Refine: yomiyasu:yomiyasu" "skill 名"
    assert_contains "$OUT" "Output: .agents/workflow/runs/refine/pr_body.refined.md" "出力パス"
    assert_contains "$OUT" "を yomiyasu:yomiyasu で推敲し、本文だけを" "依頼文"
    assert_contains "$OUT" "PR説明です" "場面"
    assert_contains "$OUT" "読者は分野は違うが技術に詳しい人です" "読者"
    assert_contains "$OUT" "要件一覧とテスト計画の項目" "変えない物"
    assert_contains "$OUT" "Next: refine" "次の操作"
    assert_file_absent "$PROJ/.agents/workflow/runs/refine/pr_body.refined.md" "前の出力を消す"
    cleanup_home
}

t_target_not_listed() {
    new_home
    set_refine yomiyasu '["pr_body"]'
    HOME="$TEST_HOME" run_script text-refine.sh commit x.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Refine: off" "推敲しない"
    assert_contains "$OUT" "Next: continue" "続行"
    cleanup_home
}

t_missing_input() {
    new_home
    set_refine yomiyasu
    HOME="$TEST_HOME" run_script text-refine.sh pr_body no-such-input.md
    assert_eq 1 "$CODE" "exit 1"
    assert_contains "$ERR" "not found:" "入力なし"
    cleanup_home
}

echo "test-text-refine.sh"
test_case "text-refine: skill が null なら Refine: off と Next: continue" t_off_when_null
test_case "text-refine: 未設定ならエージェントを問わず導入を見つけて知らせる" t_detect_installed
test_case "text-refine: 有効なら依頼文と出力パスを出す" t_enabled_request
test_case "text-refine: targets に無い場面は推敲しない" t_target_not_listed
test_case "text-refine: 有効で入力が無ければ exit 1" t_missing_input
summary
