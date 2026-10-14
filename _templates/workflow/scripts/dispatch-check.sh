#!/bin/bash
set -uo pipefail

# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# Usage: dispatch-check.sh <TaskId> [Attempt]
# exit(複数に当たる場合は上にあるものを優先する):
#   8=管理ファイルの改ざん(prompt.md・state.json・tasks.md・config.json が dispatch-run の起動時から
#     変わった/消えた、guard.sha256・output.log が無い、output.log が実行中に切り詰められた)
#   4=異常終了(非0・signal・crashed)
#   6=権限拒否で中断(output.log に子CLIの権限拒否の記録がある)
#   5=完了報告が無い・無効(最後の `## 完了報告` の後にツール実行の記録が続く、必須項目が無い・テンプレートのまま)
#   7=変更0件(完了報告はあるが作業ツリーに変更が無い。PR 作成の run(pr-*)では判定しない)
#   0=正常終了かつ完了報告あり / 1=done マーカーが無い・使い方不備

TASK_ID="${1:?Usage: dispatch-check.sh <TaskId> [Attempt]}"
ATTEMPT="${2:-1}"
TAIL_LINES=30
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]] || ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]]; then
    echo "Invalid TaskId/Attempt: '$TASK_ID' '$ATTEMPT'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

RUN_DIR=".agents/workflow/runs/${TASK_ID}-${ATTEMPT}"
DONE_PATH="$RUN_DIR/done"
LOG_PATH="$RUN_DIR/output.log"
GUARD_PATH="$RUN_DIR/guard.sha256"

if [ ! -f "$DONE_PATH" ]; then
    echo "done marker not found: $DONE_PATH (child agent has not finished yet)" >&2
    exit 1
fi

# Windows PowerShell 5.1 の Out-File は BOM を付けるため除去してから読む
EXIT_VALUE="$(sed -n '1s/^\xEF\xBB\xBF//; s/\r$//; s/^EXIT://p' "$DONE_PATH" | head -1)"
END_VALUE="$(sed -n 's/\r$//; s/^END://p' "$DONE_PATH" | head -1)"

case "$EXIT_VALUE" in
    0) KIND=ok ;;
    signal:*) KIND=signal ;;
    crashed:*) KIND=crashed ;;
    '') KIND=unknown ;;
    *) KIND=nonzero ;;
esac

# --- 管理ファイルの改ざん検知(dispatch-run が起動時に記録した guard.sha256 と比べる) ---
file_hash() {
    if [ ! -f "$1" ]; then
        echo -
    elif command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
GUARD_ISSUES=""
if [ ! -f "$GUARD_PATH" ]; then
    GUARD_ISSUES="${GUARD_ISSUES}guard.sha256 not found (deleted, or the run was not started by dispatch-run)
"
else
    while read -r expected path; do
        [ -n "$path" ] || continue
        actual="$(file_hash "$path")"
        if [ "$actual" != "$expected" ]; then
            if [ "$actual" = - ]; then
                GUARD_ISSUES="${GUARD_ISSUES}deleted: $path
"
            else
                GUARD_ISSUES="${GUARD_ISSUES}changed: $path
"
            fi
        fi
    done < <(sed 's/\r$//' "$GUARD_PATH")
fi
if [ ! -f "$LOG_PATH" ]; then
    GUARD_ISSUES="${GUARD_ISSUES}deleted: $LOG_PATH
"
elif [ "$(LC_ALL=C tr -d '\000' < "$LOG_PATH" | wc -c)" -ne "$(wc -c < "$LOG_PATH")" ]; then
    # 書き込み中のファイルを `: >` 等で空にすると、書き込み位置より前が NUL で埋まる
    GUARD_ISSUES="${GUARD_ISSUES}truncated during the run (NUL bytes): $LOG_PATH
"
fi

# --- ログの正規化(ANSI エスケープと CR を除く) ---
ESC="$(printf '\033')"
CLEAN_LOG=""
if [ -f "$LOG_PATH" ]; then
    CLEAN_LOG="$(LC_ALL=C tr -d '\000' < "$LOG_PATH" | sed "s/${ESC}\[[0-9;]*[A-Za-z]//g; s/\r\$//")"
fi

# --- 権限拒否の検出(opencode: "auto-rejecting" / "rejected permission") ---
DENIED_LINES="$(printf '%s\n' "$CLEAN_LOG" | grep -E 'auto-rejecting|rejected permission' || true)"

# --- 完了報告の判定 ---
# 最後に出現する `## 完了報告` だけを対象にし、その後にツール実行の記録が続く場合は無効とする
# (子がテンプレートやドキュメントを表示しただけの行に一致させないため)。必須項目は
# 通常のタスクが「変更ファイル」「テスト結果」、PR 作成の run(pr-*)が「PR URL」。
# 値が同じ行に無い場合は、次の行からのインデントされた箇条書きを値とみなす。
case "$TASK_ID" in
    pr-*) IS_PR=true; REQUIRED='PR URL' ;;
    *) IS_PR=false; REQUIRED='変更ファイル|テスト結果' ;;
