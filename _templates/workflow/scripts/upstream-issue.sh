#!/bin/bash
set -uo pipefail

# ワークフロー由来の問題を upstream(multi-ai-agents-workflow の配布元)リポジトリに Issue として起票する。
# 起票先は .agents/workflow/config.json の upstream.url から決める(利用先リポジトリには起票しない)。
#
# Usage:
#   upstream-issue.sh --search "<キーワード>" [--dry-run]                     重複候補を一覧表示(open/closed)
#   upstream-issue.sh --create --title "<件名>" --body-file <パス> [--dry-run]  起票(ユーザー承認後に実行)
# exit: 0=成功 / 1=使い方・config 不備 / その他=gh の exit code

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

MODE=""
QUERY=""
TITLE=""
BODY_FILE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --search) MODE=search; QUERY="${2:-}"; shift 2 ;;
        --create) MODE=create; shift ;;
        --title) TITLE="${2:-}"; shift 2 ;;
        --body-file) BODY_FILE="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# --body-file の相対パスは呼び出し時のカレントディレクトリ基準で解決する
if [ -n "$BODY_FILE" ] && [ "${BODY_FILE#/}" = "$BODY_FILE" ]; then
    BODY_FILE="$(pwd)/$BODY_FILE"
fi
cd "$SCRIPT_DIR/../../.."
CONFIG_PATH=".agents/workflow/config.json"

case "$MODE" in
    search)
        if [ -z "$QUERY" ]; then echo "--search requires a query" >&2; exit 1; fi ;;
    create)
        if [ -z "$TITLE" ]; then echo "--create requires --title" >&2; exit 1; fi
        if [ -z "$BODY_FILE" ] || [ ! -f "$BODY_FILE" ]; then
            echo "--create requires an existing --body-file (got: '${BODY_FILE}')" >&2
            exit 1
        fi ;;
    *)
        echo "Specify --search \"<query>\" or --create --title \"<title>\" --body-file <path>" >&2
        exit 1 ;;
esac

if [ ! -f "$CONFIG_PATH" ]; then
    echo "config.json not found: $CONFIG_PATH" >&2
    exit 1
fi

REPO="$(python3 - "$CONFIG_PATH" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    url = ((json.load(f).get('upstream') or {}).get('url') or '').strip()
if not url:
    print('upstream.url is not set in config.json', file=sys.stderr)
    sys.exit(1)
m = re.match(r'^(?:https?://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+?)(?:\.git)?/?$', url)
if not m:
    print('upstream.url is not a GitHub repository URL: ' + url, file=sys.stderr)
    sys.exit(1)
print(m.group(1) + '/' + m.group(2))
PY
)" || exit 1

if [ "$MODE" = search ]; then
    CMD=(gh issue list -R "$REPO" --state all --search "$QUERY" --limit 20)
else
    CMD=(gh issue create -R "$REPO" --title "$TITLE" --body-file "$BODY_FILE")
fi

echo "Repository: $REPO"
if [ "$DRY_RUN" = true ]; then
    printf 'Command (dry-run):'
    for a in "${CMD[@]}"; do
        case "$a" in
            *' '*|'') printf ' "%s"' "$a" ;;
            *) printf ' %s' "$a" ;;
        esac
    done
    printf '\n'
    exit 0
fi
"${CMD[@]}"
