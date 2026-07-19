#!/bin/bash
TASK_ID="${1:?TaskId required}"
ATTEMPT="${2:-1}"
cd "$(dirname "$0")/../../.."
export XDG_CONFIG_HOME=".agents/workflow/.config"
export XDG_DATA_HOME=".agents/workflow/.config"
RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
mkdir -p "$RUN_DIR"
LOG_PATH="$RUN_DIR/output.log"
JSONL_PATH="$RUN_DIR/output.jsonl"
DONE_PATH="$RUN_DIR/done"
rm -f "$DONE_PATH"
PROMPT_PATH="$RUN_DIR/prompt.md"

CMD_TEMPLATE=$(jq -r '.child_agent.command_template' .agents/workflow/config.json 2>/dev/null || \
  python3 -c "import json; print(json.load(open('.agents/workflow/config.json'))['child_agent']['command_template'])" 2>/dev/null || \
  sed -n 's/.*"command_template"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*/\1/p' .agents/workflow/config.json)

if command -v python3 > /dev/null 2>&1; then
  python3 -c "
import json, subprocess, sys, shlex

with open('.agents/workflow/config.json', encoding='utf-8') as f:
    tmpl = json.load(f)['child_agent']['command_template']
with open('$PROMPT_PATH', encoding='utf-8') as f:
    prompt = f.read()
tokens = shlex.split(tmpl)
tokens = [t.replace('{prompt}', prompt) if '{prompt}' in t else t for t in tokens]

log_path = '$LOG_PATH'
is_stream = 'stream-json' in tmpl

if is_stream:
    jsonl_path = '$JSONL_PATH'

    def human_line(obj):
        t = obj.get('type')
        if t == 'assistant':
            lines = []
            for block in (obj.get('message') or {}).get('content') or []:
                bt = block.get('type')
                if bt == 'text':
                    lines.append(block.get('text', ''))
                elif bt == 'tool_use':
                    inp = json.dumps(block.get('input', {}), ensure_ascii=False)
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
        proc = subprocess.Popen(tokens, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', bufsize=1)
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
        sys.exit(proc.returncode)
else:
    with open(log_path, 'w', encoding='utf-8') as lf:
        proc = subprocess.Popen(tokens, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT)
        proc.wait()
        sys.exit(proc.returncode)
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
  "${ARGS[@]}" < /dev/null > "$LOG_PATH" 2>&1
  EXIT_CODE=$?
else
  END_TIME=$(date -Iseconds)
  printf "Unsupported template format (only \"{prompt}\" as standalone token is supported in fallback)\nEND:%s\n" "$END_TIME" > "$LOG_PATH"
  EXIT_CODE=1
fi

END_TIME=$(date -Iseconds)
printf "EXIT:%s\nEND:%s\n" "$EXIT_CODE" "$END_TIME" > "$DONE_PATH"
