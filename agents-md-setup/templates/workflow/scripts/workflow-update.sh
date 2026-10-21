#!/bin/bash
set -uo pipefail

# 利用先で npx skills update のあとに実行し、npx skills で導入済みかと、配置済みスクリプトとの差分を確かめる。
# 必ずテンプレート側のコピー(利用先では .agents/skills/agents-md-setup/templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-update.sh
# 最後の行: Next: continue / confirm / escalate reason=<not-npx|sync-failed>
# exit: 0=配置済みスクリプトとの差分なし / 1=使い方不備・git の外 /
#       2=npx skills で導入されていない(ルートに skills-lock.json が無い) /
#       3=配置済みスクリプトに差分あり / 22=配置済みスクリプトとの差分確認(workflow-sync-scripts)の失敗

if [ $# -gt 0 ]; then
    echo "Unknown argument: $1" >&2
    exit 1
fi

TEMPLATE_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(dirname "$TEMPLATE_SCRIPTS")"
ROOT="$(cd "$TEMPLATE_SCRIPTS" && git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Not inside a git repository: $TEMPLATE_SCRIPTS" >&2
    exit 1
}
DEST_ROOT="$ROOT/.agents/workflow"
if [ "$(cd "$TEMPLATE_ROOT" && pwd -P)" = "$(cd "$DEST_ROOT" 2>/dev/null && pwd -P)" ]; then
    echo "Run this script from the template copy (.agents/skills/agents-md-setup/templates/workflow/scripts/), not from .agents/workflow/scripts/" >&2
    exit 1
fi

cd "$ROOT" || exit 1

if [ ! -f skills-lock.json ]; then
    echo "skills-lock.json not found: install the skills with 'npx skills add' (see README: git subtree からの移行手順)" >&2
    echo "Next: escalate reason=not-npx"
    exit 2
fi

bash "$TEMPLATE_SCRIPTS/workflow-sync-scripts.sh"
SYNC_CODE=$?
case "$SYNC_CODE" in
    0) echo "Next: continue"; exit 0 ;;
    3) echo "Next: confirm"; exit 3 ;;
    *)
        echo "workflow-sync-scripts.sh failed (exit $SYNC_CODE)" >&2
        echo "Next: escalate reason=sync-failed"
        exit 22
        ;;
esac
