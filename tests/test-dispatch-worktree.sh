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
    setup_wt_child "git -C \"$PROJ\" branch other; git -C \"$PROJ\" commit -q --allow-empty -m other; echo hello > a.txt; $WT_REPORT"
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(head -1 "$PROJ/.agents/workflow/runs/T1-1/done")" "done marker"
    assert_eq 1 "$(has_branch other && echo 1 || echo 0)" "子の実行中に本体で other ブランチができた"
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

echo "test-dispatch-worktree.sh"
test_case "dispatch-worktree: create で worktree・ブランチ・worktree.txt ができる" t_create
test_case "dispatch-worktree: remove で worktree とブランチが消える" t_remove
test_case "dispatch-worktree: 試行 2 の create で前の変更を持ち越す" t_carry
test_case "dispatch-worktree: worktree add が失敗するとブランチ・WT・worktree.txt が残らず exit 30" t_create_fail
test_case "dispatch-worktree: 試行 2 の worktree add が失敗すると前の変更が本体に戻る" t_create_fail_restore
test_case "dispatch-worktree: worktree add に -c core.longpaths=true が付く" t_create_longpaths
test_case "dispatch-worktree: collect で変更が本体に入り worktree が消える" t_collect
test_case "dispatch-worktree: collect で本体と衝突すると exit 40 で worktree が残る" t_collect_conflict
test_case "dispatch-worktree: collect で本体が dirty だと exit 20" t_collect_dirty
test_case "dispatch-worktree: worktree の run を dispatch-run で動かし dispatch-check が collect を返す" t_run_check_ok
test_case "dispatch-worktree: 子の実行中に本体で branch・commit しても tampered にならない" t_run_check_main_git
test_case "dispatch-worktree: 子が worktree で commit すると tampered(exit 8)" t_run_check_commit
summary
