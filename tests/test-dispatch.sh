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

t_run_git_state() {
    set_child 'echo hello'
    run_script dispatch-run.sh T1 1
    local expected first lines
    expected="$(git -C "$PROJ" rev-parse HEAD)"
    first="$(head -1 "$PROJ/.agents/workflow/runs/T1-1/git-state.txt")"
    assert_eq "head $expected" "$first" "git-state.txt first line"
    lines="$(wc -l < "$PROJ/.agents/workflow/runs/T1-1/git-state.txt" | tr -d '[:space:]')"
    assert_eq 4 "$lines" "git-state.txt has 4 lines"
}

t_run_git_state_no_exec() {
    set_child 'echo hello'
    chmod -x "$PROJ/.agents/workflow/scripts/git-state.sh"
    run_script dispatch-run.sh T1 1
    local expected first lines
    expected="$(git -C "$PROJ" rev-parse HEAD)"
    first="$(head -1 "$PROJ/.agents/workflow/runs/T1-1/git-state.txt")"
    assert_eq "head $expected" "$first" "git-state.txt first line"
    lines="$(wc -l < "$PROJ/.agents/workflow/runs/T1-1/git-state.txt" | tr -d '[:space:]')"
    assert_eq 4 "$lines" "git-state.txt has 4 lines"
}

t_run_git_state_from_subdir() {
    set_child 'echo hello'
    mkdir -p "$PROJ/sub"
    (cd "$PROJ/sub" && ../.agents/workflow/scripts/dispatch-run.sh T1 1) > /dev/null 2>&1
    local lines
    lines="$(wc -l < "$PROJ/.agents/workflow/runs/T1-1/git-state.txt" | tr -d '[:space:]')"
    assert_eq 4 "$lines" "git-state.txt has 4 lines"
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

# T3(#53): idle_timeout_seconds を設定する($1 = 秒)
set_idle_timeout() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['idle_timeout_seconds'] = int(v)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# T7(#53): 子CLI自身のログファイルのパス(cli_log)を設定する($1 = パス)
set_cli_log() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['cli_log'] = v
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# 子CLIプロファイル(config.json の child_agent.profile)を設定する($1 = プロファイル名)。
# profile は guard.sha256 の対象なので make_run の前に呼ぶ
set_profile() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['profile'] = v
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

# 子を python にする(Windows ネイティブ python から呼ぶ bash は WSL の bash になることがあり、
# その場合は Windows 側の環境変数を引き継がないため)。$1 = child.py の本文(省略時は XDG_DATA_HOME の表示)
set_py_child() {
    set_child ''
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "$PROJ/child.py"
    else
        printf 'import os\nprint("DATA=" + os.environ.get("XDG_DATA_HOME", ""))\n' > "$PROJ/child.py"
    fi
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

# T9(#46): 子の環境変数を NAME=<値>(\ は / に置換)で1行ずつ出力する子
set_env_py_child() {
    set_py_child 'import os
print("TMPDIR=" + os.environ.get("TMPDIR", "").replace("\\", "/"))
print("TEMP=" + os.environ.get("TEMP", "").replace("\\", "/"))
print("TMP=" + os.environ.get("TMP", "").replace("\\", "/"))
print("GIT_CEILING_DIRECTORIES=" + os.environ.get("GIT_CEILING_DIRECTORIES", "").replace("\\", "/"))'
}

# output.log から <変数名>=<値> の行の値を取り出す(CR を除く)
child_env() { # $1 = 変数名
    sed -n "s/^$1=//p" "$PROJ/.agents/workflow/runs/T1-1/output.log" | tr -d '\r'
}

# 値が .agents/workflow/runs/T1-1/tmp で終わる絶対パス(/ または <ドライブ>:/ 始まり)かを確かめる
assert_run_tmp_path() { # $1 = 値, $2 = メッセージ
    case "$1" in
        /*/.agents/workflow/runs/T1-1/tmp|[A-Za-z]:/*/.agents/workflow/runs/T1-1/tmp) _record ok ;;
        *) _record ng "$2 (expected / or drive-letter path ending with .agents/workflow/runs/T1-1/tmp, got '$1')" ;;
    esac
}

# 値が .agents/workflow/runs/T1-1 で終わる絶対パス(/ または <ドライブ>:/ 始まり)かを確かめる(GIT_CEILING_DIRECTORIES 用)
assert_run_run_path() { # $1 = 値, $2 = メッセージ
    case "$1" in
        /*/.agents/workflow/runs/T1-1|[A-Za-z]:/*/.agents/workflow/runs/T1-1) _record ok ;;
        *) _record ng "$2 (expected / or drive-letter path ending with .agents/workflow/runs/T1-1, got '$1')" ;;
    esac
}

