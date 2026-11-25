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

# config.json の text_refine.mode を書き換える: set_refine_mode <mode|null>
set_refine_mode() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['text_refine']['mode'] = None if mode == 'null' else mode
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

# yomiyasu_check.py のスタブを置く: --state-dir のディレクトリに引数と標準入力を書く
write_yomiyasu_check_stub() {
    mkdir -p "$TEST_HOME/.agents/skills/yomiyasu/scripts"
    cat > "$TEST_HOME/.agents/skills/yomiyasu/scripts/yomiyasu_check.py" <<'PY'
import os, sys
args = sys.argv[1:]
if '--state-dir' in args:
    i = args.index('--state-dir')
    state = args[i + 1]
    before = args[:i]
else:
    state = ''
    before = args
os.makedirs(state, exist_ok=True)
with open(os.path.join(state, 'stub-argv.txt'), 'w', encoding='utf-8', newline='\n') as f:
    f.write(' '.join(before))
with open(os.path.join(state, 'stub-stdin.bin'), 'wb') as f:
    f.write(sys.stdin.buffer.read())
print('stub-ok')
sys.exit(0)
PY
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
    assert_contains "$OUT" ".agents/workflow/scripts/text-refine.sh pr_body .agents/workflow/runs/refine/pr_body.md --yomiyasu-check" "検査のコマンド"
    assert_not_contains "$OUT" "yomiyasu_check.py" "検査の python を直接呼ばない"
    assert_contains "$OUT" "Next: refine" "次の操作"
    assert_file_absent "$PROJ/.agents/workflow/runs/refine/pr_body.refined.md" "前の出力を消す"
    assert_file_absent "$PROJ/.agents/workflow/runs/refine/pr_body.decisions.md" "前の判断を消す"
    cleanup_home
}

t_request_other_skill() {
    new_home
    set_refine other
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    echo "本文" > "$PROJ/.agents/workflow/runs/refine/pr_body.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body .agents/workflow/runs/refine/pr_body.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Request:" "依頼文"
    assert_not_contains "$OUT" "--yomiyasu-check" "検査のコマンドを入れない"
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
    assert_not_contains "$OUT" "Hint:" "推敲済みが無いときはヒントを出さない"
    printf '推敲済みの本文\n2行目\n' > "$PROJ/$REFINED"
    printf '別の内容\n' > "$PROJ/other.md"
    write_record r1 2026-01-01T00:00:00Z "$PROJ/other.md" '[]' '[]'
    HOME="$TEST_HOME" run_script text-refine.sh pr_body "$INPUTF" --check
    assert_eq 3 "$CODE" "exit 3"
    assert_contains "$OUT" "Unchecked: no record for sha256:" "ハッシュが合わない"
    assert_contains "$OUT" "Next: escalate reason=refine-unchecked" "エスカレーション"
    local next_line="" line found=0
    while IFS= read -r line; do
        if [ "$found" = 1 ]; then
            next_line="$line"
            found=0
        fi
        case "$line" in
            "Unchecked: no record for sha256:"*) found=1 ;;
        esac
    done <<< "$OUT"
    assert_eq 1 "$(case "$next_line" in "Hint: run .agents/workflow/scripts/text-refine.sh "*) echo 1 ;; *) echo 0 ;; esac)" "Hint は Unchecked の次"
    assert_contains "$next_line" "--yomiyasu-check" "Hint のコマンド"
    assert_eq "Next: escalate reason=refine-unchecked" "${OUT##*$'\n'}" "最後の行"
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

t_tasks_request() {
    new_home
    set_refine yomiyasu '["tasks"]'
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    echo "# タスク" > "$PROJ/.agents/workflow/runs/refine/tasks.md"
    HOME="$TEST_HOME" run_script text-refine.sh tasks .agents/workflow/runs/refine/tasks.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "タスク定義です" "場面"
    assert_contains "$OUT" "グループの区切り行" "変えない物"
    assert_contains "$OUT" "Next: refine" "次の操作"
    cleanup_home
}

t_tasks_check_changed() {
    new_home
    set_refine other '["tasks"]'
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    printf '# タスク

## T1: a

- **依存**: なし
' > "$PROJ/.agents/workflow/runs/refine/tasks.md"
    printf '# タスク

## T1: a

- **依存**: T2
' > "$PROJ/.agents/workflow/runs/refine/tasks.refined.md"
    HOME="$TEST_HOME" run_script text-refine.sh tasks .agents/workflow/runs/refine/tasks.md --check
    assert_eq 4 "$CODE" "exit 4: $ERR"
    assert_contains "$OUT" "Changed: L5 - **依存**: なし" "推敲前"
    assert_contains "$OUT" "Refined: L5 - **依存**: T2" "推敲後"
    assert_contains "$OUT" "Next: escalate reason=refine-structure-changed" "エスカレーション"
    cleanup_home
}

t_tasks_check_same() {
    new_home
    set_refine yomiyasu '["tasks"]'
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    printf '# タスク

- R1: 元の本文

## T1: a

- **目的**: 元の目的
- **依存**: なし
' > "$PROJ/.agents/workflow/runs/refine/tasks.md"
    printf '# タスク

- R1: 直した本文

## T1: a

- **目的**: 直した目的
- **依存**: なし
' > "$PROJ/.agents/workflow/runs/refine/tasks.refined.md"
    write_record r1 2026-01-01T00:00:00Z "$PROJ/.agents/workflow/runs/refine/tasks.refined.md" '[]' '[]'
    HOME="$TEST_HOME" run_script text-refine.sh tasks .agents/workflow/runs/refine/tasks.md --check
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_contains "$OUT" "Structure: same" "構造は同じ"
    assert_contains "$OUT" "Candidates: 0" "候補なし"
    assert_contains "$OUT" "Next: continue" "続行"
    assert_not_contains "$OUT" "Text:" "本文を出さない"
    cleanup_home
}

