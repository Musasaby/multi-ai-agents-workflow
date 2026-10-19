#!/bin/bash
# req-status(要件ごとの状態一覧, POSIX版)
source "$(dirname "$0")/lib.sh"

# commit 付きの state.json を書く: write_state_commit "T1:done:abcdef1234567" "T2:pending" ...
# (lib.sh の write_state は commit を null 固定にするため、python で書く)
write_state_commit() {
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$@" <<'PY'
import json, sys
path = sys.argv[1]
tasks = []
for item in sys.argv[2:]:
    parts = item.split(':')
    tasks.append({'id': parts[0], 'title': parts[0] + ' title', 'status': parts[1], 'retries': 0,
                  'commit': parts[2] if len(parts) > 2 else None})
state = {'source': 'test', 'branch': 'main', 'updated_at': 'x', 'tasks': tasks}
with open(path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(state, f, ensure_ascii=False)
PY
}

t_status_and_summary() {
    write_tasks <<'EOT'
## 要件
- R1: 一つ目
- R2: 二つ目
- R3: 三つ目

## T1: a
- **要件**: R1
- **依存**: なし

## T2: b
- **要件**: R1, R3
- **依存**: T1

## T3: c
- **要件**: R2
- **依存**: なし

## T4: d
- **要件**: なし
- **依存**: なし
EOT
    write_state_commit "T1:done:abcdef1234567" "T2:pending" "T3:done:1234567abcdef" "T4:in_review"
    run_script req-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "Requirement R1 [partial]: T1(done abcdef1), T2(pending) | 一つ目" "R1 行"
    assert_contains "$OUT" "Requirement R2 [done]: T3(done 1234567) | 二つ目" "R2 行"
    assert_contains "$OUT" "Requirement R3 [pending]: T2(pending) | 三つ目" "R3 行"
    assert_contains "$OUT" "Requirement なし: T4(in_review)" "なし行"
    assert_contains "$OUT" "Summary: done=1 partial=1 pending=1" "集計行"
}

t_no_section() {
    write_tasks <<'EOT'
## T1: a
- **依存**: なし
EOT
    write_state "T1:pending"
    run_script req-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "No requirements section" "$OUT" "節が無い旨"
}

t_uncovered() {
    write_tasks <<'EOT'
## 要件
- R1: 一つ目
- R2: 二つ目

## T1: a
- **要件**: R1
- **依存**: なし
EOT
    write_state "T1:pending"
    run_script req-status.sh
    assert_eq 1 "$CODE" "exit 1"
    assert_contains "$ERR" "Uncovered requirement: R2" "未対応の要件"
}

t_missing_task() {
    write_tasks <<'EOT'
## 要件
- R1: 一つ目

## T1: a
- **要件**: R1
- **依存**: なし

## T2: b
- **要件**: R1
- **依存**: T1
EOT
    write_state_commit "T1:done:abcdef1234567"
    run_script req-status.sh
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_contains "$OUT" "T2(missing)" "state.json に無いタスクは missing"
}

echo "test-req-status.sh"
test_case "req-status: 要件ごとの状態と集計を出す" t_status_and_summary
test_case "req-status: 要件の節が無ければその旨を出してexit 0" t_no_section
test_case "req-status: どのタスクにも対応しない要件はexit 1" t_uncovered
test_case "req-status: state.json に無いタスクは missing と出す" t_missing_task
summary
