#!/bin/bash
set -euo pipefail

SLUG="${1:?使い方: workflow-archive.sh <スラッグ>}"

case "$SLUG" in
    */*|*\\*|*..*)
        echo "スラッグにパス区切りや '..' を含めることはできません: $SLUG" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

WORKFLOW_DIR="$ROOT/.agents/workflow"

if [ ! -d "$WORKFLOW_DIR" ]; then
    echo "workflow ディレクトリが見つかりません: $WORKFLOW_DIR" >&2
    exit 1
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M')"
ARCHIVE_DIR="$WORKFLOW_DIR/archive/${TIMESTAMP}-${SLUG}"

TARGETS="tasks.md state.json runs comprehension"
EXISTING=""
for name in $TARGETS; do
    if [ -e "$WORKFLOW_DIR/$name" ]; then
        EXISTING="$EXISTING $name"
    fi
done

if [ -z "$EXISTING" ]; then
    echo "移動対象がありません(tasks.md / state.json / runs/ / comprehension/ のいずれも存在しません)" >&2
    exit 1
fi

mkdir -p "$ARCHIVE_DIR"

for name in $EXISTING; do
    mv "$WORKFLOW_DIR/$name" "$ARCHIVE_DIR/$name"
done

echo "Archived: $ARCHIVE_DIR ($(echo "$EXISTING" | sed 's/^ //;s/ /, /g'))"
