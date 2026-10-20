#!/bin/bash
# text-refine(推敲の依頼文の生成, POSIX版)
source "$(dirname "$0")/lib.sh"
unset YOMIYASU_STATE_DIR

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

# yomiyasu の記録を書く: write_record <run> <created_at> <final_file> <findings(JSON配列)> <meaning_risks(JSON配列)>
write_record() {
    python3 - "$(py_path "$PROJ/.yomiyasu/runs/$1")" "$2" "$(py_path "$3")" "$4" "$5" <<'PY'
import hashlib, json, os, sys
d, created, final, findings, risks = sys.argv[1:6]
os.makedirs(d, exist_ok=True)
with open(final, 'rb') as f:
    h = hashlib.sha256(f.read()).hexdigest()
run = os.path.basename(d)
rec = {
    'format': 'yomiyasu-check-record', 'run_id': run, 'attempt': 1, 'created_at': created,
    'inputs': {'final': {'sha256': h}},
    'checks': [
        {'name': 'lint', 'status': 'ran', 'report': 'runs/' + run + '/attempt-1.lint.json'},
        {'name': 'diff', 'status': 'ran', 'report': 'runs/' + run + '/attempt-1.diff.json'},
    ],
}
def w(name, obj):
    with open(os.path.join(d, name), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(obj, f, ensure_ascii=False)
w('attempt-1.json', rec)
w('attempt-1.lint.json', {'findings': json.loads(findings)})
w('attempt-1.diff.json', {'meaning_risks': json.loads(risks)})
PY
}

# --check 用の入力と推敲済みファイルを置く
setup_check() {
    new_home
    set_refine yomiyasu
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    echo "元" > "$PROJ/.agents/workflow/runs/refine/pr_body.md"
    printf '推敲済みの本文\n2行目\n' > "$PROJ/.agents/workflow/runs/refine/pr_body.refined.md"
    REFINED=".agents/workflow/runs/refine/pr_body.refined.md"
    INPUTF=".agents/workflow/runs/refine/pr_body.md"
}

LINT1='[{"rule":"excess_list","line":1,"snippet":"- 項目"}]'
RISK1='[{"kind":"protected","subkind":"inline_code","new_line":4,"new":"`code`"}]'

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
    echo "古い判断" > "$PROJ/.agents/workflow/runs/refine/pr_body.decisions.md"
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
    assert_file_absent "$PROJ/.agents/workflow/runs/refine/pr_body.decisions.md" "前の判断を消す"
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

t_check_skip() {
    new_home
    set_refine null
    HOME="$TEST_HOME" run_script text-refine.sh pr_body x.md --check
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Refine: off" "推敲しない"
    assert_contains "$OUT" "Next: continue" "続行"
    set_refine other
    HOME="$TEST_HOME" run_script text-refine.sh pr_body x.md --check
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Check: skipped" "確かめない"
    assert_contains "$OUT" "Next: continue" "続行"
    cleanup_home
}

t_check_no_record() {
    setup_check
    rm "$PROJ/$REFINED"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 3 "$CODE" "exit 3"
    assert_contains "$OUT" "Unchecked: output not found" "推敲済みが無い"
    printf '推敲済みの本文\n2行目\n' > "$PROJ/$REFINED"
    printf '別の内容\n' > "$PROJ/other.md"
    write_record r1 2026-01-01T00:00:00Z "$PROJ/other.md" '[]' '[]'
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 3 "$CODE" "exit 3"
    assert_contains "$OUT" "Unchecked: no record for sha256:" "ハッシュが合わない"
    assert_contains "$OUT" "Next: escalate reason=refine-unchecked" "エスカレーション"
    cleanup_home
}

t_check_undecided() {
    setup_check
    write_record r1 2026-01-01T00:00:00Z "$PROJ/$REFINED" "$LINT1" "$RISK1"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 2 "$CODE" "exit 2: $ERR"
    assert_contains "$OUT" "Candidates: 2" "候補数"
    assert_contains "$OUT" "Candidate: L1 excess_list " "lint の候補"
    assert_contains "$OUT" "Candidate: L4 meaning_risk:inline_code " "意味の候補"
    assert_contains "$OUT" "Undecided: L1 excess_list" "未判断"
    assert_contains "$OUT" "Next: decide-candidates" "判断を求める"
    echo "L1 excess_list: 残す" > "$PROJ/.agents/workflow/runs/refine/pr_body.decisions.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 2 "$CODE" "exit 2: $ERR"
    assert_not_contains "$OUT" "Undecided: L1 excess_list" "判断済みは出さない"
    assert_contains "$OUT" "Undecided: L4 meaning_risk:inline_code" "残りの未判断"
    cleanup_home
}

t_check_decided() {
    setup_check
    write_record r1 2026-01-01T00:00:00Z "$PROJ/$REFINED" "$LINT1" "$RISK1"
    printf 'L1 excess_list\nL4 meaning_risk:inline_code\n' > "$PROJ/.agents/workflow/runs/refine/pr_body.decisions.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_contains "$OUT" "Next: continue" "続行"
    assert_contains "$OUT" "Text:
推敲済みの本文
2行目" "本文を出す"
    cleanup_home
}

t_check_latest_record() {
    setup_check
    write_record old 2026-01-01T00:00:00Z "$PROJ/$REFINED" "$LINT1" '[]'
    write_record new 2026-02-01T00:00:00Z "$PROJ/$REFINED" '[]' '[]'
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_contains "$OUT" "Record: runs/new/attempt-1.json" "新しい記録"
    assert_contains "$OUT" "Candidates: 0" "候補なし"
    assert_contains "$OUT" "Next: continue" "続行"
    cleanup_home
}

echo "test-text-refine.sh"
test_case "text-refine: skill が null なら Refine: off と Next: continue" t_off_when_null
test_case "text-refine: 未設定ならエージェントを問わず導入を見つけて知らせる" t_detect_installed
test_case "text-refine: 有効なら依頼文と出力パスを出す" t_enabled_request
test_case "text-refine: targets に無い場面は推敲しない" t_target_not_listed
test_case "text-refine: 有効で入力が無ければ exit 1" t_missing_input
test_case "text-refine: チェックは推敲しないときと yomiyasu 以外のとき確かめずに続ける" t_check_skip
test_case "text-refine: チェックは記録が無いか最終稿のハッシュが合わなければ止める" t_check_no_record
test_case "text-refine: チェックは候補の判断が無ければ判断を求める" t_check_undecided
test_case "text-refine: チェックは全候補の判断があれば本文を出して続ける" t_check_decided
test_case "text-refine: チェックは同じ最終稿の最新の記録を使う" t_check_latest_record
summary
