#!/bin/bash
set -uo pipefail

# 利用先で .agents/skills/ を upstream から git subtree pull で更新し、配置済みスクリプトとの差分を知らせる。
# 必ずテンプレート側のコピー(利用先では .agents/skills/_templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-update.sh
# 最後の行: Next: continue / confirm / escalate reason=<dirty-tree|conflict|subtree-failed|sync-failed>
# exit: 0=更新済みで配置済みスクリプトとの差分なし / 1=使い方不備・git の外 /
#       2=コンフリクト(CONFLICT <パス> を出力) / 3=更新済みで配置済みスクリプトに差分あり /
#       20=作業ツリーが汚れている / 21=subtree pull の失敗(コンフリクト以外) /
#       22=配置済みスクリプトとの差分確認(workflow-sync-scripts)の失敗

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
    echo "Run this script from the template copy (.agents/skills/_templates/workflow/scripts/), not from .agents/workflow/scripts/" >&2
    exit 1
fi

cd "$ROOT" || exit 1

DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
    printf '%s\n' "$DIRTY" >&2
    echo "Next: escalate reason=dirty-tree"
    exit 20
fi

DEFAULT_URL="https://github.com/Musasaby/multi-ai-agents-workflow.git"
UPSTREAM="$(python3 - ".agents/workflow/config.json" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        u = json.load(f).get('upstream') or {}
except Exception:
    u = {}
print(u.get('url') or '')
print(u.get('branch') or '')
PY
)"
URL="$(printf '%s\n' "$UPSTREAM" | sed -n '1p' | tr -d '\r')"
BRANCH="$(printf '%s\n' "$UPSTREAM" | sed -n '2p' | tr -d '\r')"
[ -z "$URL" ] && URL="$DEFAULT_URL"
[ -z "$BRANCH" ] && BRANCH="dist"
echo "Upstream: $URL $BRANCH"
if [ "$BRANCH" = "main" ]; then
    echo 'WARN: upstream.branch is main; the distribution moved to the dist branch. Set upstream.branch to "dist" in .agents/workflow/config.json (see .agents/skills/workflow-update/references/migrations.md)' >&2
fi

if ! git subtree pull --prefix=.agents/skills "$URL" "$BRANCH" --squash -m "chore: .agents/skills を upstream から更新"; then
    CONFLICTS="$(git diff --name-only --diff-filter=U)"
    if [ -n "$CONFLICTS" ]; then
        printf '%s\n' "$CONFLICTS" | while IFS= read -r f; do echo "CONFLICT $f"; done
        echo "Next: escalate reason=conflict"
        exit 2
    fi
    echo "Next: escalate reason=subtree-failed"
    exit 21
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
