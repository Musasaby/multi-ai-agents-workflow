#!/bin/bash
# #59: quality-gate(config の quality_gate.steps の実行と判定, POSIX版)。
source "$(dirname "$0")/lib.sh"

# set_steps 'name|command|blocking' ... → config.json の quality_gate.steps を書き換える
set_steps() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$@" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
steps = []
for spec in sys.argv[2:]:
    name, command, blocking = spec.split('|', 2)
    steps.append({'name': name, 'command': command, 'blocking': blocking == 'true'})
c['quality_gate']['steps'] = steps
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

t_pass() {
    set_steps 'a|echo ok|true'
    run_script quality-gate.sh --out-dir out
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Result: PASS" "Result"
    assert_contains "$(cat "$PROJ/out/a.log")" "ok" "a.log"
    assert_eq "Next: continue" "${OUT##*$'\n'}" "last line is the Next: line"
}

t_fail_continues() {
    set_steps 'a|exit 1|true' 'b|echo b|true'
    run_script quality-gate.sh --out-dir out
    assert_eq 2 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "FAIL a" "a failed"
    assert_contains "$OUT" "PASS b" "b still ran"
    assert_eq "Next: escalate reason=quality-gate" "${OUT##*$'\n'}" "last line is the Next: line"
}

t_non_blocking() {
    set_steps 'a|echo ok|true' 'b|exit 1|false'
    run_script quality-gate.sh --out-dir out
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "FAIL b" "b failed"
    assert_contains "$OUT" "Result: PASS" "Result"
}

t_no_steps() {
    run_script quality-gate.sh --out-dir out
    assert_eq 3 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "Result: NO-STEPS" "Result"
    assert_eq "Next: escalate reason=no-steps" "${OUT##*$'\n'}" "last line is the Next: line"
}

t_tail_only() {
    set_steps 'a|seq 1 100; exit 1|true'
    run_script quality-gate.sh --out-dir out
    assert_eq 2 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "100" "last line shown"
    local after="${OUT#*--- a}"
    assert_not_contains $'\n'"$after"$'\n' $'\n1\n' "first line not shown"
    assert_eq 100 "$(wc -l < "$PROJ/out/a.log" | tr -d ' ')" "a.log has 100 lines"
}

t_stdin() {
    set_steps 'a|cat|true' 'b|echo b|true'
    run_script quality-gate.sh --out-dir out
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "PASS a" "a passed"
    assert_contains "$OUT" "PASS b" "b still ran"
}

echo "test-quality-gate.sh"
test_case "gate: blocking がすべて成功すれば PASS" t_pass
test_case "gate: blocking の失敗は FAIL(exit 2)で後続も実行する" t_fail_continues
test_case "gate: non-blocking の失敗は PASS" t_non_blocking
test_case "gate: 実行ステップが0件なら exit 3" t_no_steps
test_case "gate: stdout には失敗ステップの末尾だけを出す" t_tail_only
test_case "gate: ステップが stdin を読んでも後続のステップを実行する" t_stdin
summary
