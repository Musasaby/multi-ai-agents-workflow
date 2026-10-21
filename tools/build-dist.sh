#!/bin/bash
set -euo pipefail

# main の木から .distignore のパスを除いた木で dist ブランチのコミットを作る(CI から呼ぶ)。
# 作業ツリーと index は変えない。dist の親は前回の dist(初回は親なし)。
#
# Usage:
#   tools/build-dist.sh [--source <rev>] [--branch <name>]   (既定: HEAD / dist)
# 出力: Updated: <branch> <commit> / Unchanged: <branch>(木が前回と同じ)
# exit: 0=作成済みまたは変更なし / 1=使い方不備・git の外・<rev> に .distignore が無い

SOURCE=HEAD
BRANCH=dist
while [ $# -gt 0 ]; do
    case "$1" in
        --source|--branch)
            if [ $# -lt 2 ]; then
                echo "Missing value for $1" >&2
                exit 1
            fi
            if [ "$1" = "--source" ]; then SOURCE="$2"; else BRANCH="$2"; fi
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

ROOT=$(git rev-parse --show-toplevel) || exit 1
cd "$ROOT"
SRC=$(git rev-parse --verify -q "$SOURCE^{commit}") || { echo "Unknown revision: $SOURCE" >&2; exit 1; }
LIST=$(git show "$SRC:.distignore" 2>/dev/null) || { echo ".distignore not found in $SOURCE" >&2; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
export GIT_INDEX_FILE="$TMPD/index"      # 空ファイルは不正な index になるため、存在しないパスを渡す
git read-tree "$SRC"
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    git rm -r -q --cached -f --ignore-unmatch -- "${line%/}"
done <<< "$LIST"
TREE=$(git write-tree)
unset GIT_INDEX_FILE

PARENT=$(git rev-parse -q --verify "refs/heads/$BRANCH^{commit}" || true)
if [ -n "$PARENT" ] && [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then
    echo "Unchanged: $BRANCH"
    exit 0
fi
COMMIT=$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "dist: $(git rev-parse --short "$SRC") から生成")
git update-ref "refs/heads/$BRANCH" "$COMMIT" "$PARENT"   # PARENT が空なら「ref が無いこと」を条件に作る
echo "Updated: $BRANCH $COMMIT"
