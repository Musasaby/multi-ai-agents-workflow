#!/bin/bash
# next-task: max_parallel が 2 以上のときの並列選択(POSIX版)
source "$(dirname "$0")/lib.sh"

# config.json に max_parallel を足す
set_max_parallel() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
c['max_parallel'] = int(sys.argv[2])
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# 依存なしの T1・T2 を、変更対象 $1・$2 で書く
two_tasks() {
    write_tasks <<EOF
# タスク一覧: test

## T1: 一番目
- **目的**: a
- **対象**: \`$1\`(変更対象)
- **依存**: なし

## T2: 二番目
- **目的**: b
- **対象**: \`$2\`(変更対象)
- **依存**: なし
EOF
}

t_parallel_disjoint_dispatches_both() {
    two_tasks src/a.txt src/b.txt
    write_state "T1:pending" "T2:pending"
    set_max_parallel 3
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: dispatch T1 T2" "${OUT##*$'\n'}" "both tasks are chosen"
}

t_parallel_overlap_dispatches_first_only() {
    two_tasks src/a.txt src/a.txt
    write_state "T1:pending" "T2:pending"
    set_max_parallel 3
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: dispatch T1" "${OUT##*$'\n'}" "only the first task is chosen"
}

t_parallel_no_free_slot_waits() {
    two_tasks src/a.txt src/b.txt
    write_state "T1:in_progress" "T2:in_progress"
    set_max_parallel 2
    run_script next-task.sh
    assert_eq 5 "$CODE" "exit code: $ERR"
    assert_eq "Next: wait T1 T2" "${OUT##*$'\n'}" "waits for running tasks"
}

t_parallel_exclusive_file_not_chosen_while_active() {
    two_tasks src/a.txt README.md
    write_state "T1:in_progress" "T2:pending"
    set_max_parallel 3
    run_script next-task.sh
    assert_eq 5 "$CODE" "exit code: $ERR"
    assert_eq "Next: wait T1" "${OUT##*$'\n'}" "README.md task is not chosen while another is running"
}

t_parallel_dir_and_file_overlap() {
    two_tasks src/ src/app.py
    write_state "T1:pending" "T2:pending"
    set_max_parallel 3
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: dispatch T1" "${OUT##*$'\n'}" "dir and file under it do not run together"
}

t_parallel_same_prefix_not_overlap() {
    two_tasks src/a src/ab
    write_state "T1:pending" "T2:pending"
    set_max_parallel 3
    run_script next-task.sh
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "Next: dispatch T1 T2" "${OUT##*$'\n'}" "src/a and src/ab are both chosen"
}

test_case "parallel: 変更対象が重ならなければ両方dispatch" t_parallel_disjoint_dispatches_both
test_case "parallel: ディレクトリとその下のファイルは重なる" t_parallel_dir_and_file_overlap
test_case "parallel: 前方一致だけの別パスは重ならない" t_parallel_same_prefix_not_overlap
test_case "parallel: 変更対象が重なれば先頭だけdispatch" t_parallel_overlap_dispatches_first_only
test_case "parallel: 空きが無ければwait(exit 5)" t_parallel_no_free_slot_waits
test_case "parallel: README.md を含むタスクは実行中があると選ばれない" t_parallel_exclusive_file_not_chosen_while_active
summary
