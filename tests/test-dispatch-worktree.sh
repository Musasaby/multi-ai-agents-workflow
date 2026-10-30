#!/bin/bash
# dispatch-worktree の create・remove・collect(POSIX版)
source "$(dirname "$0")/lib.sh"

# OUT の最後の行を返す
last_line() {
    printf '%s\n' "$OUT" | tail -n 1
}

# 本体にブランチ <name> があれば 0
has_branch() {
    git -C "$PROJ" rev-parse --verify -q "refs/heads/$1" > /dev/null
}

t_create() {
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "Next: continue" "$(last_line)" "最後の行は Next: continue"
    local run=".agents/workflow/runs/T1-1"
    assert_eq 1 "$([ -d "$PROJ/$run/worktree" ] && echo 1 || echo 0)" "worktree ができる"
    assert_eq 1 "$(has_branch agents-run/T1-1 && echo 1 || echo 0)" "ブランチ agents-run/T1-1 ができる"
    assert_file_exists "$PROJ/$run/worktree.txt" "worktree.txt ができる"
    assert_eq 3 "$(awk 'END { print NR }' "$PROJ/$run/worktree.txt")" "worktree.txt は3行"
    assert_eq 1 "$(grep -c '^path ' "$PROJ/$run/worktree.txt")" "path 行がある"
    assert_eq "branch refs/heads/agents-run/T1-1" "$(sed -n 2p "$PROJ/$run/worktree.txt")" "2行目は branch"
    assert_eq "base $(git -C "$PROJ" rev-parse HEAD)" "$(sed -n 3p "$PROJ/$run/worktree.txt")" "3行目は base <HEAD>"
    assert_eq 1 "$([ -d "$PROJ/$run/worktree/$run/tmp" ] && echo 1 || echo 0)" "worktree 内に tmp ができる"
    assert_contains "$OUT" "Carried: none" "試行 1 は持ち越しなし"

    run_script dispatch-worktree.sh create T1 1
    assert_eq 30 "$CODE" "2回目は exit 30"
    assert_eq "Next: escalate reason=worktree" "$(last_line)" "2回目は escalate reason=worktree"
}

t_remove() {
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create exit: $ERR"
    run_script dispatch-worktree.sh remove T1 1
    assert_eq 0 "$CODE" "remove exit: $ERR"
    assert_eq "Next: continue" "$(last_line)" "remove は Next: continue"
    local run=".agents/workflow/runs/T1-1"
    assert_file_absent "$PROJ/$run/worktree" "worktree が消える"
    assert_file_absent "$PROJ/$run/worktree.txt" "worktree.txt が消える"
    assert_eq 0 "$(has_branch agents-run/T1-1 && echo 1 || echo 0)" "ブランチが消える"

    run_script dispatch-worktree.sh remove T1 1
    assert_eq 0 "$CODE" "無くても remove は exit 0"
}

t_carry() {
    local run1=".agents/workflow/runs/T1-1"
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create 1 exit: $ERR"
    printf 'hello\n' > "$PROJ/$run1/worktree/a.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    assert_file_exists "$PROJ/a.txt" "collect で本体に a.txt が当たる"
    assert_file_exists "$PROJ/$run1/changes.patch" "changes.patch ができる"

    run_script dispatch-worktree.sh create T1 2
    assert_eq 0 "$CODE" "create 2 exit: $ERR"
    assert_eq "Next: continue" "$(last_line)" "最後の行は Next: continue"
    assert_contains "$OUT" "Carried: $run1/changes.patch" "試行 1 の変更を持ち越す"
    assert_file_absent "$PROJ/a.txt" "本体から a.txt が取り除かれる"
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-2/worktree/a.txt" "新しい worktree に a.txt がある"
}

