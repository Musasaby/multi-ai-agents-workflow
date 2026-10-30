#!/bin/bash
TASK_ID="${1:?TaskId required}"
ATTEMPT="${2:-1}"
# パスや埋め込みコードに使うため、タスクIDと試行回数の形式を検証する
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]]; then
  echo "Invalid TaskId/Attempt: '$TASK_ID' '$ATTEMPT'" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
# child_agent.isolate_xdg が true のときだけ、子CLIの設定・データの置き場所をプロジェクト内に切り替える
# (sandbox で ~/.config 等に書けない環境向け)。既定(未指定・false)は呼び出し元の XDG をそのまま使う。
# 切り替えると ~/.local/share/<CLI>/auth.json 等の認証情報が見えなくなる点に注意。
ISOLATE_XDG=false
if command -v python3 > /dev/null 2>&1; then
  ISOLATE_XDG=$(python3 -c "import json; print(str(bool(json.load(open('.agents/workflow/config.json', encoding='utf-8'))['child_agent'].get('isolate_xdg', False))).lower())" 2>/dev/null | tr -d '\r')
elif grep -Eq '"isolate_xdg"[[:space:]]*:[[:space:]]*true' .agents/workflow/config.json; then
  ISOLATE_XDG=true
fi
if [ "$ISOLATE_XDG" = true ]; then
  export XDG_CONFIG_HOME=".agents/workflow/.config"
  export XDG_DATA_HOME=".agents/workflow/.config"
fi
RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
mkdir -p "$RUN_DIR"
# 子の一時ファイルをプロジェクト内(runs/<ID>-<試行>/tmp/)に置かせ、そこで実行された git が
# 本物のリポジトリにたどり着かないようにする(#46)。git は ceiling と同じディレクトリが
# カレントのときは探索を止めないため、tmp/ の親(runs/<ID>-<試行>/)を上限にする
# worktree.txt があるとき(dispatch-worktree create 済み)は、子を worktree の中で動かす。
# 出力ファイル(output.log・done 等)は本体の runs/ に置いたまま、tmp と ceiling だけ worktree 側にする
WT_PATH=""
WT_BRANCH=""
if [ -f "$RUN_DIR/worktree.txt" ]; then
  WT_PATH="$(sed -n 's/^path //p' "$RUN_DIR/worktree.txt" | head -n 1 | tr -d '\r')"
  WT_BRANCH="$(sed -n 's/^branch //p' "$RUN_DIR/worktree.txt" | head -n 1 | tr -d '\r')"
fi
if [ -n "$WT_PATH" ]; then
  CHILD_BASE="$WT_PATH/$RUN_DIR"
  # cwd が変わるので、相対パスの XDG は本体の絶対パスにする
  if [ "$ISOLATE_XDG" = true ]; then
    export XDG_CONFIG_HOME="$(pwd)/.agents/workflow/.config" XDG_DATA_HOME="$(pwd)/.agents/workflow/.config"
  fi
else
  CHILD_BASE="$(pwd)/$RUN_DIR"
fi
CHILD_TMP="$CHILD_BASE/tmp"
mkdir -p "$CHILD_TMP"
CHILD_CEILING="$CHILD_BASE"
# Windows ネイティブの子プロセスは /c/... 形式を解釈できないため C:/... 形式にする
if command -v cygpath > /dev/null 2>&1; then
  CHILD_TMP="$(cygpath -m "$CHILD_TMP")"
  CHILD_CEILING="$(cygpath -m "$CHILD_CEILING")"
fi
export TMPDIR="$CHILD_TMP" TEMP="$CHILD_TMP" TMP="$CHILD_TMP" GIT_CEILING_DIRECTORIES="$CHILD_CEILING"
LOG_PATH="$RUN_DIR/output.log"
JSONL_PATH="$RUN_DIR/output.jsonl"
DONE_PATH="$RUN_DIR/done"
# 子がシグナルで終了した場合に Python ラッパーがシグナル番号を書き出すファイル
SIGNAL_PATH="$RUN_DIR/exit-signal"
# ログが idle_timeout_seconds 更新されず子を止めたときに記録するファイル(#53)
IDLE_PATH="$RUN_DIR/idle-timeout"
rm -f "$DONE_PATH" "$SIGNAL_PATH" "$IDLE_PATH"
PROMPT_PATH="$RUN_DIR/prompt.md"

