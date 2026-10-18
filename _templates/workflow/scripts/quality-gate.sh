#!/bin/bash
set -uo pipefail

# config.json の quality_gate.steps を定義順に実行し、品質ゲートの合否を判定する。
# Usage: quality-gate.sh [--out-dir <ディレクトリ>] [--steps <名前,...>] [--fix]
#   各ステップの stdout/stderr は <out-dir>/<name>.log に書く
#   (--out-dir が無ければ .agents/workflow/runs/quality-gate-<YYYYMMDD-HHMMSS>/ を作る)
#   command が空のステップは、package.json の scripts に同名のキーがあれば npm run <name>、無ければ SKIP
#   config.json に quality_gate が無ければ package.json の scripts から typecheck・lint・test の順に検出する
#   --steps: 指定した名前のステップだけを実行する(解決後に絞り込む)
#   --fix: fix_command を持つステップは command の前に fix_command を実行する(<name>.fix.log。判定に含めない)
#   blocking のステップが失敗しても後続を実行する
# exit: 0=PASS / 1=使い方不備・config が読めない / 2=FAIL(blocking のステップが失敗) / 3=実行するステップが0件

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1

OUT_DIR=""
ONLY_STEPS=""
FIX=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir)
            if [ $# -lt 2 ]; then echo "--out-dir requires a value" >&2; exit 1; fi
            OUT_DIR="$2"; shift 2 ;;
        --steps)
            if [ $# -lt 2 ]; then echo "--steps requires a value" >&2; exit 1; fi
            ONLY_STEPS="$2"; shift 2 ;;
        --fix) FIX=1; shift ;;
        *) echo "Unknown argument: $1" >&2
           echo "Usage: quality-gate.sh [--out-dir <dir>] [--steps <name,...>] [--fix]" >&2
           exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
CONFIG_PATH=".agents/workflow/config.json"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "config.json not found: $CONFIG_PATH" >&2
    exit 1
fi

STEPS="$(python3 - "$CONFIG_PATH" "$ONLY_STEPS" <<'PY'
import json, os, re, sys

sys.stdout.reconfigure(newline=chr(10))  # Windows の python は改行を CRLF にするため LF に固定する

def one_line(v):
    return str(v or '').replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')

try:
    with open(sys.argv[1], encoding='utf-8') as f:
        config = json.load(f)
    only = [n for n in re.split(r'[,\s]+', sys.argv[2]) if n]
    pkg_scripts = {}
    if os.path.isfile('package.json'):
        try:
            with open('package.json', encoding='utf-8') as f:
                pkg_scripts = json.load(f).get('scripts') or {}
        except Exception:
            pkg_scripts = {}
    gate = config.get('quality_gate')
    if gate is None:
        steps = [{'name': n, 'blocking': n != 'lint'} for n in ('typecheck', 'lint', 'test') if n in pkg_scripts]
    else:
        steps = gate.get('steps') or []
    for s in steps:
        name = str(s['name'])
        if only and name not in only:
            continue
        command = one_line(s.get('command'))
        if not command and name in pkg_scripts:
            command = 'npm run ' + name
        blocking = '0' if s.get('blocking', True) is False else '1'
        print(name + '\t' + blocking + '\t' + one_line(s.get('fix_command')) + '\t' + command)
except Exception as e:
    print('Cannot read quality_gate.steps: ' + str(e), file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1

# 実行するステップ(command が空でないもの)が0件なら NO-STEPS
RUNNABLE=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    command="${line##*$'\t'}"
    [ -n "$command" ] && RUNNABLE=$((RUNNABLE + 1))
done <<< "$STEPS"
if [ "$RUNNABLE" -eq 0 ]; then
    echo "Result: NO-STEPS"
    echo "Next: escalate reason=no-steps"
    exit 3
fi

if [ -z "$OUT_DIR" ]; then
    OUT_DIR=".agents/workflow/runs/quality-gate-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR" || { echo "Cannot create out-dir: $OUT_DIR" >&2; exit 1; }

FAILED_LOGS=()
FAILED_NAMES=()
BLOCKING_FAILED=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    blocking="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    fix_command="${rest%%$'\t'*}"
    command="${rest#*$'\t'}"
    label="blocking"
    [ "$blocking" = 0 ] && label="non-blocking"
    if [ -z "$command" ]; then
        echo "SKIP $name ($label): "
        continue
    fi
    safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    log="$OUT_DIR/$safe.log"
    if [ "$FIX" = 1 ] && [ -n "$fix_command" ]; then
        bash -c "$fix_command" < /dev/null > "$OUT_DIR/$safe.fix.log" 2>&1 || true
    fi
    if bash -c "$command" < /dev/null > "$log" 2>&1; then
        echo "PASS $name ($label): $command"
    else
        echo "FAIL $name ($label): $command"
        FAILED_NAMES+=("$name")
        FAILED_LOGS+=("$log")
        [ "$blocking" = 1 ] && BLOCKING_FAILED=1
    fi
done <<< "$STEPS"

i=0
while [ "$i" -lt "${#FAILED_NAMES[@]}" ]; do
    echo "--- ${FAILED_NAMES[$i]} (last 20 lines)"
    tail -n 20 "${FAILED_LOGS[$i]}"
    i=$((i + 1))
done

echo "Logs: $OUT_DIR"
if [ "$BLOCKING_FAILED" -eq 1 ]; then
    echo "Result: FAIL"
    echo "Next: escalate reason=quality-gate"
    exit 2
fi
echo "Result: PASS"
echo "Next: continue"
exit 0
