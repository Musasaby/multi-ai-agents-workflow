#!/bin/bash
set -uo pipefail

# 配布テンプレート(このスクリプトがあるディレクトリ)と利用先の配置先
# (.agents/workflow/scripts/ と .agents/workflow/README.md)を比較し、差分を反映する。
# 必ずテンプレート側のコピー(利用先では .agents/skills/_templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-sync-scripts.sh                         差分の一覧(missing / differs)を表示
#   workflow-sync-scripts.sh --copy-missing          未配置のファイルだけをコピー(既存は上書きしない)
#   workflow-sync-scripts.sh --overwrite <名前,...>  指定したファイルをテンプレートで上書き(ユーザー承認後)
#   workflow-sync-scripts.sh --diff <名前>           配置先 → テンプレートの差分を表示
# 名前は一覧に表示される形式(例: scripts/dispatch-run.sh, README.md)
# exit: 0=成功(一覧モードでは差分なし) / 1=使い方不備 / 3=一覧モードで差分あり
# 改行コード(CRLF/LF)だけの違いは差分とみなさない。

MODE=list
NAMES=""
case "${1:-}" in
    "") ;;
    --copy-missing) MODE=copy ;;
    --overwrite) MODE=overwrite; NAMES="${2:-}" ;;
    --diff) MODE=diff; NAMES="${2:-}" ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac
if { [ "$MODE" = overwrite ] || [ "$MODE" = diff ]; } && [ -z "$NAMES" ]; then
    echo "--$MODE requires file name(s) (e.g. scripts/dispatch-run.sh)" >&2
    exit 1
fi

TEMPLATE_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(dirname "$TEMPLATE_SCRIPTS")"
ROOT="$(cd "$TEMPLATE_SCRIPTS" && git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Not inside a git repository: $TEMPLATE_SCRIPTS" >&2
    exit 1
}
DEST_ROOT="$ROOT/.agents/workflow"
# 配置先のコピー(.agents/workflow/scripts/)から実行すると比較元と比較先が同じになり、
# 常に「差分なし」と誤報するため拒否する
if [ "$(cd "$TEMPLATE_ROOT" && pwd -P)" = "$(cd "$DEST_ROOT" 2>/dev/null && pwd -P)" ]; then
    echo "Run this script from the template copy (.agents/skills/_templates/workflow/scripts/), not from .agents/workflow/scripts/" >&2
    exit 1
fi

# 比較対象の名前一覧(scripts/<ファイル> と README.md)
names() {
    local f
    for f in "$TEMPLATE_SCRIPTS"/*; do
        [ -f "$f" ] && echo "scripts/$(basename "$f")"
    done
    [ -f "$TEMPLATE_ROOT/README.md" ] && echo "README.md"
}

# CRLF・BOM を無視して内容が同じか
same_content() {
    cmp -s <(sed '1s/^\xEF\xBB\xBF//; s/\r$//' "$1") <(sed '1s/^\xEF\xBB\xBF//; s/\r$//' "$2")
}

status_of() { # $1 = 名前 → missing / differs / same
    local src="$TEMPLATE_ROOT/$1" dst="$DEST_ROOT/$1"
    if [ ! -f "$dst" ]; then echo missing
    elif same_content "$src" "$dst"; then echo same
    else echo differs
    fi
}

copy_one() { # $1 = 名前
    mkdir -p "$(dirname "$DEST_ROOT/$1")"
    cp "$TEMPLATE_ROOT/$1" "$DEST_ROOT/$1"
    case "$1" in *.sh) chmod +x "$DEST_ROOT/$1" ;; esac
}

case "$MODE" in
    list)
        FOUND=false
        while read -r n; do
            st="$(status_of "$n")"
            if [ "$st" != same ]; then
                printf '%-8s %s\n' "$st" "$n"
                FOUND=true
            fi
        done < <(names)
        if [ "$FOUND" = true ]; then exit 3; fi
        echo "All files are in sync with the template"
        exit 0 ;;
    copy)
        while read -r n; do
            if [ "$(status_of "$n")" = missing ]; then
                copy_one "$n"
                echo "copied   $n"
            fi
        done < <(names)
        exit 0 ;;
    overwrite|diff)
        ALL="$(names)"
        IFS=',' read -ra REQ <<< "$NAMES"
        for n in "${REQ[@]}"; do
            if ! printf '%s\n' "$ALL" | grep -qxF "$n"; then
                echo "Unknown file name: '$n' (use a name shown by the list mode)" >&2
                exit 1
            fi
        done
        for n in "${REQ[@]}"; do
            if [ "$MODE" = diff ]; then
                if [ -f "$DEST_ROOT/$n" ]; then
                    git --no-pager diff --no-index --ignore-cr-at-eol -- "$DEST_ROOT/$n" "$TEMPLATE_ROOT/$n"
                else
                    echo "missing  $n (not deployed yet)"
                fi
            else
                copy_one "$n"
                echo "overwritten $n"
            fi
        done
        exit 0 ;;
esac