# 子が管理ファイルを変更・削除していないかを dispatch-check が確かめられるよう、起動時の
# SHA-256 を記録する(存在しないファイルは "-")。形式は sha256sum と同じ "<hash>  <path>"
GUARD_PATH="$RUN_DIR/guard.sha256"
: > "$GUARD_PATH"
GUARD_STATE=.agents/workflow/state.json
GUARD_TASKS=.agents/workflow/tasks.md
if [ -n "$WT_PATH" ]; then
  # worktree の run では、子が触れる worktree 側のコピーを守る
  GUARD_STATE="$RUN_DIR/worktree/.agents/workflow/state.json"
  GUARD_TASKS="$RUN_DIR/worktree/.agents/workflow/tasks.md"
fi
for f in "$PROMPT_PATH" "$GUARD_STATE" "$GUARD_TASKS" .agents/workflow/config.json .agents/workflow/child-profiles.json; do
  if [ ! -f "$f" ]; then
    h=-
  elif command -v sha256sum > /dev/null 2>&1; then
    h=$(sha256sum "$f" | cut -d' ' -f1)
  else
    h=$(shasum -a 256 "$f" | cut -d' ' -f1)
  fi
  printf '%s  %s\n' "$h" "$f" >> "$GUARD_PATH"
done

# 起動時の git 状態(HEAD・ブランチ・参照・設定)を git-state.txt に記録する。dispatch-check が
# 実行後の状態と比べて、子がリポジトリのどこを変えたかを特定する(失敗しても起動は止めない)。
# 実行権限に頼らず bash で呼ぶ(リポジトリ上のスクリプトは mode 100644 のため)
if [ -n "$WT_PATH" ]; then
  # 親の作業ブランチは本体で取る(detached なら "-")
  PARENT_REF="$(git symbolic-ref -q HEAD 2> /dev/null || true)"
  [ -n "$PARENT_REF" ] || PARENT_REF=-
  (cd "$WT_PATH" && bash "$SCRIPT_DIR/git-state.sh" --run "$WT_BRANCH" --parent "$PARENT_REF") > "$RUN_DIR/git-state.txt"
else
  bash "$SCRIPT_DIR/git-state.sh" > "$RUN_DIR/git-state.txt"
fi

CMD_TEMPLATE=$(jq -r '.child_agent.command_template' .agents/workflow/config.json 2>/dev/null || \
  python3 -c "import json; print(json.load(open('.agents/workflow/config.json'))['child_agent']['command_template'])" 2>/dev/null || \
  sed -n 's/.*"command_template"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' .agents/workflow/config.json | sed 's/\\"/"/g')

SCRIPT_DIR_PY="$SCRIPT_DIR"
if command -v cygpath > /dev/null 2>&1; then
  SCRIPT_DIR_PY="$(cygpath -m "$SCRIPT_DIR")"
fi

if command -v python3 > /dev/null 2>&1; then
  WT_PATH="$WT_PATH" python3 -c "
import json, subprocess, sys, shlex, os, threading, time, signal
sys.dont_write_bytecode = True
sys.path.insert(0, '$SCRIPT_DIR_PY')
import childprofile

with open('.agents/workflow/config.json', encoding='utf-8') as f:
    cfg = json.load(f)['child_agent']
tmpl = cfg['command_template']
# ログの無更新監視のしきい値。未指定・0 以下は無効(#53)
idle_timeout = float(cfg.get('idle_timeout_seconds') or 0)
with open('$PROMPT_PATH', encoding='utf-8') as f:
    prompt = f.read()
