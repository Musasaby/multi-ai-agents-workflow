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
        for cmd in bash sh dirname mkdir rm sed cat date head; do
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

make_run() { # $1 = EXIT 値, $2 = output.log の内容
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    printf 'EXIT:%s\nEND:2026-01-01T00:00:00+09:00\n' "$1" > "$PROJ/.agents/workflow/runs/T1-1/done"
    printf '%s\n' "$2" > "$PROJ/.agents/workflow/runs/T1-1/output.log"
}

REPORT=$'作業しました\n## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス'

t_check_ok() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_contains "$OUT" "kind: ok" "kind"
    assert_contains "$OUT" "a.txt" "git status shown"
    assert_contains "$OUT" "Completion report: found" "report found"
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
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "BOM-prefixed done marker (Windows PowerShell) parsed: $OUT"
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
summary
