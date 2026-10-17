#!/bin/bash
set -uo pipefail

# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# Usage: dispatch-check.sh <TaskId> [Attempt]
# exit(複数に当たる場合は上にあるものを優先する):
#   8=管理ファイルの改ざん(prompt.md・state.json・tasks.md・config.json が dispatch-run の起動時から
#     変わった/消えた、guard.sha256・output.log・git-state.txt が無い、output.log が実行中に
#     切り詰められた、本物のリポジトリの git 状態(HEAD・ブランチ・参照・設定)が変わった)
#   4=異常終了(非0・signal・crashed)
#   6=権限拒否で中断(output.log に子CLIの権限拒否の記録がある)、または、ツール実行の記録に
#     プロジェクト外(/tmp・ホームディレクトリ等)へのアクセスがある
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
# (BSD sed は \xEF 等のエスケープを解釈しないため、BOM のバイト列は printf で作る)
BOM="$(printf '\357\273\277')"
EXIT_VALUE="$(LC_ALL=C tr -d '\r' < "$DONE_PATH" | LC_ALL=C sed -n "1s/^$BOM//; s/^EXIT://p" | head -1)"
END_VALUE="$(LC_ALL=C tr -d '\r' < "$DONE_PATH" | LC_ALL=C sed -n 's/^END://p' | head -1)"

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
    done < <(LC_ALL=C tr -d '\r' < "$GUARD_PATH")
fi

# --- 本物のリポジトリの git 状態の検証(dispatch-run が起動時に git-state.txt に記録した値と比べる) ---
# タスク種別の判定(完了報告の必須項目と変更0件の判定で使う case)は、ここでも IS_PR を使うため
# この位置に置いている。PR 作成の run(IS_PR=true。タスクIDが pr- で始まる)は config を比べない
# (子が git push -u で .git/config を正当に変えるため)
case "$TASK_ID" in
    pr-*) IS_PR=true; REQUIRED='PR URL' ;;
    *) IS_PR=false; REQUIRED='変更ファイル|テスト結果' ;;
esac
GIT_STATE_PATH="$RUN_DIR/git-state.txt"
if [ ! -f "$GIT_STATE_PATH" ]; then
    GUARD_ISSUES="${GUARD_ISSUES}git-state.txt not found (deleted, or the run was not started by dispatch-run)
"
else
    RECORDED_STATE="$(LC_ALL=C tr -d '\r' < "$GIT_STATE_PATH")"
    # 実行権限に頼らず bash で呼ぶ(リポジトリ上のスクリプトは mode 100644 のため)
    CURRENT_STATE="$(bash "$SCRIPT_DIR/git-state.sh" 2> /dev/null | LC_ALL=C tr -d '\r')"
    for name in head branch refs config; do
        if [ "$IS_PR" = true ] && [ "$name" = config ]; then continue; fi
        recorded="$(printf '%s\n' "$RECORDED_STATE" | LC_ALL=C awk -v name="$name" '$1 == name { print $2 }')"
        current="$(printf '%s\n' "$CURRENT_STATE" | LC_ALL=C awk -v name="$name" '$1 == name { print $2 }')"
        if [ "$recorded" != "$current" ]; then
            GUARD_ISSUES="${GUARD_ISSUES}git changed: $name
"
        fi
    done
fi
if [ ! -f "$LOG_PATH" ]; then
    GUARD_ISSUES="${GUARD_ISSUES}deleted: $LOG_PATH
"
elif [ "$(LC_ALL=C tr -d '\000' < "$LOG_PATH" | wc -c)" -ne "$(wc -c < "$LOG_PATH")" ]; then
    # 書き込み中のファイルを `: >` 等で空にすると、書き込み位置より前が NUL で埋まる
    GUARD_ISSUES="${GUARD_ISSUES}truncated during the run (NUL bytes): $LOG_PATH
"
fi

# --- ログの正規化(NUL・CR を除く。ANSI エスケープは awk 側で扱う) ---
# BSD sed は不正な UTF-8 バイトでエラーになるため、バイト単位で処理する(LC_ALL=C の tr / awk)
ESC="$(printf '\033')"
RAW_LOG=""
if [ -f "$LOG_PATH" ]; then
    RAW_LOG="$(LC_ALL=C tr -d '\000\r' < "$LOG_PATH")"
fi

# --- 権限拒否の検出 ---
# opencode が拒否を記録する行(行頭の `! permission requested: ...; auto-rejecting`)だけに一致させる
# (子がスクリプトやテストを表示した出力の中の同じ文字列には反応しない)
DENIED_LINES="$(printf '%s\n' "$RAW_LOG" | LC_ALL=C awk -v esc="$ESC" '
    { line = $0; gsub(esc "\\[[0-9;]*[A-Za-z]", "", line) }
    line ~ /^! permission requested: .*auto-rejecting/ { print line }')"

