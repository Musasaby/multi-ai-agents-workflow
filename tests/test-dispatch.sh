#!/bin/bash
# #16: dispatch-run の done マーカー(シグナル終了の区別)と dispatch-check(POSIX版)
source "$(dirname "$0")/lib.sh"

IS_WINDOWS=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;; esac

set_child() { # $1 = 子スクリプトの本文
    printf '#!/bin/bash\n%s\n' "$1" > "$PROJ/child.sh"
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['command_template'] = 'bash ./child.sh "{prompt}"'
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    printf 'prompt\n' > "$PROJ/.agents/workflow/runs/T1-1/prompt.md"
}

done_exit() { head -1 "$PROJ/.agents/workflow/runs/T1-1/done"; }

# python3 を含まない PATH(dispatch-run.sh のフォールバック経路を通すため)
path_without_python() {
    local out="" dir cmd
    if [ "$IS_WINDOWS" = false ]; then
        # Linux では python3 と bash 等が同じ /usr/bin にあるため、必要なコマンドだけを
        # シンボリックリンクした一時ディレクトリを PATH にする
        out="$PROJ/.nopython-bin"
        mkdir -p "$out"
        for cmd in bash sh dirname mkdir rm sed cat date head sha256sum cut; do
            ln -sf "$(command -v "$cmd")" "$out/$cmd"
        done
        echo "$out"
        return
    fi
    IFS=':' read -ra dirs <<< "$PATH"
    for dir in "${dirs[@]}"; do
        if [ -e "$dir/python3" ] || [ -e "$dir/python3.exe" ]; then continue; fi
        out="${out:+$out:}$dir"
    done
    echo "$out"
}

# ---------- dispatch-run ----------

t_run_exit0() {
    set_child 'echo hello'
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(done_exit)" "done marker"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/output.log")" "hello" "output.log"
}

t_run_exit_nonzero() {
    set_child 'exit 3'
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:3" "$(done_exit)" "plain non-zero stays numeric"
}

t_run_signal_python() {
    if [ "$IS_WINDOWS" = true ]; then
        echo "    (skip: Windows has no POSIX signals for native python3)"
        return
    fi
    set_child 'kill -TERM $$'
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:signal:15" "$(done_exit)" "SIGTERM recorded as signal"
}

t_run_signal_fallback() {
    set_child 'kill -TERM $$'
    local p
    p="$(path_without_python)"
    (cd "$PROJ" && PATH="$p" .agents/workflow/scripts/dispatch-run.sh T1 1) > /dev/null 2>&1
    assert_eq "EXIT:signal:15" "$(done_exit)" "fallback: 128+15 recorded as signal"
}

t_run_exit_fallback() {
    set_child 'exit 3'
    local p
    p="$(path_without_python)"
    (cd "$PROJ" && PATH="$p" .agents/workflow/scripts/dispatch-run.sh T1 1) > /dev/null 2>&1
    assert_eq "EXIT:3" "$(done_exit)" "fallback: plain non-zero stays numeric"
}