prompt_file = os.path.abspath('$PROMPT_PATH').replace(os.sep, '/')
tokens = shlex.split(tmpl)
tokens = [t.replace('{prompt_file}', prompt_file).replace('{prompt}', prompt) for t in tokens]
# {prompt_file}・{prompt} のどちらも無いテンプレートは、プロンプトを stdin で渡す
use_stdin = '{prompt_file}' not in tmpl and '{prompt}' not in tmpl

log_path = '$LOG_PATH'
signal_path = '$SIGNAL_PATH'

def finish(returncode):
    # シグナルで終了した子は負の returncode になる。sys.exit(-15) は 8bit に切り詰められ
    # 241 になり「241 で正常終了」と区別できないため、シグナル番号を別ファイルに記録する
    if returncode < 0:
        with open(signal_path, 'w', encoding='utf-8') as sf:
            sf.write(str(-returncode))
        sys.exit(128 - returncode)
    sys.exit(returncode)

idle_path = '$IDLE_PATH'

def start_watchdog(proc):
    # ログ(output.log)が idle_timeout 秒更新されなければ子を止め、idle-timeout ファイルに記録する(#53)
    if idle_timeout <= 0:
        return
    start = time.time()
    def watch():
        while proc.poll() is None:
            time.sleep(1)
            try:
                last = max(start, os.path.getmtime(log_path))
            except OSError:
                last = start
            if time.time() - last >= idle_timeout and proc.poll() is None:
                with open(idle_path, 'w', encoding='utf-8') as f:
                    f.write(str(int(idle_timeout)))
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/T', '/F', '/PID', str(proc.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    os.killpg(proc.pid, signal.SIGKILL)
                return
    threading.Thread(target=watch, daemon=True).start()

try:
    prof = childprofile.load_profile('.')
except childprofile.ProfileError as e:
    with open(log_path, 'w', encoding='utf-8') as lf:
        lf.write('Child profile error: ' + str(e) + '\n')
    finish(1)

is_stream = prof['output_format'] == 'claude-stream-json'

def feed_stdin(proc):
    # プロンプトを UTF-8 のバイト列で stdin に書いて閉じる(text モードでも buffer 経由で改行変換を避ける)
    def write():
        try:
            stream = getattr(proc.stdin, 'buffer', proc.stdin)
            stream.write(prompt.encode('utf-8'))
            stream.flush()
        except (OSError, ValueError):
            pass
        finally:
            try:
                proc.stdin.close()
            except (OSError, ValueError):
                pass
    threading.Thread(target=write, daemon=True).start()

stdin_mode = subprocess.PIPE if use_stdin else subprocess.DEVNULL
# worktree の run では子の作業ディレクトリを worktree にする(未指定なら今の cwd のまま)
child_cwd = os.environ.get('WT_PATH') or None

