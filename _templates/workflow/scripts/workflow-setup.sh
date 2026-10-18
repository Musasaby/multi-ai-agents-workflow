#!/bin/bash
set -uo pipefail

# 利用先プロジェクトに .agents/workflow/ 一式と関連設定(AGENTS.md・CLAUDE.md・.claude・.gitignore・.gitattributes)を揃える。
# すべて冪等で、既存のファイルは上書きしない。必ずテンプレート側のコピー
# (利用先では .agents/skills/_templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-setup.sh            不足しているものを作る・足す(CREATED / APPENDED を出力)
#   workflow-setup.sh --check    何も変えず、不足しているものを MISSING で出力
# 利用者の判断が要る事項は DECIDE <種別>: <内容> で出力する。
# 最後の行: DECIDE があれば "Next: confirm"、無ければ "Next: continue"
# exit: 0=変更済み(--check では不足なし)かつ DECIDE なし / 1=使い方不備・git の外 / 3=DECIDE あり(--check では MISSING あり)

CHECK=false
case "${1:-}" in
    "") ;;
    --check) CHECK=true ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

TEMPLATE_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(dirname "$TEMPLATE_SCRIPTS")"
TEMPLATES="$(dirname "$TEMPLATE_ROOT")"
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
DECIDE=false
MISSING=false

decide() { echo "DECIDE $1"; DECIDE=true; }

ensure_dir() { # $1 = ROOT からの相対パス
    [ -d "$1" ] && return
    if [ "$CHECK" = true ]; then echo "MISSING $1"; MISSING=true
    else mkdir -p "$1"; echo "CREATED $1"; fi
}

ensure_copy() { # $1 = コピー元, $2 = ROOT からの相対パス(無ければコピー)
    [ -e "$2" ] && return
    if [ "$CHECK" = true ]; then echo "MISSING $2"; MISSING=true
    else mkdir -p "$(dirname "$2")"; cp "$1" "$2"; echo "CREATED $2"; fi
}

ensure_line() { # $1 = ファイル, $2 = 行(完全一致で判定し、無ければ末尾に足す)
    if [ -f "$1" ] && tr -d '\r' < "$1" | grep -qxF -- "$2"; then return; fi
    if [ "$CHECK" = true ]; then echo "MISSING $1: $2"; MISSING=true; return; fi
    if [ ! -f "$1" ]; then
        : > "$1"
        echo "CREATED $1"
    elif [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
        printf '\n' >> "$1"
    fi
    printf '%s\n' "$2" >> "$1"
    echo "APPENDED $1: $2"
}

ensure_dir .agents/workflow/runs
ensure_dir .agents/workflow/.config/opencode/log
ensure_copy "$TEMPLATE_ROOT/config.json" .agents/workflow/config.json
ensure_copy "$TEMPLATE_ROOT/README.md" .agents/workflow/README.md

# スクリプト
if [ "$CHECK" = true ]; then
    SYNC_OUT="$(bash "$TEMPLATE_SCRIPTS/workflow-sync-scripts.sh" 2>&1)"
    [ -n "$SYNC_OUT" ] && echo "$SYNC_OUT"
    if printf '%s\n' "$SYNC_OUT" | grep -q '^missing'; then MISSING=true; fi
else
    if ! bash "$TEMPLATE_SCRIPTS/workflow-sync-scripts.sh" --copy-missing; then
        echo "workflow-sync-scripts.sh --copy-missing failed" >&2
        exit 1
    fi
    chmod +x .agents/workflow/scripts/*.sh 2>/dev/null
fi

ensure_copy "$TEMPLATES/AGENTS.md" AGENTS.md

# CLAUDE.md
if [ ! -e CLAUDE.md ]; then
    if [ "$CHECK" = true ]; then echo "MISSING CLAUDE.md"; MISSING=true
    else printf '@AGENTS.md\n' > CLAUDE.md; echo "CREATED CLAUDE.md"; fi
else
    CLAUDE_BODY="$(tr -d '\r' < CLAUDE.md | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')"
    if [ "$CLAUDE_BODY" != "@AGENTS.md" ]; then
        decide "claude-md: CLAUDE.md has its own content (move it into AGENTS.md, then make CLAUDE.md the single line @AGENTS.md)"
    fi
fi

# .claude
if [ -L .claude ]; then
    if [ ! -e .claude ]; then
        decide "claude-link: .claude is a broken symbolic link (recreate it with: ln -sfn .agents .claude)"
    else
        if [ "$(cd .claude && pwd -P)" != "$(cd .agents 2>/dev/null && pwd -P)" ]; then
            decide "claude-link: .claude points to '$(readlink .claude)', not .agents (check it, then relink with: ln -sfn .agents .claude)"
        fi
    fi
elif [ -e .claude ]; then
    decide "claude-dir: .claude is a real directory (merge it into .agents, then replace it with a link)"
else
    if [ "$CHECK" = true ]; then echo "MISSING .claude"; MISSING=true
    else
        mkdir -p .agents
        LINK_OK=false
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                # Git Bash の ln -s は実体のコピーになるため、ジャンクションを作る
                cmd //c "mklink /J .claude .agents" > /dev/null 2>&1 && LINK_OK=true ;;
            *) ln -s .agents .claude && LINK_OK=true ;;
        esac
        if [ "$LINK_OK" = true ] && [ -L .claude ]; then
            echo "CREATED .claude"
        else
            echo "Failed to create .claude link" >&2
            decide "claude-link: could not create .claude (create it with: cmd /c mklink /J .claude .agents)"
        fi
    fi
fi

for line in .claude .agents/settings.local.json .agents/workflow/.config/ .agents/workflow/runs/ \
    .agents/workflow/archive/ .agents/scheduled_tasks.lock; do
    ensure_line .gitignore "$line"
done

ensure_line .gitattributes ".agents/workflow/scripts/*.sh text eol=lf"
ensure_line .gitattributes ".agents/workflow/scripts/*.py text eol=lf"

# 旧レイアウト
for old in .agents/workflow/.dispatch-run.ps1 .agents/workflow/.dispatch-run.sh \
    .agents/workflow/logs .agents/workflow/reports .agents/workflow/.dispatch-prompt-*.md; do
    [ -e "$old" ] && decide "old-layout: $old"
done

if [ "$DECIDE" = true ]; then
    echo "Next: confirm"
else
    echo "Next: continue"
fi
if [ "$DECIDE" = true ] || [ "$MISSING" = true ]; then exit 3; fi
exit 0