# 呼び出し元の TMP 系環境変数を /caller/tmp にして dispatch-run を実行する
run_with_caller_tmp() {
    (
        cd "$PROJ" &&
        TMPDIR=/caller/tmp TEMP=/caller/tmp TMP=/caller/tmp GIT_CEILING_DIRECTORIES=/caller/tmp \
            .agents/workflow/scripts/dispatch-run.sh T1 1
    ) > /dev/null 2>&1
}

t_run_child_tmp_dir() {
    set_env_py_child
    run_with_caller_tmp
    assert_run_tmp_path "$(child_env TMPDIR)" "child TMPDIR points to runs/T1-1/tmp"
    assert_run_tmp_path "$(child_env TEMP)" "child TEMP points to runs/T1-1/tmp"
    assert_run_tmp_path "$(child_env TMP)" "child TMP points to runs/T1-1/tmp"
    if [ -d "$PROJ/.agents/workflow/runs/T1-1/tmp" ]; then _record ok; else _record ng "runs/T1-1/tmp directory exists"; fi
}

t_run_child_git_ceiling() {
    set_env_py_child
    run_with_caller_tmp
    assert_run_run_path "$(child_env GIT_CEILING_DIRECTORIES)" "child GIT_CEILING_DIRECTORIES points to runs/T1-1"
}

# T18: 子が TMPDIR 直下で git rev-parse を実行し、本物のリポジトリが見つからない(returncode 非0)ことを確かめる
t_run_child_git_no_repo() {
    set_py_child 'import os, subprocess
r = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=os.environ["TMPDIR"], capture_output=True)
print("GITRC=" + str(r.returncode))'
    run_with_caller_tmp
    local rc
    rc="$(child_env GITRC)"
    case "$rc" in
        ''|0) _record ng "git under TMPDIR must not find the caller repo (GITRC='$rc')" ;;
        *) _record ok ;;
    esac
}

t_run_caller_tmp_unchanged() {
    set_env_py_child
    local result
    # 呼び出し元のシェル(このサブシェル)の TMPDIR/TEMP/TMP が実行後も書き換わらないことを確かめる
    result="$(
        export TMPDIR=/caller/tmp TEMP=/caller/tmp TMP=/caller/tmp
        cd "$PROJ" || exit 1
        .agents/workflow/scripts/dispatch-run.sh T1 1 > /dev/null 2>&1
        printf 'TMPDIR=%s\nTEMP=%s\nTMP=%s\n' "$TMPDIR" "$TEMP" "$TMP"
    )"
    assert_contains "$result" "TMPDIR=/caller/tmp" "caller TMPDIR unchanged"
    assert_contains "$result" "TEMP=/caller/tmp" "caller TEMP unchanged"
    assert_contains "$result" "TMP=/caller/tmp" "caller TMP unchanged"
}

# T3(#53): ログが idle_timeout_seconds 更新されなければ子を止めて EXIT:idle-timeout
t_run_idle_timeout_kills_child() {
    set_child 'echo start; sleep 30'
    set_idle_timeout 2
    local started elapsed
    started="$SECONDS"
    run_script dispatch-run.sh T1 1
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -lt 20 ]; then _record ok; else _record ng "finished in under 20 seconds (elapsed=$elapsed)"; fi
    assert_eq "EXIT:idle-timeout" "$(done_exit)" "done marker"
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/idle-timeout" "idle-timeout file"
}

# T3(#53): ログが更新され続ければ idle_timeout_seconds で止めない
t_run_idle_timeout_not_triggered() {
    set_child 'for i in 1 2 3 4 5; do echo "tick $i"; sleep 1; done'
    set_idle_timeout 3
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(done_exit)" "done marker"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/output.log")" "tick 5" "output.log"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/idle-timeout" "no idle-timeout file"
}