# git のラッパーを PATH 先頭に置く。GIT_WRAP_FAIL=1 の間、`worktree add` はブランチと WT のディレクトリを
# 作ってから exit 128 で終わる。それ以外の引数は本物の git に渡す。引数は GIT_WRAP_LOG に記録する
wrap_git_on() {
    GIT_WRAP_DIR="$(mktemp -d)"
    GIT_WRAP_LOG="$GIT_WRAP_DIR/git.log"
    GIT_WRAP_REAL="$(command -v git)"
    PATH_BEFORE_WRAP="$PATH"
    export GIT_WRAP_LOG GIT_WRAP_REAL
    cat > "$GIT_WRAP_DIR/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_WRAP_LOG"
if [ "${GIT_WRAP_FAIL:-}" = 1 ] && [[ " $* " == *" worktree add "* ]]; then
    WT="${@: -2:1}"
    while [ $# -gt 0 ]; do
        [ "$1" = "-b" ] && BR="$2"
        shift
    done
    "$GIT_WRAP_REAL" branch "$BR" HEAD
    mkdir -p "$WT"
    echo "fatal: simulated worktree add failure" >&2
    exit 128
fi
exec "$GIT_WRAP_REAL" "$@"
EOF
    chmod +x "$GIT_WRAP_DIR/git"
    if command -v cygpath > /dev/null 2>&1; then
        export PATH="$(cygpath -u "$GIT_WRAP_DIR"):$PATH"
    else
        export PATH="$GIT_WRAP_DIR:$PATH"
    fi
}

wrap_git_off() {
    export PATH="$PATH_BEFORE_WRAP"
    unset GIT_WRAP_FAIL GIT_WRAP_LOG GIT_WRAP_REAL
    rm -rf "$GIT_WRAP_DIR"
}

t_create_fail() {
    wrap_git_on
    local run=".agents/workflow/runs/T1-1"
    GIT_WRAP_FAIL=1 run_script dispatch-worktree.sh create T1 1
    assert_eq 30 "$CODE" "worktree add の失敗は exit 30"
    assert_eq "Next: escalate reason=worktree" "$(last_line)" "escalate reason=worktree"
    assert_eq 0 "$(has_branch agents-run/T1-1 && echo 1 || echo 0)" "ブランチが残らない"
    assert_file_absent "$PROJ/$run/worktree" "WT が残らない"
    assert_file_absent "$PROJ/$run/worktree.txt" "worktree.txt が残らない"
    assert_contains "$(cat "$GIT_WRAP_LOG")" "worktree add" "ラッパーが worktree add を受けた"

    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "ラッパーを外すと同じ試行で create できる: $ERR"
    wrap_git_off
}

t_create_fail_restore() {
    wrap_git_on
    local run1=".agents/workflow/runs/T1-1"
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create 1 exit: $ERR"
    printf 'hello\n' > "$PROJ/$run1/worktree/a.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    assert_file_exists "$PROJ/a.txt" "collect で本体に a.txt が当たる"

    GIT_WRAP_FAIL=1 run_script dispatch-worktree.sh create T1 2
    assert_eq 30 "$CODE" "試行 2 の失敗は exit 30"
    assert_file_exists "$PROJ/a.txt" "前の試行の変更が本体に戻る"
    assert_eq 0 "$(has_branch agents-run/T1-2 && echo 1 || echo 0)" "試行 2 のブランチが残らない"
    wrap_git_off
}

t_create_longpaths() {
    wrap_git_on
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create exit: $ERR"
    assert_contains "$(cat "$GIT_WRAP_LOG")" "-c core.longpaths=true worktree add" "worktree add に -c core.longpaths=true が付く"
    wrap_git_off
}

# 本体に base.txt(2行)を足して履歴に残し、T1 の変更対象を base.txt だけにして create する
setup_collect() {
    printf 'line1\nline2\n' > "$PROJ/base.txt"
    git -C "$PROJ" add base.txt
    git -C "$PROJ" commit -q -m "add base"
    write_tasks <<'TASKS'
## T1: 一番目
- **目的**: a
- **依存**: なし
- **対象**: `base.txt`(変更対象)
TASKS
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create exit: $ERR"
    WTDIR="$PROJ/.agents/workflow/runs/T1-1/worktree"
}

t_collect() {
    setup_collect
    printf 'line1\nfromwt\n' > "$WTDIR/base.txt"
    printf 'new\n' > "$WTDIR/new.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    assert_eq "Next: review T1" "$(last_line)" "最後の行は Next: review T1"
    assert_eq "line1 fromwt" "$(tr -d '\r' < "$PROJ/base.txt" | tr '\n' ' ' | sed 's/ $//')" "既存ファイルの変更が本体に入る"
    assert_file_exists "$PROJ/new.txt" "新規ファイルが本体に入る"
    assert_contains "$OUT" "Undeclared: new.txt" "変更対象に無い new.txt は Undeclared に出る"
    assert_not_contains "$OUT" "Undeclared: base.txt" "base.txt は Undeclared に出ない"
    assert_file_absent "$WTDIR" "worktree が消える"
    assert_eq 0 "$(has_branch agents-run/T1-1 && echo 1 || echo 0)" "ブランチが消える"
}

t_collect_conflict() {
    setup_collect
    printf 'line1\nfromwt\n' > "$WTDIR/base.txt"
    printf 'line1\nfrommain\n' > "$PROJ/base.txt"
    git -C "$PROJ" commit -q -a -m "main change"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 40 "$CODE" "exit 40"
    assert_eq "Next: escalate reason=conflict" "$(last_line)" "escalate reason=conflict"
    assert_eq 1 "$([ -d "$WTDIR" ] && echo 1 || echo 0)" "worktree は残る"
}

t_collect_dirty() {
    setup_collect
    printf 'line1\nfromwt\n' > "$WTDIR/base.txt"
    printf 'dirty\n' > "$PROJ/base.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 20 "$CODE" "exit 20"
    assert_eq "Next: escalate reason=dirty-tree" "$(last_line)" "escalate reason=dirty-tree"
    assert_eq 1 "$([ -d "$WTDIR" ] && echo 1 || echo 0)" "worktree は残る"
}

t_collect_git_fail() {
    setup_collect
    local run="$PROJ/.agents/workflow/runs/T1-1"
    printf 'line1\nfromwt\n' > "$WTDIR/base.txt"
    local gitdir
    gitdir="$(git -C "$WTDIR" rev-parse --absolute-git-dir)"
    : > "$gitdir/index.lock"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 30 "$CODE" "exit 30"
    assert_eq "Next: escalate reason=worktree" "$(last_line)" "escalate reason=worktree"
    assert_eq 1 "$([ -d "$WTDIR" ] && echo 1 || echo 0)" "worktree は残る"
    assert_eq 1 "$(has_branch agents-run/T1-1 && echo 1 || echo 0)" "ブランチは残る"
    assert_file_exists "$run/worktree.txt" "worktree.txt は残る"
    rm -f "$gitdir/index.lock"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "index.lock を消すと collect できる: $ERR"
}

t_collect_committed() {
    setup_collect
    printf 'hello\n' > "$WTDIR/a.txt"
    git -C "$WTDIR" add a.txt
    git -C "$WTDIR" commit -q -m "child"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    assert_file_exists "$PROJ/a.txt" "子がコミットした a.txt が本体に入る"
}

t_collect_no_base() {
    setup_collect
    local run="$PROJ/.agents/workflow/runs/T1-1"
    sed -i '/^base /d' "$run/worktree.txt"
    printf 'hello\n' > "$WTDIR/a.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "base 行が無くても collect できる: $ERR"
    assert_file_exists "$PROJ/a.txt" "HEAD との差分で a.txt が本体に入る"
}

t_collect_marks_collected() {
    setup_collect
    local run="$PROJ/.agents/workflow/runs/T1-1"
    printf 'line1\nfromwt\n' > "$WTDIR/base.txt"
    assert_file_absent "$run/collected" "collect 前は collected が無い"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    assert_file_exists "$run/collected" "collect が成功すると collected ができる"
}

t_create_after_collect_conflict() {
    setup_collect
    local run="$PROJ/.agents/workflow/runs/T1-1"
    printf 'line1\nfromwt\n' > "$WTDIR/base.txt"
    printf 'line1\nfrommain\n' > "$PROJ/base.txt"
    git -C "$PROJ" commit -q -a -m "main change"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 40 "$CODE" "collect は exit 40"
    assert_file_absent "$run/collected" "衝突した collect では collected ができない"

    run_script dispatch-worktree.sh create T1 2
    assert_eq 0 "$CODE" "create 2 exit: $ERR"
    assert_contains "$OUT" "Carried: none (not collected:" "取り込まれなかった試行は持ち越さない"
    assert_eq "line1 frommain" "$(tr -d '\r' < "$PROJ/base.txt" | tr '\n' ' ' | sed 's/ $//')" "本体の base.txt は変わらない"
    assert_file_exists "$run/changes.patch" "試行 1 の changes.patch がある"
}

t_create_carry_conflict() {
    setup_collect
    local run="$PROJ/.agents/workflow/runs/T1-1"
    printf 'mine\nline2\n' > "$WTDIR/base.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    assert_file_exists "$run/collected" "collect で collected ができる"
    assert_eq "mine" "$(head -n 1 "$PROJ/base.txt" | tr -d '\r')" "本体の1行目は mine"
    printf 'theirs\nline2\n' > "$PROJ/base.txt"
    git -C "$PROJ" commit -q -a -m "theirs"
    printf 'mine\nline2\n' > "$PROJ/base.txt"

    run_script dispatch-worktree.sh create T1 2
    assert_eq 40 "$CODE" "持ち越しの衝突は exit 40"
    assert_eq "Next: escalate reason=conflict" "$(last_line)" "escalate reason=conflict"
    assert_eq 0 "$(has_branch agents-run/T1-2 && echo 1 || echo 0)" "試行 2 のブランチが残らない"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-2/worktree" "試行 2 の WT が残らない"
    assert_eq "mine" "$(head -n 1 "$PROJ/base.txt" | tr -d '\r')" "本体の1行目が mine に戻る"
}

t_abort() {
    local run=".agents/workflow/runs/T1-1"
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create exit: $ERR"
    run_script dispatch-worktree.sh abort T1 1
    assert_eq 0 "$CODE" "abort exit: $ERR"
    assert_eq "Next: continue" "$(last_line)" "abort は Next: continue"
    assert_file_absent "$PROJ/$run/worktree" "worktree が消える"
    assert_file_absent "$PROJ/$run/worktree.txt" "worktree.txt が消える"
    assert_eq 0 "$(has_branch agents-run/T1-1 && echo 1 || echo 0)" "ブランチが消える"
}

t_abort_reapply() {
    local run1=".agents/workflow/runs/T1-1" run2=".agents/workflow/runs/T1-2"
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create 1 exit: $ERR"
    printf 'hello\n' > "$PROJ/$run1/worktree/a.txt"
    run_script dispatch-worktree.sh collect T1 1
    assert_eq 0 "$CODE" "collect exit: $ERR"
    run_script dispatch-worktree.sh create T1 2
    assert_eq 0 "$CODE" "create 2 exit: $ERR"
    assert_file_absent "$PROJ/a.txt" "create で本体から a.txt が取り除かれる"
    assert_file_exists "$PROJ/$run2/reverted" "reverted ができる"

    run_script dispatch-worktree.sh abort T1 2
    assert_eq 0 "$CODE" "abort exit: $ERR"
    assert_eq "Next: continue" "$(last_line)" "abort は Next: continue"
    assert_file_exists "$PROJ/a.txt" "abort で a.txt が本体に戻る"
    assert_file_absent "$PROJ/$run2/reverted" "reverted が消える"
    assert_file_absent "$PROJ/$run2/worktree" "試行 2 の WT が消える"
    assert_eq 0 "$(has_branch agents-run/T1-2 && echo 1 || echo 0)" "試行 2 のブランチが消える"
}

# ---------- dispatch-run・dispatch-check(worktree の run) ----------

WT_REPORT='echo "## 完了報告"; echo "- 変更ファイル: a.txt"; echo "- テスト結果: 全件パス"'

# 子の本文 $1 を child.sh にして config の command_template に設定し、T1-1 の worktree を作る
setup_wt_child() {
    run_script dispatch-worktree.sh create T1 1
    assert_eq 0 "$CODE" "create exit: $ERR"
    printf '#!/bin/bash
%s
' "$1" > "$PROJ/.agents/workflow/runs/T1-1/worktree/child.sh"
    # Windows では PATH 上の bash が WSL 版のことがあり、worktree の .git(Windows パス)を辿れない。
    # git を使う子のため、今の bash の絶対パスで起動する
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$(py_path "$(command -v bash)")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['command_template'] = '"' + sys.argv[2] + '" ./child.sh "{prompt}"'
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
    printf 'prompt
' > "$PROJ/.agents/workflow/runs/T1-1/prompt.md"
}

t_run_check_ok() {
    setup_wt_child "echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    local run="$PROJ/.agents/workflow/runs/T1-1"
    assert_eq "EXIT:0" "$(head -1 "$run/done")" "done marker"
    assert_file_exists "$run/worktree/a.txt" "子は worktree の中で a.txt を作る"
    assert_file_absent "$PROJ/a.txt" "本体の作業ツリーは変わらない"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "check exit: $ERR"
    assert_contains "$OUT" "Guard: ok" "guard ok"
    assert_eq "Next: collect T1" "$(last_line)" "最後の行は Next: collect T1"
}

t_run_check_main_git() {
    write_state "T1:in_progress" "T2:in_progress"
    setup_wt_child "git -C \"$PROJ\" branch agents-run/T2-1; git -C \"$PROJ\" commit -q --allow-empty -m other; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(head -1 "$PROJ/.agents/workflow/runs/T1-1/done")" "done marker"
    assert_eq 1 "$(has_branch agents-run/T2-1 && echo 1 || echo 0)" "子の実行中に本体で実行中のタスクの run のブランチができた"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "本体の git 変更では tampered にならない: $OUT"
    assert_not_contains "$OUT" "git changed" "git changed は出ない"
    assert_eq "Next: collect T1" "$(last_line)" "最後の行は Next: collect T1"
}

t_run_check_commit() {
    setup_wt_child "echo hello > a.txt; git add a.txt; git commit -q -m child; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "worktree で commit すると exit 8"
    assert_contains "$OUT" "git changed: head" "git changed: head"
}

t_run_check_tag() {
    setup_wt_child "echo hello > a.txt; git tag t1; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "worktree で tag を作ると exit 8"
    assert_contains "$OUT" "git changed" "git changed"
}

t_run_check_state_entry() {
    write_state "T1:in_progress" "T2:pending"
    setup_wt_child "sed -i 's/in_progress/done/' \"$PROJ/.agents/workflow/state.json\"; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "本体の state.json の自分のタスクの status を書き換えると exit 8"
    assert_contains "$OUT" "changed: .agents/workflow/state.json" "state.json の changed"
}

t_run_check_tasks_md() {
    setup_wt_child "echo extra >> \"$PROJ/.agents/workflow/tasks.md\"; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "本体の tasks.md を書き換えると exit 8"
    assert_contains "$OUT" "changed: .agents/workflow/tasks.md" "tasks.md の changed"
}

t_run_check_parent_activity() {
    write_state "T1:in_progress" "T2:pending"
    setup_wt_child "git -C \"$PROJ\" commit -q --allow-empty -m parent; sed -i 's/pending/in_progress/' \"$PROJ/.agents/workflow/state.json\"; git -C \"$PROJ\" branch agents-run/T2-1; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    assert_eq 1 "$(has_branch agents-run/T2-1 && echo 1 || echo 0)" "子の実行中に本体でほかの run のブランチができた"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "親の作業・ほかのタスクの欄・ほかの run のブランチでは tampered にならない: $OUT"
    assert_not_contains "$OUT" "changed" "changed は出ない"
    assert_eq "Next: collect T1" "$(last_line)" "最後の行は Next: collect T1"
}

# 子の worktree に、本体の state.json の 1 タスクの欄を書き換えるスクリプトを置く
# 使い方: python3 setstate.py <state.json> <ID> <status> [<commit>]
write_setstate_py() {
    cat > "$PROJ/.agents/workflow/runs/T1-1/worktree/setstate.py" <<'PY'
import json, sys
p, tid, status = sys.argv[1:4]
commit = sys.argv[4] if len(sys.argv) > 4 else None
with open(p, encoding='utf-8') as f:
    s = json.load(f)
for e in s['tasks']:
    if e['id'] == tid:
        e['status'] = status
        if commit:
            e['commit'] = commit
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(s, f)
PY
}

t_run_check_other_task_done() {
    write_state "T1:in_progress" "T2:pending"
    local sp
    sp="$(py_path "$PROJ/.agents/workflow/state.json")"
    setup_wt_child "python3 setstate.py \"$sp\" T2 done; echo hello > a.txt; $WT_REPORT"
    write_setstate_py
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "ほかのタスクを commit 無しで done にすると exit 8: $OUT"
    assert_contains "$OUT" "changed: .agents/workflow/state.json (T2)" "state.json (T2) の changed"
}

t_run_check_done_reverted() {
    write_state "T1:in_progress" "T2:pending" "T3:done"
    local sp
    sp="$(py_path "$PROJ/.agents/workflow/state.json")"
    setup_wt_child "python3 setstate.py \"$sp\" T3 pending; echo hello > a.txt; $WT_REPORT"
    write_setstate_py
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "起動時に done だったタスクを pending に戻すと exit 8: $OUT"
    assert_contains "$OUT" "changed: .agents/workflow/state.json (T3)" "state.json (T3) の changed"
}

t_run_check_parent_done() {
    write_state "T1:in_progress" "T2:pending"
    local sp
    sp="$(py_path "$PROJ/.agents/workflow/state.json")"
    setup_wt_child "git -C \"$PROJ\" commit -q --allow-empty -m parent; python3 setstate.py \"$sp\" T2 in_progress; python3 setstate.py \"$sp\" T2 in_review; python3 setstate.py \"$sp\" T2 done \"\$(git -C \"$PROJ\" rev-parse HEAD)\"; echo hello > a.txt; $WT_REPORT"
    write_setstate_py
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(head -1 "$PROJ/.agents/workflow/runs/T1-1/done")" "done marker"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "親の正規の遷移(commit は本体の HEAD の祖先)では tampered にならない: $OUT"
    assert_not_contains "$OUT" "changed" "changed は出ない"
}

t_run_check_parent_rewind() {
    git -C "$PROJ" commit -q --allow-empty -m p1
    git -C "$PROJ" commit -q --allow-empty -m p2
    local pb
    pb="$(git -C "$PROJ" symbolic-ref --short HEAD)"
    setup_wt_child "git -C \"$PROJ\" update-ref refs/heads/$pb HEAD~1; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "親の作業ブランチを巻き戻すと exit 8: $OUT"
    assert_contains "$OUT" "git changed: parent" "git changed: parent"
}

t_run_check_foreign_run_branch() {
    write_state "T1:in_progress" "T9:pending"
    setup_wt_child "git -C \"$PROJ\" branch agents-run/T9-1; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "実行中でないタスクの run のブランチを作ると exit 8: $OUT"
    assert_contains "$OUT" "git changed: refs" "git changed: refs"
}

t_run_check_preexisting_other_run() {
    write_state "T1:in_progress" "T2:in_progress"
    git -C "$PROJ" branch agents-run/T2-1
    setup_wt_child "echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "起動前からある実行中のタスクの run のブランチでは tampered にならない: $OUT"
    assert_not_contains "$OUT" "changed" "changed は出ない"
}

t_git_state_other_runs() {
    local pr base with_t2 with_t9
    pr="refs/heads/$(git -C "$PROJ" symbolic-ref --short HEAD)"
    git -C "$PROJ" branch agents-run/T1-1 2> /dev/null || true
    run_script git-state.sh --run refs/heads/agents-run/T1-1 --parent "$pr" --other-runs T2
    base="$(printf '%s\n' "$OUT" | grep '^refs ')"
    git -C "$PROJ" branch agents-run/T2-1
    run_script git-state.sh --run refs/heads/agents-run/T1-1 --parent "$pr" --other-runs T2
    with_t2="$(printf '%s\n' "$OUT" | grep '^refs ')"
    assert_eq "$base" "$with_t2" "--other-runs に入っている T2 の run のブランチは除かれる"
    git -C "$PROJ" branch agents-run/T9-1
    run_script git-state.sh --run refs/heads/agents-run/T1-1 --parent "$pr" --other-runs T2
    with_t9="$(printf '%s\n' "$OUT" | grep '^refs ')"
    assert_eq 1 "$([ "$base" != "$with_t9" ] && echo 1 || echo 0)" "--other-runs に無い T9 の run のブランチは除かれない"
}

echo "test-dispatch-worktree.sh"
test_case "dispatch-worktree: create で worktree・ブランチ・worktree.txt ができる" t_create
test_case "dispatch-worktree: remove で worktree とブランチが消える" t_remove
test_case "dispatch-worktree: 試行 2 の create で前の変更を持ち越す" t_carry
test_case "dispatch-worktree: worktree add が失敗するとブランチ・WT・worktree.txt が残らず exit 30" t_create_fail
test_case "dispatch-worktree: 試行 2 の worktree add が失敗すると前の変更が本体に戻る" t_create_fail_restore
test_case "dispatch-worktree: worktree add に -c core.longpaths=true が付く" t_create_longpaths
test_case "dispatch-worktree: collect で変更が本体に入り worktree が消える" t_collect
test_case "dispatch-worktree: collect で本体と衝突すると exit 40 で worktree が残る" t_collect_conflict
test_case "dispatch-worktree: collect が成功すると collected ができる" t_collect_marks_collected
test_case "dispatch-worktree: collect の衝突の後の create は前の試行を持ち越さない" t_create_after_collect_conflict
test_case "dispatch-worktree: create で持ち越しが衝突すると exit 40 で WT・ブランチが残らず本体が戻る" t_create_carry_conflict
test_case "dispatch-worktree: abort で worktree・ブランチ・worktree.txt が消える" t_abort
test_case "dispatch-worktree: abort で reverted のパッチが本体に当たり reverted が消える" t_abort_reapply
test_case "dispatch-worktree: collect で本体が dirty だと exit 20" t_collect_dirty
test_case "dispatch-worktree: collect で git add が失敗すると exit 30 で worktree が残り、直せば collect できる" t_collect_git_fail
test_case "dispatch-worktree: 子が worktree でコミットした変更が collect のパッチに入る" t_collect_committed
test_case "dispatch-worktree: worktree.txt に base 行が無いと HEAD との差分で collect する" t_collect_no_base
test_case "dispatch-worktree: worktree の run を dispatch-run で動かし dispatch-check が collect を返す" t_run_check_ok
test_case "dispatch-worktree: 子の実行中に本体で実行中のタスクの branch・commit をしても tampered にならない" t_run_check_main_git
test_case "dispatch-worktree: 子が worktree で commit すると tampered(exit 8)" t_run_check_commit
test_case "dispatch-worktree: 子が worktree で tag を作ると tampered(exit 8)" t_run_check_tag
test_case "dispatch-worktree: 子が本体の state.json の自分のタスクの欄を書き換えると tampered(exit 8)" t_run_check_state_entry
test_case "dispatch-worktree: 子が本体の tasks.md を書き換えると tampered(exit 8)" t_run_check_tasks_md
test_case "dispatch-worktree: 実行中の親の commit・ほかのタスクの欄・ほかの run のブランチでは tampered にならない" t_run_check_parent_activity
test_case "dispatch-worktree: 子が本体の state.json でほかのタスクを commit 無しで done にすると tampered(exit 8)" t_run_check_other_task_done
test_case "dispatch-worktree: 子が起動時に done だったタスクを pending に戻すと tampered(exit 8)" t_run_check_done_reverted
test_case "dispatch-worktree: 実行中に親がほかのタスクを正規に done にしても tampered にならない" t_run_check_parent_done
test_case "dispatch-worktree: 子が本体で親の作業ブランチを巻き戻すと tampered(exit 8)" t_run_check_parent_rewind
test_case "dispatch-worktree: 子が実行中でないタスクの run のブランチを作ると tampered(exit 8)" t_run_check_foreign_run_branch
test_case "dispatch-worktree: 起動前からある実行中のタスクの run のブランチは tampered にならない" t_run_check_preexisting_other_run
test_case "dispatch-worktree: git-state の --other-runs は指定した ID の run のブランチだけを除く" t_git_state_other_runs
summary
