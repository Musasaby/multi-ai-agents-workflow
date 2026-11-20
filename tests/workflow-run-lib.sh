#!/bin/bash
# test-workflow-run.sh / test-workflow-run-retry.sh の共通の準備関数(POSIX版)。
# 単体では実行しない。lib.sh を読み込んだ後に source して使う。

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
n="${run_name##*-}"
# .agents/review-fail-<ID> があれば、レビュー不合格として次の試行の fix-notes.md を書く
root="$(cd "$PWD/../../../.." && pwd)"
if [ -f "$root/review-fail-$id" ]; then
    rm -f "$root/review-fail-$id"
    mkdir -p "$root/workflow/runs/$id-$((n + 1))"
    printf '# 修正依頼\n\nレビューの指摘を直してください。\n' > "$root/workflow/runs/$id-$((n + 1))/fix-notes.md"
    echo "## 完了報告"
    echo "- Verdict: fail"
    echo "- 指摘: 1件(修正が必要)"
    echo "- 要約: $id を直す"
    echo "- type: feat"
    echo "- fix-notes: あり"
    echo "- 理解確認: なし"
    exit 0
fi
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

# release-child が現れるまで待ってから完了報告を出す子(最大60秒)
set_slow_child() {
    cat > "$PROJ/.agents/child-stub.sh" <<'SH'
#!/bin/bash
for i in $(seq 1 120); do [ -f "$(dirname "$0")/release-child" ] && break; sleep 0.5; done
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

# exit 2(--max-wait)の間は呼び直す。最大60回
run_until_not_wait() {
    local i
    for i in $(seq 1 60); do
        run_script workflow-run.sh --max-wait 5 --interval 1
        [ "$CODE" -ne 2 ] && return 0
    done
    return 0
}