set_isolate() { # $1 = true/false/absent
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
if v == 'absent':
    cfg['child_agent'].pop('isolate_xdg', None)
else:
    cfg['child_agent']['isolate_xdg'] = (v == 'true')
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# 子を python にする(Windows ネイティブ python から呼ぶ bash は WSL の bash になることがあり、
# その場合は Windows 側の環境変数を引き継がないため)
set_py_child() {
    set_child ''
    printf 'import os\nprint("DATA=" + os.environ.get("XDG_DATA_HOME", ""))\n' > "$PROJ/child.py"
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['command_template'] = 'python3 ./child.py "{prompt}"'
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

child_xdg() {
    (cd "$PROJ" && XDG_DATA_HOME=/caller/xdg-data XDG_CONFIG_HOME=/caller/xdg-config .agents/workflow/scripts/dispatch-run.sh T1 1) > /dev/null 2>&1
    cat "$PROJ/.agents/workflow/runs/T1-1/output.log"
}

t_run_xdg_inherited_by_default() {
    set_py_child
    set_isolate absent
    assert_contains "$(child_xdg)" "caller/xdg-data" "absent: caller XDG inherited"
    set_isolate false
    assert_contains "$(child_xdg)" "caller/xdg-data" "false: caller XDG inherited"
}

t_run_xdg_isolated() {
    set_py_child
    set_isolate true
    assert_contains "$(child_xdg)" "DATA=.agents/workflow/.config" "true: XDG isolated"
}

# ---------- dispatch-check ----------

# dispatch-run と同じ形式で guard.sha256 を書く(runs/<run>/prompt.md と管理ファイル)
write_guard() { # $1 = run 名(例: T1-1)
    local run="$1" f h
    (
        cd "$PROJ" || exit 1
        : > ".agents/workflow/runs/$run/guard.sha256"
        for f in ".agents/workflow/runs/$run/prompt.md" .agents/workflow/state.json .agents/workflow/tasks.md .agents/workflow/config.json; do
            if [ -f "$f" ]; then h="$(sha256sum "$f" | cut -d' ' -f1)"; else h=-; fi
            printf '%s  %s\n' "$h" "$f" >> ".agents/workflow/runs/$run/guard.sha256"
        done
    )
}

make_run() { # $1 = EXIT 値, $2 = output.log の内容, $3 = run 名(省略時 T1-1)
    local run="${3:-T1-1}"
    mkdir -p "$PROJ/.agents/workflow/runs/$run"
    printf 'prompt\n' > "$PROJ/.agents/workflow/runs/$run/prompt.md"
    printf 'EXIT:%s\nEND:2026-01-01T00:00:00+09:00\n' "$1" > "$PROJ/.agents/workflow/runs/$run/done"
    printf '%s\n' "$2" > "$PROJ/.agents/workflow/runs/$run/output.log"
    write_guard "$run"
}

REPORT=$'作業しました\n## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス'
ESC=$'\033'

t_check_ok() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "kind: ok" "kind"
    assert_contains "$OUT" "a.txt" "git status shown"
    assert_contains "$OUT" "Completion report: found" "report found"
    assert_contains "$OUT" "Guard: ok" "guard ok"
}

t_check_signal() {
    make_run "signal:15" "step 67 ..."
    run_script dispatch-check.sh T1 1
    assert_eq 4 "$CODE" "exit code"
    assert_contains "$OUT" "kind: signal" "kind"
    assert_contains "$OUT" "step 67" "log tail shown"
}

t_check_nonzero() {
    make_run 3 "$REPORT"
    run_script dispatch-check.sh T1 1
    assert_eq 4 "$CODE" "exit code"
    assert_contains "$OUT" "kind: nonzero" "kind"
}

t_check_crashed() {
    make_run "crashed:boom" ""
    run_script dispatch-check.sh T1 1
    assert_eq 4 "$CODE" "exit code"
    assert_contains "$OUT" "kind: crashed" "kind"
}

t_check_missing_report() {
    make_run 0 "did something but no report"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code"
    assert_contains "$OUT" "Completion report: missing" "report missing"
}

t_check_no_done() {
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    run_script dispatch-check.sh T1 1
    assert_eq 1 "$CODE" "exit code"
}

t_check_bom_done() {
    make_run 0 "$REPORT"
    printf '\xef\xbb\xbfEXIT:0\nEND:x\n' > "$PROJ/.agents/workflow/runs/T1-1/done"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "BOM-prefixed done marker (Windows PowerShell) parsed: $OUT"
}

# #35: 子がテンプレートを cat しただけの `## 完了報告` に一致させない
t_check_report_then_tool_activity() {
    make_run 0 "${ESC}[0m\$ ${ESC}[0mcat dispatch-pr-prompt-template.md
## 完了報告
- PR URL: <作成した PR の URL>
${ESC}[0m→ ${ESC}[0mRead README.md
${ESC}[0m\$ ${ESC}[0mls"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "invalid (tool activity after the report" "reason"
}

t_check_report_placeholder() {
    make_run 0 $'## 完了報告\n- 変更ファイル: <一覧>\n- テスト結果: <パス/失敗の件数>'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "template placeholder" "reason"
}

t_check_report_missing_field() {
    make_run 0 $'## 完了報告\n- 変更ファイル: a.txt\n- 備考: なし'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "missing field: テスト結果" "reason"
}

t_check_report_list_value_and_ansi() {
    # 値が次行以降の箇条書き・CRLF・ANSI エスケープ・前方のツール実行行があっても有効
    make_run 0 "${ESC}[0m\$ ${ESC}[0mbash tests/test.sh"$'\r\n## 完了報告\r\n- 変更ファイル:\r\n  - `a.txt`\r\n- テスト結果: 全件パス\r'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
}

t_check_permission_denied() {
    make_run 0 "! permission requested: external_directory (/tmp/*); auto-rejecting
✗ cd /tmp && git init failed
Error: The user rejected permission to use this specific tool call."
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Permission denied: yes" "flag"
    assert_contains "$OUT" "auto-rejecting" "denied line shown"
}

t_check_no_changes() {
    make_run 0 "$REPORT"
    run_script dispatch-check.sh T1 1
    assert_eq 7 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Changes: 0" "changes"
}

t_check_pr_run_without_changes() {
    make_run 0 $'## 完了報告\n- PR URL: https://github.com/o/r/pull/1\n- タイトル: t' pr-1-1
    run_script dispatch-check.sh pr-1 1
    assert_eq 0 "$CODE" "pr run is not checked for changes: $OUT"
}

# #34: 管理ファイルの変更・削除を検知する
t_check_state_changed() {
    write_state "T1:in_progress"
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    write_state "T1:done"
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "changed: .agents/workflow/state.json" "issue"
}

t_check_prompt_deleted() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    rm "$PROJ/.agents/workflow/runs/T1-1/prompt.md"
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "deleted: .agents/workflow/runs/T1-1/prompt.md" "issue"
}

t_check_guard_missing() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    rm "$PROJ/.agents/workflow/runs/T1-1/guard.sha256"
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "guard.sha256 not found" "issue"
}

t_check_log_truncated() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    printf '\0\0\0%s\n' "$REPORT" > "$PROJ/.agents/workflow/runs/T1-1/output.log"
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "truncated during the run" "issue"
}

# dispatch-run が書いた guard.sha256 を dispatch-check が検証する(結合)
t_run_then_check_ok() {
    write_state "T1:in_progress"
    set_child "printf 'x\\n' > a.txt; printf '## 完了報告\\n- 変更ファイル: a.txt\\n- テスト結果: 全件パス\\n'"
    run_script dispatch-run.sh T1 1
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/guard.sha256" "guard written"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
}

t_run_then_check_child_deletes_prompt() {
    set_child "rm -f .agents/workflow/runs/T1-1/prompt.md; printf 'x\\n' > a.txt; printf '## 完了報告\\n- 変更ファイル: a.txt\\n- テスト結果: 全件パス\\n'"
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
}

t_check_report_body_symbols() {
    # 報告本文の `→ ` や `$ ` で始まる行(色なし)はツール実行の記録とみなさない
    make_run 0 $'## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス\n$ npm test\n→ 要確認'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
}

t_check_quoted_permission_text() {
    # 子が表示したソース中の文字列(行頭が `! permission requested` でない)には反応しない
    make_run 0 "${ESC}[0m\$ ${ESC}[0mgrep -n auto-rejecting tests/test-dispatch.sh
12:    make_run 0 \"! permission requested: external_directory (/tmp/*); auto-rejecting
Error: The user rejected permission to use this specific tool call.\"
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Permission denied: no" "flag"
}

t_check_permission_denied_colored() {
    make_run 0 "${ESC}[91m! permission requested: external_directory (/tmp/*); auto-rejecting${ESC}[0m"
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "colored permission line detected: $OUT"
}

echo "test-dispatch.sh"

test_case "run: 正常終了はEXIT:0" t_run_exit0
test_case "run: 通常の非0は数値のまま" t_run_exit_nonzero
test_case "run: SIGTERMはsignal:15(python経路)" t_run_signal_python
test_case "run: SIGTERMはsignal:15(フォールバック経路)" t_run_signal_fallback
test_case "run: 通常の非0は数値のまま(フォールバック経路)" t_run_exit_fallback
test_case "run: isolate_xdg 未指定/false は XDG を引き継ぐ" t_run_xdg_inherited_by_default
test_case "run: isolate_xdg true は XDG を切り替える" t_run_xdg_isolated
test_case "check: 正常" t_check_ok
test_case "check: signalはexit 4" t_check_signal
test_case "check: 非0はexit 4" t_check_nonzero
test_case "check: crashedはexit 4" t_check_crashed
test_case "check: 完了報告なしはexit 5" t_check_missing_report
test_case "check: doneなしはexit 1" t_check_no_done
test_case "check: BOM付きdone" t_check_bom_done
test_case "check: 完了報告の後にツール実行が続けば無効(exit 5)" t_check_report_then_tool_activity
test_case "check: テンプレートのままの完了報告は無効(exit 5)" t_check_report_placeholder
test_case "check: 必須項目が無い完了報告は無効(exit 5)" t_check_report_missing_field
test_case "check: 箇条書きの値・CRLF・ANSIを含む完了報告は有効" t_check_report_list_value_and_ansi
test_case "check: 権限拒否はexit 6" t_check_permission_denied
test_case "check: 変更0件はexit 7" t_check_no_changes
test_case "check: PR作成のrunは変更0件でも正常" t_check_pr_run_without_changes
test_case "check: state.jsonの変更はexit 8" t_check_state_changed
test_case "check: prompt.mdの削除はexit 8" t_check_prompt_deleted
test_case "check: guard.sha256が無ければexit 8" t_check_guard_missing
test_case "check: output.logの切り詰めはexit 8" t_check_log_truncated
test_case "run+check: 子が正常に完了すればexit 0" t_run_then_check_ok
test_case "run+check: 子がprompt.mdを消せばexit 8" t_run_then_check_child_deletes_prompt
test_case "check: 報告本文の→や$で始まる行は有効" t_check_report_body_symbols
test_case "check: 表示されたソース中の権限拒否の文字列には反応しない" t_check_quoted_permission_text
test_case "check: 色付きの権限拒否行もexit 6" t_check_permission_denied_colored
summary