# command_template を差し替える($1 = テンプレート)
set_template() {
    python3 - "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" <<'PY'
import json, sys
p, v = sys.argv[1:3]
with open(p, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['child_agent']['command_template'] = v
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

t_run_prompt_file_placeholder_passes_long_prompt() {
    set_py_child "import sys
print('LEN=' + str(len(open(sys.argv[1], encoding='utf-8').read())))"
    set_template 'python3 ./child.py "{prompt_file}"'
    python3 -c "open(r'$(py_path "$PROJ/.agents/workflow/runs/T1-1/prompt.md")', 'w', encoding='utf-8', newline='').write('a' * 40000)"
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(done_exit)" "done marker"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/output.log")" "LEN=40000" "prompt_file length"
}

t_run_no_placeholder_passes_prompt_via_stdin() {
    set_py_child "import sys
sys.stdout.write(sys.stdin.read())"
    set_template 'python3 ./child.py'
    printf 'hello-stdin\n' > "$PROJ/.agents/workflow/runs/T1-1/prompt.md"
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(done_exit)" "done marker"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/output.log")" "hello-stdin" "stdin prompt"
}

t_run_profile_stream_json_writes_jsonl_without_template_keyword() {
    set_py_child "print('{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\"}')"
    set_profile claude-stream-json
    run_script dispatch-run.sh T1 1
    assert_file_exists "$PROJ/.agents/workflow/runs/T1-1/output.jsonl" "output.jsonl"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/output.log")" "[result] exit_subtype=success" "result line"
}

t_run_stream_json_large_stdin_does_not_deadlock() {
    set_py_child "import sys
sys.stderr.write('e' * 200000)
sys.stderr.flush()
data = sys.stdin.read()
print('{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"LEN=' + str(len(data)) + '\"}')"
    set_template 'python3 ./child.py'
    set_profile claude-stream-json
    set_idle_timeout 10
    python3 -c "open(r'$(py_path "$PROJ/.agents/workflow/runs/T1-1/prompt.md")', 'w', encoding='utf-8', newline='').write('a' * 200000)"
    run_script dispatch-run.sh T1 1
    assert_eq "EXIT:0" "$(done_exit)" "done marker"
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/output.jsonl")" "LEN=200000" "stdin length"
}

t_run_guard_records_child_profiles() {
    set_child 'echo hello'
    printf '{}\n' > "$PROJ/.agents/workflow/child-profiles.json"
    run_script dispatch-run.sh T1 1
    assert_contains "$(cat "$PROJ/.agents/workflow/runs/T1-1/guard.sha256")" ".agents/workflow/child-profiles.json" "guard has child-profiles.json"
}

# ---------- dispatch-check ----------

# dispatch-run と同じ形式で guard.sha256 を書き(runs/<run>/prompt.md と管理ファイル)、
# dispatch-run と同じく git-state.sh の出力で git-state.txt も書く
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
    (cd "$PROJ" && .agents/workflow/scripts/git-state.sh) > "$PROJ/.agents/workflow/runs/$run/git-state.txt"
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
    assert_eq "Next: review T1" "${OUT##*$'\n'}" "next line"
}

t_check_signal() {
    make_run "signal:15" "step 67 ..."
    run_script dispatch-check.sh T1 1
    assert_eq 4 "$CODE" "exit code"
    assert_contains "$OUT" "kind: signal" "kind"
    assert_contains "$OUT" "step 67" "log tail shown"
    assert_eq "Next: escalate reason=abnormal-exit" "${OUT##*$'\n'}" "next line"
}

t_check_idle_timeout() {
    make_run idle-timeout "> build · glm-5.3"
    run_script dispatch-check.sh T1 1
    assert_eq 4 "$CODE" "exit code"
    assert_contains "$OUT" "kind: idle-timeout" "kind"
    assert_contains "$OUT" "Verdict: abnormal-exit" "verdict"
    assert_eq "Next: escalate reason=idle-timeout" "${OUT##*$'\n'}" "next line"
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
    assert_eq "Next: escalate reason=no-report" "${OUT##*$'\n'}" "next line"
}