esac
REPORT_RESULT="$(printf '%s\n' "$CLEAN_LOG" | awk -v required="$REQUIRED" '
    { lines[NR] = $0 }
    /^## 完了報告[ \t]*$/ { last = NR }
    END {
        if (!last) { print "missing"; exit }
        for (i = last + 1; i <= NR; i++) {
            if (lines[i] ~ /^(\$|→|←|✱|✗|⚙|!) / || lines[i] ~ /^\[tool_(use|result)\]/) {
                print "invalid (tool activity after the report at line " i ")"; exit
            }
        }
        end = NR
        for (i = last + 1; i <= NR; i++) if (lines[i] ~ /^## /) { end = i - 1; break }
        n = split(required, fields, "|")
        for (k = 1; k <= n; k++) {
            prefix = "- " fields[k] ":"
            found = 0
            for (i = last + 1; i <= end; i++) {
                if (index(lines[i], prefix) != 1) continue
                value = substr(lines[i], length(prefix) + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                if (value == "" && i < end && lines[i + 1] ~ /^[ \t]+[^ \t]/) value = "(list)"
                if (value == "") { print "invalid (empty field: " fields[k] ")"; exit }
                if (value ~ /^<[^>]*>$/) { print "invalid (template placeholder: " fields[k] ")"; exit }
                found = 1; break
            }
            if (!found) { print "invalid (missing field: " fields[k] ")"; exit }
        }
        print "found"
    }')"

CHANGES="$(git status --porcelain)"
CHANGE_COUNT=0
[ -n "$CHANGES" ] && CHANGE_COUNT="$(printf '%s\n' "$CHANGES" | wc -l | tr -d ' ')"

if [ -n "$GUARD_ISSUES" ]; then
    VERDICT="tampered"; CODE=8
elif [ "$KIND" != ok ]; then
    VERDICT="abnormal-exit"; CODE=4
elif [ -n "$DENIED_LINES" ]; then
    VERDICT="permission-denied"; CODE=6
elif [ "$REPORT_RESULT" != found ]; then
    VERDICT="no-report"; CODE=5
elif [ "$IS_PR" = false ] && [ "$CHANGE_COUNT" -eq 0 ]; then
    VERDICT="no-changes"; CODE=7
else
    VERDICT="ok"; CODE=0
fi

echo "Run: ${TASK_ID}-${ATTEMPT}"
echo "Exit: ${EXIT_VALUE} (kind: ${KIND})"
echo "End: ${END_VALUE}"
if [ -n "$GUARD_ISSUES" ]; then
    echo "Guard: NG"
    printf '%s' "$GUARD_ISSUES" | sed 's/^/  /'
else
    echo "Guard: ok"
fi
if [ -n "$DENIED_LINES" ]; then
    echo "Permission denied: yes"
    printf '%s\n' "$DENIED_LINES" | sed 's/^/  /'
else
    echo "Permission denied: no"
fi
echo "Completion report: ${REPORT_RESULT}"
echo "Changes: ${CHANGE_COUNT}"
echo "Verdict: ${VERDICT}"
echo "--- git status --porcelain"
git status --porcelain
echo "--- git diff --stat"
git diff --stat
echo "--- output.log (last ${TAIL_LINES} lines)"
if [ -f "$LOG_PATH" ]; then
    tail -n "$TAIL_LINES" "$LOG_PATH"
else
    echo "(output.log not found)"
fi

exit "$CODE"