if is_stream:
    jsonl_path = '$JSONL_PATH'

    # ファイル編集ツールの本文(書き込む内容)は [tool_use] 行から外す。本文に書かれたパスの文字列を
    # dispatch-check が誤検知するため。全文は output.jsonl に残る
    FILE_EDIT_TOOLS = ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
    FILE_EDIT_BODY_KEYS = ('old_string', 'new_string', 'content', 'edits', 'new_source')

    def human_line(obj):
        t = obj.get('type')
        if t == 'assistant':
            lines = []
            for block in (obj.get('message') or {}).get('content') or []:
                bt = block.get('type')
                if bt == 'text':
                    lines.append(block.get('text', ''))
                elif bt == 'tool_use':
                    tool_input = block.get('input', {})
                    if block.get('name') in FILE_EDIT_TOOLS and isinstance(tool_input, dict):
                        tool_input = {k: v for k, v in tool_input.items() if k not in FILE_EDIT_BODY_KEYS}
                    inp = json.dumps(tool_input, ensure_ascii=False)
                    if len(inp) > 300:
                        inp = inp[:300] + '...(truncated)'
                    lines.append('[tool_use] ' + str(block.get('name')) + ': ' + inp)
                else:
                    lines.append('[assistant:' + str(bt) + ']')
            return '\n'.join(lines)
        if t == 'user':
            lines = []
            for block in (obj.get('message') or {}).get('content') or []:
                if block.get('type') == 'tool_result':
                    content = block.get('content')
                    if isinstance(content, list):
                        text = '\n'.join(c.get('text', '') for c in content if isinstance(c, dict))
                    else:
                        text = str(content)
                    if len(text) > 300:
                        text = text[:300] + '...(truncated)'
                    lines.append('[tool_result] ' + text)
            return '\n'.join(lines)
        if t == 'result':
            return '[result] exit_subtype=' + str(obj.get('subtype')) + ' result=' + str(obj.get('result'))
        compact = json.dumps(obj, ensure_ascii=False)
        if len(compact) > 300:
            compact = compact[:300] + '...(truncated)'
        return '[' + str(t) + '] ' + compact

    with open(jsonl_path, 'w', encoding='utf-8') as jf, open(log_path, 'w', encoding='utf-8') as lf:
        proc = subprocess.Popen(tokens, stdin=stdin_mode, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', bufsize=1, cwd=child_cwd, start_new_session=(os.name != 'nt'))
        if use_stdin:
            feed_stdin(proc)
        start_watchdog(proc)
        for line in proc.stdout:
            line = line.rstrip('\n')
            jf.write(line + '\n')
            jf.flush()
            try:
                obj = json.loads(line)
                human = human_line(obj)
            except Exception:
                human = line
            if human:
                lf.write(human + '\n')
                lf.flush()
        proc.wait()
        finish(proc.returncode)
else:
    with open(log_path, 'w', encoding='utf-8') as lf:
        proc = subprocess.Popen(tokens, stdin=stdin_mode, stdout=lf, stderr=subprocess.STDOUT, cwd=child_cwd, start_new_session=(os.name != 'nt'))
        if use_stdin:
            feed_stdin(proc)
        start_watchdog(proc)
        proc.wait()
        finish(proc.returncode)
  "
  EXIT_CODE=$?
elif [[ "$CMD_TEMPLATE" == *'"{prompt}"'* ]]; then
  PROMPT=$(cat "$PROMPT_PATH")
  PREFIX="${CMD_TEMPLATE%%'"{prompt}"'*}"
  SUFFIX="${CMD_TEMPLATE#*'"{prompt}"'}"
  IFS=' ' read -ra ARGS <<< "$PREFIX"
  ARGS+=("$PROMPT")
  if [ -n "$SUFFIX" ]; then
    IFS=' ' read -ra SA <<< "$SUFFIX"
    ARGS+=("${SA[@]}")
  fi
  if [ -n "$WT_PATH" ]; then
    (cd "$WT_PATH" && "${ARGS[@]}" < /dev/null > "$OLDPWD/$LOG_PATH" 2>&1)
  else
    "${ARGS[@]}" < /dev/null > "$LOG_PATH" 2>&1
  fi
  EXIT_CODE=$?
  # bash はシグナル N で終了した子の終了コードを 128+N で返す
  if [ "$EXIT_CODE" -gt 128 ]; then
    EXIT_CODE="signal:$((EXIT_CODE - 128))"
  fi
else
  END_TIME=$(date -Iseconds)
  printf "Unsupported template format (only \"{prompt}\" as standalone token is supported in fallback)\nEND:%s\n" "$END_TIME" > "$LOG_PATH"
  EXIT_CODE=1
fi

if [ -f "$SIGNAL_PATH" ]; then
  EXIT_CODE="signal:$(cat "$SIGNAL_PATH")"
  rm -f "$SIGNAL_PATH"
fi
# シグナル死より idle-timeout を優先する(idle-timeout ファイルは記録として残す)
if [ -f "$IDLE_PATH" ]; then
  EXIT_CODE="idle-timeout"
fi

END_TIME=$(date -Iseconds)
printf "EXIT:%s\nEND:%s\n" "$EXIT_CODE" "$END_TIME" > "$DONE_PATH"