t_check_missing_report_no_output_after_tool() {
    # #50: 最後のツール実行の後に何も出力していない(推論だけで出力トークン上限に達した)場合の理由
    make_run 0 "> build · glm-5.3

${ESC}[0m→ ${ESC}[0mRead a.txt
${ESC}[0m→ ${ESC}[0mRead b.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "no output after the last tool call" "reason"
    assert_eq "Next: escalate reason=token-limit" "${OUT##*$'\n'}" "next line"
}

t_check_missing_report_body_after_tool() {
    # ツール実行の後に本文があれば、理由を付けない(単なる報告漏れとして扱う)
    make_run 0 "${ESC}[0m→ ${ESC}[0mRead a.txt
考え中です"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Completion report: missing" "report missing"
    assert_not_contains "$OUT" "no output after the last tool call" "reason absent"
}

t_check_no_done() {
    mkdir -p "$PROJ/.agents/workflow/runs/T1-1"
    run_script dispatch-check.sh T1 1
    assert_eq 2 "$CODE" "exit code"
    assert_eq "Next: wait" "$OUT" "next line"
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

t_check_report_fullwidth_required_fields() {
    make_run 0 $'## 完了報告\n- 変更ファイル：\n  - a.txt\n- テストコマンド: bash tests/test.sh\n- テスト結果： 全件パス'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Completion report: found" "report"
}

t_check_report_fullwidth_pr_url() {
    make_run 0 $'## 完了報告\n- PR URL： https://github.com/o/r/pull/1' pr-1-1
    run_script dispatch-check.sh pr-1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Completion report: found" "report"
}

# T11: 有効な完了報告(CODE 0・7)なら最後の `## 完了報告` ブロックを report.md に保存する
t_check_report_saved() {
    make_run 0 $'作業ログ\n## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス\n\n## 備考の後'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "$(printf '## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス')" \
        "$(cat "$PROJ/.agents/workflow/runs/T1-1/report.md")" "report.md content"
    assert_eq "$(printf '## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス\n' | wc -c | tr -d ' ')" \
        "$(wc -c < "$PROJ/.agents/workflow/runs/T1-1/report.md" | tr -d ' ')" "report.md has 3 lines + one trailing newline"
    assert_contains "$OUT" "Report: .agents/workflow/runs/T1-1/report.md" "report path line"
}

# T11: report.md が既にあれば上書きしない
t_check_report_existing_kept() {
    make_run 0 $'作業ログ\n## 完了報告\n- 変更ファイル: a.txt\n- テスト結果: 全件パス\n\n## 備考の後'
    printf 'x\n' > "$PROJ/a.txt"
    printf 'old\n' > "$PROJ/.agents/workflow/runs/T1-1/report.md"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $ERR"
    assert_eq "old" "$(cat "$PROJ/.agents/workflow/runs/T1-1/report.md")" "existing report.md kept"
    assert_contains "$OUT" "Report: .agents/workflow/runs/T1-1/report.md" "report path line"
}

# T11: 完了報告が無効(CODE 5)なら report.md を作らず Report: 行も出さない
t_check_report_invalid_not_saved() {
    make_run 0 $'## 完了報告\n- 変更ファイル: <一覧>'
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 5 "$CODE" "exit code: $ERR"
    assert_file_absent "$PROJ/.agents/workflow/runs/T1-1/report.md" "no report.md"
    assert_not_contains "$OUT" "Report:" "no Report: line"
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
    assert_eq "Next: escalate reason=permission-denied" "${OUT##*$'\n'}" "next line"
}

t_check_profile_default() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Profile: auto" "profile"
    assert_contains "$OUT" "Disabled checks: none" "disabled checks"
}

t_check_profile_plain() {
    set_profile plain
    make_run 0 "! permission requested: x; auto-rejecting
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Disabled checks: permission-denied, outside-access, tool-activity, provider-error" "disabled checks"
    assert_contains "$OUT" "Permission denied: disabled (profile: plain)" "permission denied"
    assert_contains "$OUT" "Outside access: disabled (profile: plain)" "outside access"
    assert_contains "$OUT" "Provider error: disabled (profile: plain)" "provider error"
}

t_check_profile_stream_json() {
    set_profile claude-stream-json
    make_run 0 "$REPORT
${ESC}[0m\$ ${ESC}[0mcat /tmp/x"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "opencode marker line is ignored: $OUT"
    make_run 0 "$REPORT
[tool_use] bash: {\"command\": \"cat /tmp/x\"}"
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "tool_use line detected: $OUT"
    assert_eq "Next: escalate reason=outside-access" "${OUT##*$'\n'}" "next line"
}

t_check_profile_custom() {
    printf '%s\n' '{"mycli": {"output_format": "text", "permission_denied_pattern": "^DENIED: "}}' \
        > "$PROJ/.agents/workflow/child-profiles.json"
    set_profile mycli
    make_run 0 "DENIED: rm -rf x
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_eq "Next: escalate reason=permission-denied" "${OUT##*$'\n'}" "next line"
}

t_check_profile_unknown() {
    set_profile nope
    make_run 0 "$REPORT"
    run_script dispatch-check.sh T1 1
    assert_eq 1 "$CODE" "exit code: $OUT"
    assert_not_contains "$OUT" "Next:" "no Next line"
}

t_check_no_changes() {
    make_run 0 "$REPORT"
    run_script dispatch-check.sh T1 1
    assert_eq 7 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Changes: 0" "changes"
    assert_eq "Next: escalate reason=no-changes" "${OUT##*$'\n'}" "next line"
}

t_check_pr_run_without_changes() {
    make_run 0 $'## 完了報告\n- PR URL: https://github.com/o/r/pull/1\n- タイトル: t' pr-1-1
    run_script dispatch-check.sh pr-1 1
    assert_eq 0 "$CODE" "pr run is not checked for changes: $OUT"
    assert_eq "Next: wait-merge" "${OUT##*$'\n'}" "pr run is not reviewed"
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
    assert_eq "Next: escalate reason=tampered" "${OUT##*$'\n'}" "next line"
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

t_check_git_state_missing() {
    make_run 0 "$REPORT"
    rm "$PROJ/.agents/workflow/runs/T1-1/git-state.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Guard: NG" "guard ng"
    assert_contains "$OUT" "git-state.txt not found" "issue"
}

t_check_git_state_no_exec() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    chmod -x "$PROJ/.agents/workflow/scripts/git-state.sh"
    (cd "$PROJ" && git commit --allow-empty -q -m x)
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "git changed: head" "issue"
}

t_check_log_truncated() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    printf '\0\0\0%s\n' "$REPORT" > "$PROJ/.agents/workflow/runs/T1-1/output.log"
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "truncated during the run" "issue"
}

# #44: 切り詰められた output.log の末尾表示から NUL・CR を除く(stdout に NUL を流さない)
t_check_log_truncated_display_no_nul() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    printf '\0\0\0%s\n' "$REPORT" > "$PROJ/.agents/workflow/runs/T1-1/output.log"
    local nul_count
    assert_contains "$( (cd "$PROJ" && .agents/workflow/scripts/dispatch-check.sh T1 1 2>/dev/null) )" \
        "- テスト結果: 全件パス" "report body shown"
    nul_count="$( (cd "$PROJ" && .agents/workflow/scripts/dispatch-check.sh T1 1 2>/dev/null) \
        | LC_ALL=C tr -dc '\000' | wc -c | tr -d ' \n')"
    assert_eq 0 "$nul_count" "no NUL bytes in stdout"
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

# git を実行する子を python にする(Windows で bash が WSL の bash に解決される場合があるため、
# 既存の set_py_child と同じ python の子にする)。$1 = child.py の本文
set_git_py_child() {
    set_child ''
    printf '%s\n' "$1" > "$PROJ/child.py"
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

# T7: 子が本物のリポジトリの git 状態(HEAD・ブランチ・参照・設定)を変えれば exit 8
t_run_then_check_child_commits() {
    set_git_py_child 'import subprocess; subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "x"])'
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Guard: NG" "guard ng"
    assert_contains "$OUT" "git changed: head" "issue"
}

t_run_then_check_child_changes_config() {
    set_git_py_child 'import subprocess; subprocess.run(["git", "config", "user.name", "x"])'
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Guard: NG" "guard ng"
    assert_contains "$OUT" "git changed: config" "issue"
}

t_run_then_check_child_creates_branch() {
    set_git_py_child 'import subprocess; subprocess.run(["git", "branch", "x"])'
    run_script dispatch-run.sh T1 1
    run_script dispatch-check.sh T1 1
    assert_eq 8 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Guard: NG" "guard ng"
    assert_contains "$OUT" "git changed: refs" "issue"
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

# T12: 権限を拒否されずに成功したプロジェクト外(/tmp 等)へのアクセスを検出する(exit 6)
t_check_outside_access_tmp_write() {
    make_run 0 "$REPORT
${ESC}[0m\$ ${ESC}[0mbash -c \"bash tests/x.sh > /tmp/dsp-sh.log\""
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Verdict: outside-access" "verdict"
    assert_contains "$OUT" "Outside access: yes" "flag"
    assert_contains "$OUT" "/tmp/dsp-sh.log" "line shown"
    assert_eq "Next: escalate reason=outside-access" "${OUT##*$'\n'}" "next line"
}

t_check_outside_access_runs_tmp_ok() {
    make_run 0 "${ESC}[0m\$ ${ESC}[0mbash tests/x.sh > .agents/workflow/runs/T1-1/tmp/out.log
${ESC}[0m\$ ${ESC}[0mecho \$TMPDIR
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Outside access: no" "flag"
}

t_check_outside_access_tool_output_ignored() {
    make_run 0 "PROJ=/tmp/tmp.abc
[tool_result] /tmp/x
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Outside access: no" "flag"
}

t_check_outside_access_with_permission_denied() {
    make_run 0 "! permission requested: external_directory (/tmp/*); auto-rejecting
${ESC}[0m\$ ${ESC}[0mbash -c \"bash tests/x.sh > /tmp/dsp-sh.log\""
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Verdict: permission-denied" "verdict"
    assert_contains "$OUT" "Permission denied: yes" "flag"
    assert_contains "$OUT" "Outside access: yes" "flag"
}

t_check_outside_access_tmp_uppercase_ok() {
    # /tmp の参照は大文字小文字を区別する(/TMP は検出しない)
    make_run 0 "${ESC}[0m\$ ${ESC}[0mls /TMP/x
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Outside access: no" "flag"
}

t_check_outside_access_home_redirect() {
    # リダイレクト(`>`)の直後の ~/ もホームディレクトリの参照とみなす
    make_run 0 "$REPORT
${ESC}[0m\$ ${ESC}[0mbash tests/x.sh >~/out.log"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Verdict: outside-access" "verdict"
    assert_contains "$OUT" "~/out.log" "line shown"
}

# T14: ホームディレクトリ・AppData の Temp への参照も検出する(exit 6)
t_check_outside_access_tool_use_home() {
    make_run 0 "$REPORT
[tool_use] bash: {\"command\": \"cat ~/x.log\"}"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Verdict: outside-access" "verdict"
    assert_contains "$OUT" "Outside access: yes" "flag"
    assert_contains "$OUT" "~/x.log" "line shown"
}

t_check_outside_access_userprofile_temp() {
    make_run 0 "${ESC}[0m\$ ${ESC}[0mGet-Content \$env:USERPROFILE\\x.log
$REPORT" T1-2
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 2
    assert_eq 6 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Verdict: outside-access" "verdict"
    assert_contains "$OUT" "Outside access: yes" "flag"
    make_run 0 "${ESC}[0m\$ ${ESC}[0mls C:\\Users\\u\\AppData\\Local\\Temp
$REPORT" T1-3
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 3
    assert_eq 6 "$CODE" "exit code: $OUT (appdata temp)"
    assert_contains "$OUT" "Verdict: outside-access" "verdict (appdata temp)"
    assert_contains "$OUT" "Outside access: yes" "flag (appdata temp)"
}

t_check_outside_access_home_not_detected() {
    make_run 0 "${ESC}[0m\$ ${ESC}[0mecho \$HOMEBREW_PREFIX
${ESC}[0m\$ ${ESC}[0mGet-ChildItem \$env:TEMP
$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Outside access: no" "flag"
}

# T7(#53): 子CLIのログの利用上限エラーを Provider error: yes にする
# (cli_log は guard.sha256 の対象なので make_run の前に設定する)
t_check_cli_log_provider_error() {
    set_cli_log "$(py_path "$PROJ/cli.log")"
    printf 'timestamp=2026-10-17T03:07:49.892Z level=INFO message="ok"\n' > "$PROJ/cli.log"
    printf 'timestamp=2026-10-17T03:07:50.429Z level=ERROR message="stream error" error.error="AI_APICallError: Go usage limit exceeded"\n' >> "$PROJ/cli.log"
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Go usage limit exceeded" "error line shown"
    assert_contains "$OUT" "Provider error: yes" "provider flag"
    assert_not_contains "$OUT" "level=INFO" "info line not shown"
}

# T47(#74): 利用上限エラーのログで子が異常終了(非0)すれば provider-error で exit 4
t_check_cli_log_provider_error_exit4() {
    set_cli_log "$(py_path "$PROJ/cli.log")"
    printf 'timestamp=2026-10-17T03:07:49.892Z level=INFO message="ok"\n' > "$PROJ/cli.log"
    printf 'timestamp=2026-10-17T03:07:50.429Z level=ERROR message="stream error" error.error="AI_APICallError: Go usage limit exceeded"\n' >> "$PROJ/cli.log"
    make_run 3 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 4 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "Provider error: yes" "provider flag"
    assert_eq "Next: escalate reason=provider-error" "${OUT##*$'\n'}" "next line"
}

# T7(#53): 子CLIのログの ERROR がプロバイダー由来でなければ Provider error: no
t_check_cli_log_error_not_provider() {
    set_cli_log "$(py_path "$PROJ/cli.log")"
    printf 'timestamp=2026-10-17T03:07:50.429Z level=ERROR message="tool failed"\n' > "$PROJ/cli.log"
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" 'message="tool failed"' "error line shown"
    assert_contains "$OUT" "Provider error: no" "provider flag"
}

# T7(#53): cli_log が未設定なら CLI log: (not configured)
t_check_cli_log_not_configured() {
    make_run 0 "$REPORT"
    printf 'x\n' > "$PROJ/a.txt"
    run_script dispatch-check.sh T1 1
    assert_eq 0 "$CODE" "exit code: $OUT"
    assert_contains "$OUT" "CLI log: (not configured)" "not configured"
    assert_contains "$OUT" "Provider error: unknown" "provider flag"
}

echo "test-dispatch.sh"

test_case "run: 正常終了はEXIT:0" t_run_exit0
test_case "run: 起動時の git 状態を git-state.txt に記録する" t_run_git_state
test_case "run: git-state.sh に実行権限が無くても git-state.txt を4行で書く" t_run_git_state_no_exec
test_case "run: プロジェクトルート以外から相対パスで起動しても git-state.txt を書く" t_run_git_state_from_subdir
test_case "run: 通常の非0は数値のまま" t_run_exit_nonzero
test_case "run: SIGTERMはsignal:15(python経路)" t_run_signal_python
test_case "run: SIGTERMはsignal:15(フォールバック経路)" t_run_signal_fallback
test_case "run: 通常の非0は数値のまま(フォールバック経路)" t_run_exit_fallback
test_case "run: isolate_xdg 未指定/false は XDG を引き継ぐ" t_run_xdg_inherited_by_default
test_case "run: isolate_xdg true は XDG を切り替える" t_run_xdg_isolated
test_case "run: 子の TMPDIR/TEMP/TMP は runs/<ID>-<試行>/tmp を指す" t_run_child_tmp_dir
test_case "run: 子の GIT_CEILING_DIRECTORIES は runs/<ID>-<試行> を指す" t_run_child_git_ceiling
test_case "run: 子が TMPDIR 直下で実行した git は本物のリポジトリを見つけない" t_run_child_git_no_repo
test_case "run: 呼び出し元の TMPDIR/TEMP/TMP を書き換えない" t_run_caller_tmp_unchanged
test_case "run: ログが idle_timeout_seconds 更新されなければ子を止めて EXIT:idle-timeout" t_run_idle_timeout_kills_child
test_case "run: ログが更新され続ければ idle_timeout_seconds で止めない" t_run_idle_timeout_not_triggered
test_case "run: {prompt_file} で 40000 文字のプロンプトをファイルパスで渡す" t_run_prompt_file_placeholder_passes_long_prompt
test_case "run: プレースホルダが無いテンプレートは stdin でプロンプトを渡す" t_run_no_placeholder_passes_prompt_via_stdin
test_case "run: profile claude-stream-json は command_template に stream-json が無くても output.jsonl を書く" t_run_profile_stream_json_writes_jsonl_without_template_keyword
test_case "run: stream-json で stdin に大きいプロンプトを渡しても、子が先に stderr に大量に書くと止まらない" t_run_stream_json_large_stdin_does_not_deadlock
test_case "run: 利用先の child-profiles.json を guard.sha256 に記録する" t_run_guard_records_child_profiles
test_case "check: 正常" t_check_ok
test_case "check: signalはexit 4" t_check_signal
test_case "check: EXIT:idle-timeout は abnormal-exit(exit 4)" t_check_idle_timeout
test_case "check: 非0はexit 4" t_check_nonzero
test_case "check: crashedはexit 4" t_check_crashed
test_case "check: 完了報告なしはexit 5" t_check_missing_report
test_case "check: 最後のツール実行の後に出力が無ければ理由に書く(exit 5)" t_check_missing_report_no_output_after_tool
test_case "check: ツール実行の後に本文があれば理由を付けない(exit 5)" t_check_missing_report_body_after_tool
test_case "check: doneなしはexit 2" t_check_no_done
test_case "check: BOM付きdone" t_check_bom_done
test_case "check: 完了報告の後にツール実行が続けば無効(exit 5)" t_check_report_then_tool_activity
test_case "check: テンプレートのままの完了報告は無効(exit 5)" t_check_report_placeholder
test_case "check: 必須項目が無い完了報告は無効(exit 5)" t_check_report_missing_field
test_case "check: 全角コロンの必須項目も有効(exit 0)" t_check_report_fullwidth_required_fields
test_case "check: 全角コロンのPR URLも有効(exit 0)" t_check_report_fullwidth_pr_url
test_case "check: 有効な完了報告を report.md に保存する" t_check_report_saved
test_case "check: report.md が既にあれば上書きしない" t_check_report_existing_kept
test_case "check: 完了報告が無効なら report.md を作らない" t_check_report_invalid_not_saved
test_case "check: 箇条書きの値・CRLF・ANSIを含む完了報告は有効" t_check_report_list_value_and_ansi
test_case "check: 権限拒否はexit 6" t_check_permission_denied
test_case "check: profile 未指定は Profile: auto と Disabled checks: none を出す" t_check_profile_default
test_case "check: plain は検知できない検査を disabled と出し、権限拒否の行があっても ok" t_check_profile_plain
test_case "check: claude-stream-json は opencode のマーカー行を見ず [tool_use] 行でプロジェクト外アクセスを検出する" t_check_profile_stream_json
test_case "check: 利用先の child-profiles.json の権限拒否パターンで exit 6" t_check_profile_custom
test_case "check: 未定義の profile は exit 1" t_check_profile_unknown
test_case "check: 変更0件はexit 7" t_check_no_changes
test_case "check: PR作成のrunは変更0件でも正常" t_check_pr_run_without_changes
test_case "check: state.jsonの変更はexit 8" t_check_state_changed
test_case "check: prompt.mdの削除はexit 8" t_check_prompt_deleted
test_case "check: guard.sha256が無ければexit 8" t_check_guard_missing
test_case "check: git-state.txt が無ければ exit 8" t_check_git_state_missing
test_case "check: git-state.sh に実行権限が無くても git 状態の変化を検出する" t_check_git_state_no_exec
test_case "check: output.logの切り詰めはexit 8" t_check_log_truncated
test_case "check: 切り詰められたoutput.logの表示にNULを含めない" t_check_log_truncated_display_no_nul
test_case "run+check: 子が正常に完了すればexit 0" t_run_then_check_ok
test_case "run+check: 子がprompt.mdを消せばexit 8" t_run_then_check_child_deletes_prompt
test_case "run+check: 子がコミットすれば exit 8(git changed: head)" t_run_then_check_child_commits
test_case "run+check: 子が git config を変えれば exit 8(git changed: config)" t_run_then_check_child_changes_config
test_case "run+check: 子がブランチを作れば exit 8(git changed: refs)" t_run_then_check_child_creates_branch
test_case "check: 報告本文の→や$で始まる行は有効" t_check_report_body_symbols
test_case "check: 表示されたソース中の権限拒否の文字列には反応しない" t_check_quoted_permission_text
test_case "check: 色付きの権限拒否行もexit 6" t_check_permission_denied_colored
test_case "check: ツール実行行の /tmp への書き込みは exit 6(outside-access)" t_check_outside_access_tmp_write
test_case "check: runs/<ID>/tmp 配下へのアクセスは検出しない" t_check_outside_access_runs_tmp_ok
test_case "check: ツールの出力中の /tmp には反応しない" t_check_outside_access_tool_output_ignored
test_case "check: 権限拒否とプロジェクト外アクセスが両方あれば permission-denied" t_check_outside_access_with_permission_denied
test_case "check: 大文字の /TMP は検出しない" t_check_outside_access_tmp_uppercase_ok
test_case "check: リダイレクト直後の ~/ は exit 6" t_check_outside_access_home_redirect
test_case "check: tool_use 行のホームディレクトリ参照は exit 6" t_check_outside_access_tool_use_home
test_case "check: 色付きツール実行行の USERPROFILE・AppData の Temp 参照は exit 6" t_check_outside_access_userprofile_temp
test_case "check: HOMEBREW_PREFIX や env:TEMP は検出しない" t_check_outside_access_home_not_detected
test_case "check: CLI ログの利用上限エラーを Provider error: yes にする" t_check_cli_log_provider_error
test_case "check: CLI ログの利用上限エラーで異常終了なら provider-error" t_check_cli_log_provider_error_exit4
test_case "check: CLI ログの ERROR がプロバイダー由来でなければ Provider error: no" t_check_cli_log_error_not_provider
test_case "check: cli_log が未設定なら CLI log: (not configured)" t_check_cli_log_not_configured
summary