t_dispatch_skip_request() {
    new_home
    set_refine yomiyasu
    set_refine_mode dispatch
    HOME="$TEST_HOME" run_script text-refine.sh commit x.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Refine: dispatch" "dispatch"
    assert_not_contains "$OUT" "Request:" "依頼文を出さない"
    assert_eq "Next: continue" "${OUT##*$'\n'}" "最後の行"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body x.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Refine: dispatch" "dispatch"
    assert_not_contains "$OUT" "Request:" "依頼文を出さない"
    assert_eq "Next: continue" "${OUT##*$'\n'}" "最後の行"
    cleanup_home
}

t_dispatch_request() {
    new_home
    set_refine yomiyasu
    set_refine_mode dispatch
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    echo "本文" > "$PROJ/.agents/workflow/runs/refine/pr_body.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body .agents/workflow/runs/refine/pr_body.md --request
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Request:" "依頼文を出す"
    assert_eq "Next: refine" "${OUT##*$'\n'}" "最後の行"
    cleanup_home
}

t_dispatch_tasks_request() {
    new_home
    set_refine yomiyasu
    set_refine_mode dispatch
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    echo "# タスク" > "$PROJ/.agents/workflow/runs/refine/tasks.md"
    HOME="$TEST_HOME" run_script text-refine.sh tasks .agents/workflow/runs/refine/tasks.md
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "Next: refine" "${OUT##*$'\n'}" "最後の行"
    cleanup_home
}

t_yomiyasu_check_pipes() {
    new_home
    set_refine yomiyasu
    write_skill_md "$TEST_HOME/.agents/skills/yomiyasu/SKILL.md" yomiyasu
    write_yomiyasu_check_stub
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    printf '本文\n' > "$PROJ/.agents/workflow/runs/refine/pr_body.md"
    printf '推敲済み' > "$PROJ/.agents/workflow/runs/refine/pr_body.refined.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body .agents/workflow/runs/refine/pr_body.md --yomiyasu-check
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "stub-ok" "検査の出力"
    assert_eq "run --stdin" "$(cat "$PROJ/.yomiyasu/stub-argv.txt")" "検査の引数"
    local expected
    expected="$(mktemp)"
    printf '<<<yomiyasu:original>>>\n本文\n<<<yomiyasu:final>>>\n推敲済み' > "$expected"
    assert_eq 0 "$(cmp -s "$PROJ/.yomiyasu/stub-stdin.bin" "$expected" && echo 0 || echo 1)" "標準入力のバイト列"
    rm -f "$expected"
    cleanup_home
}

t_yomiyasu_check_missing_final() {
    new_home
    set_refine yomiyasu
    write_skill_md "$TEST_HOME/.agents/skills/yomiyasu/SKILL.md" yomiyasu
    write_yomiyasu_check_stub
    mkdir -p "$PROJ/.agents/workflow/runs/refine"
    printf '本文\n' > "$PROJ/.agents/workflow/runs/refine/pr_body.md"
    HOME="$TEST_HOME" run_script text-refine.sh pr_body .agents/workflow/runs/refine/pr_body.md --yomiyasu-check
    assert_eq 1 "$CODE" "exit 1"
    assert_contains "$ERR" "not found: .agents/workflow/runs/refine/pr_body.refined.md" "推敲後が無い"
    cleanup_home
}

echo "test-text-refine.sh"
test_case "text-refine: skill が null なら Refine: off と Next: continue" t_off_when_null
test_case "text-refine: 未設定ならエージェントを問わず導入を見つけて知らせる" t_detect_installed
test_case "text-refine: 有効なら依頼文と出力パスを出す" t_enabled_request
test_case "text-refine: yomiyasu 以外の skill の依頼文には検査のコマンドを入れない" t_request_other_skill
test_case "text-refine: targets に無い場面は推敲しない" t_target_not_listed
test_case "text-refine: 有効で入力が無ければ exit 1" t_missing_input
test_case "text-refine: チェックは推敲しないときと yomiyasu 以外のとき確かめずに続ける" t_check_skip
test_case "text-refine: チェックは記録が無いか最終稿のハッシュが合わなければ止める" t_check_no_record
test_case "text-refine: チェックは候補の判断が無ければ判断を求める" t_check_undecided
test_case "text-refine: チェックは全候補の判断があれば本文を出して続ける" t_check_decided
test_case "text-refine: チェックは同じ最終稿の最新の記録を使う" t_check_latest_record
test_case "text-refine: tasks の場面は機械パースする行を変えないよう依頼する" t_tasks_request
test_case "text-refine: tasks のチェックは機械パースする行が変わったら止める" t_tasks_check_changed
test_case "text-refine: tasks のチェックは機械パースする行が同じなら本文を出さずに続ける" t_tasks_check_same
test_case "text-refine: dispatch では --request が無ければ依頼文を出さない" t_dispatch_skip_request
test_case "text-refine: dispatch でも --request なら依頼文を出す" t_dispatch_request
test_case "text-refine: dispatch でも tasks は依頼文を出す" t_dispatch_tasks_request
test_case "text-refine: --yomiyasu-check は原文と推敲後を区切りの行で標準入力から渡す" t_yomiyasu_check_pipes
test_case "text-refine: --yomiyasu-check は推敲後のファイルが無いと exit 1" t_yomiyasu_check_missing_final
summary