# --- プロジェクト外(/tmp・ホームディレクトリ等)へのアクセスの検出 ---
# 権限を拒否されずに成功したプロジェクト外アクセス(例: bash -c "... > /tmp/x.log"、cat ~/x.log)を検出する。
# 対象はツール実行の記録行だけ: opencode の色付きマーカー行($ / → / ← / ✱ / ✗ / ⚙ で始まるもの。
# ! は権限拒否の行なので除く)と stream-json の [tool_use] 行。ツールの出力(色なしの行・
# [tool_result] 行)や完了報告の本文には反応しない。判定は ANSI エスケープを除いた行に対して行う。
# 条件の正規表現は outside_re と home_re にまとめる(条件を足したくなったらここへ追記する)。
# home_re はホームディレクトリ(~/・$HOME・${HOME}・$env:USERPROFILE・%USERPROFILE% 等)と
# Windows のユーザー一時ディレクトリ(AppData の Temp)への参照。大文字小文字を区別しないため、
# ANSI エスケープを除いた行を tolower() してから当てる。$env:TEMP・%TEMP%・$TMPDIR は
# dispatch-run によりプロジェクト内を指すため検出しない
OUTSIDE_LINES="$(printf '%s\n' "$RAW_LOG" | LC_ALL=C awk -v esc="$ESC" '
    BEGIN {
        outside_re = "(^|[ \t\"'\''=(<>])\\/(var\\/)?tmp([\\/ \t\"'\'');]|$)"
        home_re = "(^|[ \t\"'\''=(<>])~\\/|\\$(\\{home\\}|home([^a-z0-9_]|$)|env:(home|userprofile)([^a-z0-9_]|$))|%userprofile%|appdata[\\\\/]local[\\\\/]temp"
    }
    {
        raw = $0
        is_tool = (raw ~ ("^" esc "\\[[0-9;]*m(\\$|→|←|✱|✗|⚙) " esc "\\[[0-9;]*m")) || (raw ~ /^\[tool_use\]/)
        if (!is_tool) next
        line = raw; gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
        if (line ~ outside_re || tolower(line) ~ home_re) print line
    }')"

# --- 完了報告の判定 ---
# 最後に出現する `## 完了報告` だけを対象にし、その後にツール実行の記録が続く場合は無効とする
# (子がテンプレートやドキュメントを表示しただけの行に一致させないため)。ツール実行の記録は、
# opencode が色付きで出すマーカー行(`ESC[0m$ ESC[0m...` 等)と stream-json の `[tool_use]` /
# `[tool_result]` 行に限る(報告本文の `→ 要確認` や `$ npm test` は対象外)。必須項目は
# 通常のタスクが「変更ファイル」「テスト結果」、PR 作成の run(pr-*)が「PR URL」。
# 値が同じ行に無い場合は、次の行からのインデントされた箇条書きを値とみなす。
REPORT_RESULT="$(printf '%s\n' "$RAW_LOG" | LC_ALL=C awk -v esc="$ESC" -v required="$REQUIRED" '
    {
        raw = $0
        tool[NR] = (raw ~ ("^" esc "\\[[0-9;]*m(\\$|→|←|✱|✗|⚙|!) " esc "\\[[0-9;]*m")) || (raw ~ /^\[tool_(use|result)\]/)
        gsub(esc "\\[[0-9;]*[A-Za-z]", "", raw)
        lines[NR] = raw
    }
    lines[NR] ~ /^## 完了報告[ \t]*$/ { last = NR }
    END {
        if (!last) { print "missing"; exit }
        for (i = last + 1; i <= NR; i++) {
            if (tool[i]) { print "invalid (tool activity after the report at line " i ")"; exit }
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
elif [ -n "$OUTSIDE_LINES" ]; then
    VERDICT="outside-access"; CODE=6
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
if [ -n "$OUTSIDE_LINES" ]; then
    echo "Outside access: yes"
    printf '%s\n' "$OUTSIDE_LINES" | sed 's/^/  /'
else
    echo "Outside access: no"
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
    # 切り詰められた output.log(先頭の NUL)をそのまま tail に渡すと stdout に NUL が流れるため除く
    LC_ALL=C tr -d '\000\r' < "$LOG_PATH" | tail -n "$TAIL_LINES"
else
    echo "(output.log not found)"
fi

exit "$CODE"
