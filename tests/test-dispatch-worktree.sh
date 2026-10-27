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

echo "test-dispatch-worktree.sh"
test_case "dispatch-worktree: create で worktree・ブランチ・worktree.txt ができる" t_create
test_case "dispatch-worktree: remove で worktree とブランチが消える" t_remove
test_case "dispatch-worktree: 試行 2 の create で前の変更を持ち越す" t_carry
test_case "dispatch-worktree: collect で変更が本体に入り worktree が消える" t_collect
test_case "dispatch-worktree: collect で本体と衝突すると exit 40 で worktree が残る" t_collect_conflict
test_case "dispatch-worktree: collect で本体が dirty だと exit 20" t_collect_dirty
summary
