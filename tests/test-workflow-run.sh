#!/bin/bash
# T12: workflow-run.sh(前提の確認・ロック・記録・タスクの起動と完了待ち, POSIX版)
source "$(dirname "$0")/lib.sh"

# OUT の最後の行を返す
last_line() {
    printf '%s\n' "$OUT" | tail -n 1
}

# runs/<run>/done が現れるまで最大60秒待つ(0.5秒ごと)
wait_done() {
    local i
    for i in $(seq 1 120); do
        [ -f "$PROJ/.agents/workflow/runs/$1/done" ] && return 0
        sleep 0.5
    done
    return 1
}

set_state_branch() {
    python3 - "$(py_path "$PROJ/.agents/workflow/state.json")" "$1" <<'PY'
import json, sys
p, branch = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    s = json.load(f)
s['branch'] = branch
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# T1.txt・T2.txt をコミットし、workflow-run を使える config.json と子のスタブを用意する
setup_runner() {
    git -C "$PROJ" switch -q -c develop/t
    printf 'one\n' > "$PROJ/T1.txt"
    printf 'one\n' > "$PROJ/T2.txt"
    git -C "$PROJ" add T1.txt T2.txt
    git -C "$PROJ" commit -q -m "add T1 T2"
    write_tasks <<'TASKS'
# タスク一覧: test

## T1: 一番目
- **目的**: a
- **対象**: T1.txt を直す
- **参照ファイル**:
  - `T1.txt`(変更対象)
- **依存**: なし

## T2: 二番目
- **目的**: b
- **対象**: T2.txt を直す
- **参照ファイル**:
  - `T2.txt`(変更対象)
- **依存**: なし
TASKS
    write_state "T1:pending" "T2:pending"
    set_state_branch develop/t
    gh_stub_set 0 '[]' ''
    # 子は worktree の中で動く(.agents/ は worktree に無い)ため、スタブは絶対パスで指定する。
    # カレントディレクトリ(worktree)の親ディレクトリ名(T1-1)からタスクIDを取り、<ID>.txt に1行足す
    cat > "$PROJ/.agents/child-stub.sh" <<'SH'
#!/bin/bash
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
printf 'line\n' >> "$id.txt"
echo "## 完了報告"
echo "- 変更ファイル: $id.txt"
echo "- テスト結果: 全件パス"
SH
    chmod +x "$PROJ/.agents/child-stub.sh"
    # レビュー役。カレントディレクトリ(worktree)の親ディレクトリ名(review-<ID>-<N>)からタスクIDを取る
    cat > "$PROJ/.agents/review-stub.sh" <<'SH'
#!/bin/bash
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
id="${id#review-}"
echo "## 完了報告"
echo "- Verdict: pass"
echo "- 指摘: 0件(なし)"
echo "- 要約: $id を変える"
echo "- type: feat"
echo "- fix-notes: なし"
echo "- 理解確認: なし"
SH
    chmod +x "$PROJ/.agents/review-stub.sh"
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" \
        "$(py_path "$PROJ/.agents/child-stub.sh")" "$(py_path "$PROJ/.agents/review-stub.sh")" \
        "$(py_path "$(command -v bash)")" <<'PY'
import json, sys
p, child, review, bash = sys.argv[1:5]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
# Windows では PATH 上の bash が WSL 版のことがあり、C:/... のスクリプトを開けない。
# スタブを確実に実行するため、今の bash の絶対パスで起動する
cfg['max_parallel'] = 2
cfg['verify_before_commit'] = False
cfg['review'] = {'mode': 'dispatch', 'command_template': '"' + bash + '" "' + review + '" "{prompt}"'}
cfg['child_agent']['command_template'] = '"' + bash + '" "' + child + '" "{prompt}"'
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

# 子のスタブを $1 の本文に差し替える(config は同じ絶対パスを指したまま)
set_child_body() {
    printf '#!/bin/bash\n%s\n' "$1" > "$PROJ/.agents/child-stub.sh"
    chmod +x "$PROJ/.agents/child-stub.sh"
}

# レビュー役のスタブを $1 の本文に差し替える(config は同じ絶対パスを指したまま)
set_review_body() {
    printf '#!/bin/bash\n%s\n' "$1" > "$PROJ/.agents/review-stub.sh"
    chmod +x "$PROJ/.agents/review-stub.sh"
}

# 30秒眠ってから完了報告を出す子
set_slow_child() {
    cat > "$PROJ/.agents/child-stub.sh" <<'SH'
#!/bin/bash
sleep 30
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
printf 'line\n' >> "$id.txt"
echo "## 完了報告"
echo "- 変更ファイル: $id.txt"
echo "- テスト結果: 全件パス"
SH
    chmod +x "$PROJ/.agents/child-stub.sh"
}

# config.json の review.mode を消し、max_parallel を $1 にする
break_precondition() { # $1 = max_parallel の値
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, mp = sys.argv[1], int(sys.argv[2])
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
if mp == 0:
    cfg['review'].pop('mode', None)
else:
    cfg['review']['mode'] = 'dispatch'
    cfg['max_parallel'] = mp
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

t_runner_unsupported() {
    setup_runner
    break_precondition 0
    run_script workflow-run.sh
    assert_eq 4 "$CODE" "review.mode が無ければ exit 4: $ERR"
    assert_contains "$ERR" "review.mode" "stderr に理由"
    assert_eq "Next: escalate reason=runner-unsupported" "$(last_line)" "最後の行"
    assert_file_absent "$PROJ/.agents/workflow/runs/workflow-run/lock" "ロックを取らない"

    break_precondition 1
    run_script workflow-run.sh
    assert_eq 4 "$CODE" "max_parallel が 1 なら exit 4: $ERR"
    assert_contains "$ERR" "max_parallel" "stderr に理由"
    assert_eq "Next: escalate reason=runner-unsupported" "$(last_line)" "最後の行"
}

t_lock() {
    setup_runner
    mkdir -p "$PROJ/.agents/workflow/runs/workflow-run/lock"
    sleep 60 &
    local pid=$!
    printf '%s\n' "$pid" > "$PROJ/.agents/workflow/runs/workflow-run/lock/pid"

    run_script workflow-run.sh
    assert_eq 5 "$CODE" "生きているロックは exit 5: $ERR"
    assert_contains "$ERR" "already running" "stderr に理由"
    assert_eq "Next: escalate reason=already-running" "$(last_line)" "最後の行"

    kill "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
    write_state "T1:done" "T2:done"
    set_state_branch develop/t
    run_script workflow-run.sh
    assert_eq 0 "$CODE" "死んだロックは引き継ぐ: $ERR"
    assert_eq "Next: finish" "$(last_line)" "最後の行"
    assert_file_absent "$PROJ/.agents/workflow/runs/workflow-run/lock" "終了後にロックが消える"
}

t_parallel_max_wait() {
    setup_runner
    set_slow_child
    run_script workflow-run.sh --max-wait 1 --interval 1
    assert_eq 2 "$CODE" "exit 2: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/done" "子の完了を待たずに max-wait で返る"
    assert_contains "$OUT" "Started: T1-1" "T1 を起動した"
    assert_contains "$OUT" "Started: T2-1" "T2 を起動した"
    assert_contains "$OUT" "In flight: T1-1 running" "実行中を出す"
    assert_eq "Next: wait" "$(last_line)" "最後の行"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/workflow-run/progress.log")" "Started: T1-1" "progress.log に記録"
    assert_file_absent "$PROJ/.agents/workflow/runs/workflow-run/lock" "終了後にロックが消える"

    # 子(30秒 sleep)が終わってから一時ディレクトリを片付ける
    wait_done T1-1
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/done" "T1 の done"
    wait_done T2-1
    assert_file_exists "$PROJ/.agents/workflow/runs/T2-1/done" "T2 の done"
}

t_abnormal_exit() {
    setup_runner
    set_child_body 'exit 1'
    run_script workflow-run.sh --max-wait 60 --interval 1
    assert_eq 3 "$CODE" "exit 3: $ERR"
    assert_contains "$OUT" "Stopped: T1 reason=abnormal-exit" "異常終了で止まる"
    assert_contains "$OUT" "Detail: " "詳細のパスを出す"
    assert_eq "Next: escalate reason=abnormal-exit" "$(last_line)" "最後の行"
    assert_eq "EXIT:1" "$(head -1 "$PROJ/.agents/workflow/runs/T1-1/done")" "子が実際に異常終了した"
    wait_done T2-1
}

t_review_pass() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    local i
    for i in $(seq 1 60); do
        run_script workflow-run.sh --max-wait 2 --interval 1
        [ -f "$PROJ/.agents/workflow/runs/review-T1-1/verdict" ] && break
    done
    local runs="$PROJ/.agents/workflow/runs"
    assert_file_exists "$runs/T1-1/checked" "実装の run が checked"
    assert_file_exists "$runs/review-T1-1/worktree.txt" "レビューの worktree.txt"
    assert_eq "pass" "$(sed -n '1p' "$runs/review-T1-1/verdict" | tr -d '\r')" "verdict の1行目"
    assert_eq "feat" "$(sed -n '2p' "$runs/review-T1-1/verdict" | tr -d '\r')" "verdict の2行目"
    assert_eq "T1 を変える" "$(sed -n '3p' "$runs/review-T1-1/verdict" | tr -d '\r')" "verdict の3行目"
    assert_eq "$(sed -n 's/^path //p' "$runs/T1-1/worktree.txt" | head -n 1 | tr -d '\r')" \
        "$(sed -n 's/^path //p' "$runs/review-T1-1/worktree.txt" | head -n 1 | tr -d '\r')" \
        "レビューは実装と同じ worktree の中で行う"
    assert_contains "$(cat "$runs/workflow-run/progress.log")" "Review: T1-1 pass" "progress.log に記録"
}

t_review_invalid() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    set_review_body ':'        # 何も出力しないレビュー役
    local i
    for i in $(seq 1 60); do
        run_script workflow-run.sh --max-wait 2 --interval 1
        [ "$CODE" -eq 3 ] && break
    done
    assert_eq 3 "$CODE" "exit 3: $ERR"
    assert_contains "$OUT" "Stopped: T1 reason=review-invalid" "無効な完了報告で止まる"
    assert_eq "Next: escalate reason=review-invalid" "$(last_line)" "最後の行"
    assert_eq "in_progress" "$(state_get T1 status)" "T1 の状態は in_progress のまま"
}

t_finish() {
    setup_runner
    write_state "T1:done" "T2:done"
    set_state_branch develop/t
    run_script workflow-run.sh
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_eq "Next: finish" "$(last_line)" "最後の行"
}

# exit 2(--max-wait)の間は呼び直す。最大60回
run_until_not_wait() {
    local i
    for i in $(seq 1 60); do
        run_script workflow-run.sh --max-wait 5 --interval 1
        [ "$CODE" -ne 2 ] && return 0
    done
    return 0
}

t_collect_commit() {
    setup_runner
    write_state "T1:pending" "T2:pending"
    set_state_branch develop/t
    run_until_not_wait
    local runs="$PROJ/.agents/workflow/runs"
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_eq "Next: finish" "$(last_line)" "最後の行"
    assert_eq "done" "$(state_get T1 status)" "T1 の状態"
    assert_eq "done" "$(state_get T2 status)" "T2 の状態"
    local subjects; subjects="$(git -C "$PROJ" log --format=%s)"
    assert_contains "$subjects" "feat: T1 を変える" "レビュー役の type と要約で T1 をコミット"
    assert_contains "$subjects" "feat: T2 を変える" "レビュー役の type と要約で T2 をコミット"
    local progress; progress="$(cat "$runs/workflow-run/progress.log")"
    assert_contains "$progress" "Done: T1 " "progress.log に Done を記録"
    assert_contains "$progress" "retries=0" "progress.log に retries を記録"
    assert_file_absent "$runs/T1-1/worktree" "collect 後に T1 の worktree が消える"
}

t_commit_format() {
    setup_runner
    write_state "T1:pending" "T2:done"
    set_state_branch develop/t
    set_review_body 'run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
id="${id#review-}"
echo "## 完了報告"
echo "- Verdict: pass"
echo "- 指摘: 0件(なし)"
echo "- 要約: $id を変える"
echo "- type: bogus"
echo "- fix-notes: なし"
echo "- 理解確認: なし"'
    run_until_not_wait
    local runs="$PROJ/.agents/workflow/runs"
    assert_eq 3 "$CODE" "exit 3: $ERR"
    assert_contains "$OUT" "Stopped: T1 reason=commit-format" "commit-format で止まる"
    assert_eq "Next: escalate reason=commit-format" "$(last_line)" "最後の行"
    assert_eq "in_review" "$(state_get T1 status)" "T1 の状態は in_review のまま"
    assert_file_exists "$runs/T1-1/collected" "collect 済み"
}

t_group_advance() {
    setup_runner
    write_tasks <<'TASKS'
# タスク一覧: test

<!-- グループ g1 -->

## T1: 一番目
- **目的**: a
- **対象**: T1.txt を直す
- **参照ファイル**:
  - `T1.txt`(変更対象)
- **依存**: なし

<!-- グループ g2 -->

## T2: 二番目
- **目的**: b
- **対象**: T2.txt を直す
- **参照ファイル**:
  - `T2.txt`(変更対象)
- **依存**: なし
TASKS
    write_state "T1:pending" "T2:pending"
    set_state_branch develop/t
    set_state_group g1
    run_until_not_wait
    assert_eq 0 "$CODE" "exit 0: $ERR"
    assert_eq "Next: group-advance" "$(last_line)" "最後の行"
    assert_eq "done" "$(state_get T1 status)" "T1 の状態"
    assert_eq "pending" "$(state_get T2 status)" "T2 の状態"
}

echo "test-workflow-run.sh"
test_case "run: 使える条件を満たさなければ runner-unsupported(exit 4)" t_runner_unsupported
test_case "run: 生きているロックは already-running、死んでいれば引き継ぐ" t_lock
test_case "run: 並列に起動し、max-wait で Next: wait を返す" t_parallel_max_wait
test_case "run: 実装の run が異常終了したら、その理由で止まる" t_abnormal_exit
test_case "run: 子が終わると worktree の中でレビューし、verdict を記録する" t_review_pass
test_case "run: レビューの完了報告が無効なら review-invalid で止まる" t_review_invalid
test_case "run: 全タスク done なら Next: finish" t_finish
test_case "run: 合格した run を collect してコミットし、Done 行を出す" t_collect_commit
test_case "run: type が無効なら commit-format で止まり、in_review のまま残る" t_commit_format
test_case "run: グループの最後で Next: group-advance を返す" t_group_advance
summary
