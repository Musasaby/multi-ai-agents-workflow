#!/bin/bash
TASK_ID="${1:?TaskId required}"
ATTEMPT="${2:-1}"
cd "$(dirname "$0")/../.."
export XDG_CONFIG_HOME=".agents/workflow/.config"
export XDG_DATA_HOME=".agents/workflow/.config"
mkdir -p .agents/workflow/logs
LOG_PATH=".agents/workflow/logs/${TASK_ID}-${ATTEMPT}.log"
DONE_PATH=".agents/workflow/logs/${TASK_ID}-${ATTEMPT}.done"
rm -f "$DONE_PATH"
PROMPT_PATH=".agents/workflow/.dispatch-prompt-${TASK_ID}.md"
if [ ! -f "$PROMPT_PATH" ]; then
  PROMPT_PATH=".agents/workflow/.dispatch-prompt.md"
fi

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
sys.exit(subprocess.call(tokens, stdin=subprocess.DEVNULL))
  " > "$LOG_PATH" 2>&1
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
