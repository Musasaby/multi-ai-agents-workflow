#!/bin/bash
set -uo pipefail

# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# Usage: dispatch-check.sh <TaskId> [Attempt]
# exit(複数に当たる場合は上にあるものを優先する):
#   8=管理ファイルの改ざん(prompt.md・state.json・tasks.md・config.json が dispatch-run の起動時から
#     変わった/消えた、guard.sha256・output.log・git-state.txt が無い、output.log が実行中に
#     切り詰められた、本物のリポジトリの git 状態(HEAD・ブランチ・参照・設定)が変わった)
#   4=異常終了(非0・signal・crashed・idle-timeout)
#   6=権限拒否で中断(output.log にプロファイルの権限拒否の記録がある)、または、ツール実行の記録に
#     プロジェクト外(/tmp・ホームディレクトリ等)へのアクセスがある
#   5=完了報告が無い・無効(最後の `## 完了報告` の後にツール実行の記録が続く、必須項目が無い・テンプレートのまま)。
#     最後のツール実行の後に出力が無い場合は、その旨を理由に書く
#   7=変更0件(完了報告はあるが作業ツリーに変更が無い。PR 作成の run(pr-*)では判定しない)
#   0=正常終了かつ完了報告あり / 2=done マーカーが無い(まだ実行中) / 1=使い方不備
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / review <TaskId> /
# collect <TaskId>(worktree の run で正常のとき)/
# escalate reason=<理由>。使い方不備の exit 1 では出さない)

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
    echo "Next: wait"
    exit 2
fi

# --- 子CLIプロファイルの解決(config.json の child_agent.profile。検知のパターンを決める) ---
# childprofile.py は7行を返す: 名前・出力形式・tool_activity・tool_call・permission_denied・
# provider_error・agents_md_imports(パターンが空の行もあるため、行は位置で取り出す)
to_py_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}
if ! PROFILE_OUT="$(python3 "$(to_py_path "$SCRIPT_DIR")/childprofile.py" . | tr -d '\r')"; then
    exit 1
fi
PROFILE_NAME="$(printf '%s\n' "$PROFILE_OUT" | sed -n '1p')"
TOOL_ACTIVITY_RE="$(printf '%s\n' "$PROFILE_OUT" | sed -n '3p')"
TOOL_CALL_RE="$(printf '%s\n' "$PROFILE_OUT" | sed -n '4p')"
DENIED_RE="$(printf '%s\n' "$PROFILE_OUT" | sed -n '5p')"
PROVIDER_RE="$(printf '%s\n' "$PROFILE_OUT" | sed -n '6p')"
DISABLED_CHECKS=""
add_disabled() { # $1 = パターン, $2 = 検査名
    if [ -z "$1" ]; then
        DISABLED_CHECKS="${DISABLED_CHECKS:+$DISABLED_CHECKS, }$2"
    fi
}
add_disabled "$DENIED_RE" permission-denied
add_disabled "$TOOL_CALL_RE" outside-access
add_disabled "$TOOL_ACTIVITY_RE" tool-activity
add_disabled "$PROVIDER_RE" provider-error

# Windows PowerShell 5.1 の Out-File は BOM を付けるため除去してから読む
# (BSD sed は \xEF 等のエスケープを解釈しないため、BOM のバイト列は printf で作る)
BOM="$(printf '\357\273\277')"
EXIT_VALUE="$(LC_ALL=C tr -d '\r' < "$DONE_PATH" | LC_ALL=C sed -n "1s/^$BOM//; s/^EXIT://p" | head -1)"
END_VALUE="$(LC_ALL=C tr -d '\r' < "$DONE_PATH" | LC_ALL=C sed -n 's/^END://p' | head -1)"

case "$EXIT_VALUE" in
    0) KIND=ok ;;
    idle-timeout) KIND=idle-timeout ;;
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

# worktree の run は、本体の state.json の自分のタスクの欄が起動時から変わっていないかも確かめる
if [ -f "$RUN_DIR/worktree.txt" ]; then
    if [ ! -f "$RUN_DIR/state-entry.txt" ]; then
        GUARD_ISSUES="${GUARD_ISSUES}state-entry.txt not found
"
    else
        CURRENT_ENTRY="$(python3 -c "
import json, sys
try:
    with open('.agents/workflow/state.json', encoding='utf-8') as f:
        tasks = json.load(f).get('tasks', [])
    for e in tasks:
        if e.get('id') == sys.argv[1]:
            print(json.dumps({k: e.get(k) for k in ('status', 'retries', 'commit')}, sort_keys=True))
            break
    else:
        print('-')
except Exception:
    print('-')
" "$TASK_ID" 2> /dev/null | tr -d '\r')"
        if [ "$CURRENT_ENTRY" != "$(LC_ALL=C tr -d '\r' < "$RUN_DIR/state-entry.txt" | head -n 1)" ]; then
            GUARD_ISSUES="${GUARD_ISSUES}changed: .agents/workflow/state.json ($TASK_ID)
"
        fi
    fi
    # 自分以外のタスクの欄は、親の正規の遷移(task-state・state-sync --insert)だけを許す
    if [ ! -f "$RUN_DIR/state-tasks.json" ]; then
        GUARD_ISSUES="${GUARD_ISSUES}state-tasks.json not found
"
    else
        BAD_TASKS="$(python3 -c "
import json, subprocess, sys
try:
    with open(sys.argv[2], encoding='utf-8') as f:
        before = {e['id']: e for e in json.load(f)}
except Exception:
    before = None
if before is None:
    print(sys.argv[1])
    sys.exit(0)
try:
    with open('.agents/workflow/state.json', encoding='utf-8') as f:
        now = {str(e.get('id')): e for e in json.load(f).get('tasks', [])}
except Exception:
    now = {}

def is_ancestor(c):
    if not c or not isinstance(c, str):
        return False
    r = subprocess.run(['git', 'merge-base', '--is-ancestor', c, 'HEAD'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0

bad = []
for tid, b in before.items():
    if tid == sys.argv[1]:
        continue
    n = now.get(tid)
    if n is None:
        bad.append(tid)
    elif b.get('status') == 'done':
        if n.get('status') != 'done' or n.get('commit') != b.get('commit'):
            bad.append(tid)
    else:
        if n.get('status') == 'done' and not is_ancestor(n.get('commit')):
            bad.append(tid)
for tid, n in now.items():
    if tid not in before and n.get('status') != 'pending':
        bad.append(tid)
print(' '.join(bad))
" "$TASK_ID" "$RUN_DIR/state-tasks.json" 2> /dev/null | tr -d '\r')"
        for bad_id in $BAD_TASKS; do
            GUARD_ISSUES="${GUARD_ISSUES}changed: .agents/workflow/state.json ($bad_id)
"
        done
    fi
fi

# --- 本物のリポジトリの git 状態の検証(dispatch-run が起動時に git-state.txt に記録した値と比べる) ---
# タスク種別の判定(完了報告の必須項目と変更0件の判定で使う case)は、ここでも IS_PR を使うため
# この位置に置いている。PR 作成の run(IS_PR=true。タスクIDが pr- で始まる)は config を比べない
# (子が git push -u で .git/config を正当に変えるため)
case "$TASK_ID" in
    pr-*) IS_PR=true; REQUIRED='PR URL' ;;
    *) IS_PR=false; REQUIRED='変更ファイル|テスト結果' ;;
esac
# worktree.txt がある run(dispatch-worktree create 済み)は、worktree の中で git-state --run <branch> --parent <親の作業ブランチ> を
# 実行した値で比べ、変更の取得も worktree の中で行う(WT_DIR が空でなければ worktree の run)
WT_DIR=""
WT_BRANCH=""
WT_MISSING=false
if [ -f "$RUN_DIR/worktree.txt" ]; then
    WT_DIR="$(sed -n 's/^path //p' "$RUN_DIR/worktree.txt" | head -n 1 | tr -d '\r')"
    WT_BRANCH="$(sed -n 's/^branch //p' "$RUN_DIR/worktree.txt" | head -n 1 | tr -d '\r')"
    if [ -z "$WT_DIR" ] || [ ! -d "$WT_DIR" ]; then
        WT_MISSING=true
        GUARD_ISSUES="${GUARD_ISSUES}worktree not found: $WT_DIR
"
    fi
fi
GIT_STATE_PATH="$RUN_DIR/git-state.txt"
if [ ! -f "$GIT_STATE_PATH" ]; then
    GUARD_ISSUES="${GUARD_ISSUES}git-state.txt not found (deleted, or the run was not started by dispatch-run)
"
elif [ "$WT_MISSING" = true ]; then
    :
else
    RECORDED_STATE="$(LC_ALL=C tr -d '\r' < "$GIT_STATE_PATH")"
    # 実行権限に頼らず bash で呼ぶ(リポジトリ上のスクリプトは mode 100644 のため)
    if [ -n "$WT_DIR" ]; then
        PARENT_REF="$(git symbolic-ref -q HEAD 2> /dev/null || true)"
        [ -n "$PARENT_REF" ] || PARENT_REF=-
        OTHER_RUNS="$(python3 -c "
import json, sys
try:
    with open('.agents/workflow/state.json', encoding='utf-8') as f:
        tasks = json.load(f).get('tasks', [])
    print(','.join(str(e.get('id')) for e in tasks if e.get('id') != sys.argv[1] and e.get('status') in ('in_progress', 'in_review')))
except Exception:
    print('')
" "$TASK_ID" 2> /dev/null | tr -d '\r')"
        CURRENT_STATE="$(cd "$WT_DIR" && bash "$SCRIPT_DIR/git-state.sh" --run "$WT_BRANCH" --parent "$PARENT_REF" --other-runs "$OTHER_RUNS" 2> /dev/null | LC_ALL=C tr -d '\r')"
        # 親の作業ブランチが、起動時の参照名のまま、記録した値から進む方向にだけ動いたかを確かめる
        if [ ! -f "$RUN_DIR/parent-head.txt" ]; then
            GUARD_ISSUES="${GUARD_ISSUES}parent-head.txt not found
"
        else
            REC_PARENT_REF="$(sed -n 1p "$RUN_DIR/parent-head.txt" | tr -d '\r')"
            REC_PARENT_SHA="$(sed -n 2p "$RUN_DIR/parent-head.txt" | tr -d '\r')"
            CUR_PARENT_SHA="$(git rev-parse --verify -q HEAD 2> /dev/null || echo -)"
            PARENT_BAD=false
            if [ "$REC_PARENT_REF" != "$PARENT_REF" ]; then
                PARENT_BAD=true
            elif [ "$REC_PARENT_SHA" != "$CUR_PARENT_SHA" ]; then
                if [ "$REC_PARENT_SHA" = - ] || [ "$CUR_PARENT_SHA" = - ] || ! git merge-base --is-ancestor "$REC_PARENT_SHA" "$CUR_PARENT_SHA" 2> /dev/null; then
                    PARENT_BAD=true
                fi
            fi
            if [ "$PARENT_BAD" = true ]; then
                GUARD_ISSUES="${GUARD_ISSUES}git changed: parent
"
            fi
        fi
    else
        CURRENT_STATE="$(bash "$SCRIPT_DIR/git-state.sh" 2> /dev/null | LC_ALL=C tr -d '\r')"
    fi
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
# プロファイルの permission_denied_pattern に一致する行だけを対象にする(auto / opencode では
# 行頭の `! permission requested: ...; auto-rejecting`。子がスクリプトやテストを表示した出力の中の
# 同じ文字列には反応しない)。パターンは awk の -v だと \[ 等を解釈されるため環境変数で渡す。
# 空なら検査しない
DENIED_LINES="$(printf '%s\n' "$RAW_LOG" | DENIED_RE="$DENIED_RE" LC_ALL=C awk -v esc="$ESC" '
    BEGIN { pat = ENVIRON["DENIED_RE"] }
    pat == "" { next }
    { line = $0; gsub(esc "\\[[0-9;]*[A-Za-z]", "", line) }
    line ~ pat { print line }')"

# --- プロジェクト外(/tmp・ホームディレクトリ等)へのアクセスの検出 ---
# 権限を拒否されずに成功したプロジェクト外アクセス(例: bash -c "... > /tmp/x.log"、cat ~/x.log)を検出する。
# 対象はツール実行の記録行だけ(プロファイルの tool_call_pattern。auto / opencode では色付きマーカー行
# ($ / → / ← / ✱ / ✗ / ⚙ で始まるもの。! は権限拒否の行なので除く)と stream-json の [tool_use] 行)。
# ツールの出力(色なしの行・[tool_result] 行)や完了報告の本文には反応しない。パターンが空なら検査しない。
# 判定は ANSI エスケープを除いた行に対して行う。
# 条件の正規表現は outside_re と home_re にまとめる(条件を足したくなったらここへ追記する)。
# home_re はホームディレクトリ(~/・$HOME・${HOME}・$env:USERPROFILE・%USERPROFILE% 等)と
# Windows のユーザー一時ディレクトリ(AppData の Temp)への参照。大文字小文字を区別しないため、
# ANSI エスケープを除いた行を tolower() してから当てる。$env:TEMP・%TEMP%・$TMPDIR は
# dispatch-run によりプロジェクト内を指すため検出しない
OUTSIDE_LINES="$(printf '%s\n' "$RAW_LOG" | TOOL_CALL_RE="$TOOL_CALL_RE" LC_ALL=C awk -v esc="$ESC" '
    BEGIN {
        call_re = ENVIRON["TOOL_CALL_RE"]
        outside_re = "(^|[ \t\"'\''=(<>])\\/(var\\/)?tmp([\\/ \t\"'\'');]|$)"
        home_re = "(^|[ \t\"'\''=(<>])~\\/|\\$(\\{home\\}|home([^a-z0-9_]|$)|env:(home|userprofile)([^a-z0-9_]|$))|%userprofile%|appdata[\\\\/]local[\\\\/]temp"
    }
    {
        raw = $0
        if (call_re == "" || raw !~ call_re) next
        line = raw; gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
        if (line ~ outside_re || tolower(line) ~ home_re) print line
    }')"

# --- 子CLI自身のログのエラー検出(利用上限・エンドポイント障害などの切り分け用) ---
# config.json の child_agent.cli_log(子CLI自身のログファイルのパス。先頭の ~/ はホームディレクトリ)
# を読む(python3 が無い・config.json が読めない場合は空 = 未設定扱い)。末尾 200 行のうち ERROR を
# 含む行の最後の 5 行と、プロバイダー起因かどうか(利用上限・レート制限・エンドポイント障害・429。
# 429 の前後に英数字を許さないのは .429Z のようなタイムスタンプや16進の ID に一致させないため)を
# 出力に表示するだけなので、判定(Verdict・exit code)には影響しない
CLI_LOG="$(python3 -c "import json; print(json.load(open('.agents/workflow/config.json', encoding='utf-8'))['child_agent'].get('cli_log', ''))" 2>/dev/null | tr -d '\r')"
PROVIDER_ERROR=unknown
CLI_LOG_LINES=""
# provider_error_pattern が空のプロファイルでは、プロバイダー起因かどうかの判定をしない
if [ -n "$CLI_LOG" ]; then
    CLI_LOG_PATH="$CLI_LOG"
    case "$CLI_LOG" in
        "~"/*) CLI_LOG_PATH="$HOME/${CLI_LOG#"~/"}" ;;
    esac
    if [ ! -f "$CLI_LOG_PATH" ]; then
        CLI_LOG="$CLI_LOG (not found)"
    else
        PROVIDER_ERROR=no
        # NUL を含むと grep がバイナリ扱いするため、output.log と同じく NUL・CR を除いてから読む
        CLI_LOG_LINES="$(LC_ALL=C tr -d '\000\r' < "$CLI_LOG_PATH" | tail -n 200 | grep ERROR | tail -n 5)"
        if [ -n "$PROVIDER_RE" ] && [ -n "$CLI_LOG_LINES" ] && printf '%s\n' "$CLI_LOG_LINES" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C grep -Eq -e "$PROVIDER_RE"; then
            PROVIDER_ERROR=yes
        fi
    fi
fi

# --- 完了報告の判定 ---
# 最後に出現する `## 完了報告` だけを対象にし、その後にツール実行の記録が続く場合は無効とする
# (子がテンプレートやドキュメントを表示しただけの行に一致させないため)。ツール実行の記録は、
# プロファイルの tool_activity_pattern に一致する行に限る(auto / opencode では色付きのマーカー行
# (`ESC[0m$ ESC[0m...` 等)と stream-json の `[tool_use]` / `[tool_result]` 行。報告本文の
# `→ 要確認` や `$ npm test` は対象外。パターンが空なら記録は無いものとして扱う)。必須項目は
# 通常のタスクが「変更ファイル」「テスト結果」、PR 作成の run(pr-*)が「PR URL」。
# 区切りは半角 `:` と全角 `：` のどちらでもよい。
# 値が同じ行に無い場合は、次の行からのインデントされた箇条書きを値とみなす。
REPORT_RESULT="$(printf '%s\n' "$RAW_LOG" | TOOL_ACTIVITY_RE="$TOOL_ACTIVITY_RE" LC_ALL=C awk -v esc="$ESC" -v required="$REQUIRED" '
    BEGIN { act_re = ENVIRON["TOOL_ACTIVITY_RE"] }
    {
        raw = $0
        tool[NR] = (act_re != "" && raw ~ act_re)
        gsub(esc "\\[[0-9;]*[A-Za-z]", "", raw)
        lines[NR] = raw
    }
    lines[NR] ~ /^## 完了報告[ \t]*$/ { last = NR }
    END {
        if (!last) {
            # 最後の空でない行がツール実行の記録なら、子はその後に何も出力せずに終わった
            # (#50: 推論だけで出力トークン上限に達すると、opencode はエラーにせず exit 0 で終わる)
            for (i = NR; i >= 1; i--) if (lines[i] ~ /[^ \t]/) break
            if (i >= 1 && tool[i]) print "missing (no output after the last tool call; the model may have hit the output token limit)"
            else print "missing"
            exit
        }
        for (i = last + 1; i <= NR; i++) {
            if (tool[i]) { print "invalid (tool activity after the report at line " i ")"; exit }
        }
        end = NR
        for (i = last + 1; i <= NR; i++) if (lines[i] ~ /^## /) { end = i - 1; break }
        n = split(required, fields, "|")
        for (k = 1; k <= n; k++) {
            found = 0
            for (i = last + 1; i <= end; i++) {
                # 区切りは半角 `:` と全角 `：` のどちらも受け付ける(#55: 日本語で応答する子は全角で書くことがある)
                plen = 0
                if (index(lines[i], "- " fields[k] ":") == 1) plen = length("- " fields[k] ":")
                else if (index(lines[i], "- " fields[k] "：") == 1) plen = length("- " fields[k] "：")
                if (!plen) continue
                value = substr(lines[i], plen + 1)
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

# worktree の run は worktree の中で変更を取る(worktree が無いときは本体で取る)
git_in_wt() {
    if [ -n "$WT_DIR" ] && [ "$WT_MISSING" = false ]; then
        git -C "$WT_DIR" "$@"
    else
        git "$@"
    fi
}
CHANGES="$(git_in_wt status --porcelain)"
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

# --- 完了報告の report.md への書き出し(CODE が 0・7 = 完了報告が有効で改ざん・異常終了が無いとき) ---
# ブロックの範囲は完了報告の判定の awk と同じ: 最後の `## 完了報告` 行から、その後の最初の `## ` 行の
# 直前(無ければ末尾)まで。ANSI エスケープを除いた行で範囲を判定して書き出し、ブロック末尾の空行は
# 除く(最後に改行を1つだけ付ける)。既にあれば上書きしない(同じ run を再判定しても内容は同じため)
REPORT_PATH="$RUN_DIR/report.md"
REPORT_SAVED=""
if [ "$CODE" = 0 ] || [ "$CODE" = 7 ]; then
    if [ -f "$REPORT_PATH" ]; then
        REPORT_SAVED=1
    else
        REPORT_BODY="$(printf '%s\n' "$RAW_LOG" | LC_ALL=C awk -v esc="$ESC" '
            {
                line = $0
                gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
                lines[NR] = line
            }
            lines[NR] ~ /^## 完了報告[ \t]*$/ { last = NR }
            END {
                if (!last) exit
                end = NR
                for (i = last + 1; i <= NR; i++) if (lines[i] ~ /^## /) { end = i - 1; break }
                while (end > last && lines[end] ~ /^[ \t]*$/) end--
                for (i = last; i <= end; i++) print lines[i]
            }')"
        if [ -n "$REPORT_BODY" ]; then
            printf '%s\n' "$REPORT_BODY" > "$REPORT_PATH" && REPORT_SAVED=1
        fi
    fi
fi

echo "Run: ${TASK_ID}-${ATTEMPT}"
echo "Exit: ${EXIT_VALUE} (kind: ${KIND})"
echo "End: ${END_VALUE}"
echo "Profile: ${PROFILE_NAME}"
echo "Disabled checks: ${DISABLED_CHECKS:-none}"
if [ -n "$GUARD_ISSUES" ]; then
    echo "Guard: NG"
    printf '%s' "$GUARD_ISSUES" | sed 's/^/  /'
else
    echo "Guard: ok"
fi
if [ -z "$DENIED_RE" ]; then
    echo "Permission denied: disabled (profile: ${PROFILE_NAME})"
elif [ -n "$DENIED_LINES" ]; then
    echo "Permission denied: yes"
    printf '%s\n' "$DENIED_LINES" | sed 's/^/  /'
else
    echo "Permission denied: no"
fi
if [ -z "$TOOL_CALL_RE" ]; then
    echo "Outside access: disabled (profile: ${PROFILE_NAME})"
elif [ -n "$OUTSIDE_LINES" ]; then
    echo "Outside access: yes"
    printf '%s\n' "$OUTSIDE_LINES" | sed 's/^/  /'
else
    echo "Outside access: no"
fi
echo "CLI log: ${CLI_LOG:-(not configured)}"
if [ -n "$CLI_LOG_LINES" ]; then
    printf '%s\n' "$CLI_LOG_LINES" | sed 's/^/  /'
fi
if [ -z "$PROVIDER_RE" ]; then
    echo "Provider error: disabled (profile: ${PROFILE_NAME})"
else
    echo "Provider error: $PROVIDER_ERROR"
fi
echo "Completion report: ${REPORT_RESULT}"
if [ -n "$REPORT_SAVED" ]; then
    echo "Report: $REPORT_PATH"
fi
echo "Changes: ${CHANGE_COUNT}"
echo "Verdict: ${VERDICT}"
echo "--- git status --porcelain"
git_in_wt status --porcelain
echo "--- git diff --stat"
git_in_wt diff --stat
echo "--- output.log (last ${TAIL_LINES} lines)"
if [ -f "$LOG_PATH" ]; then
    # 切り詰められた output.log(先頭の NUL)をそのまま tail に渡すと stdout に NUL が流れるため除く
    LC_ALL=C tr -d '\000\r' < "$LOG_PATH" | tail -n "$TAIL_LINES"
else
    echo "(output.log not found)"
fi

# --- 次のアクションの判定(stdout の最後の行に出す) ---
# PR 作成の run(pr-*)はレビューしない。PR を検証して報告し、マージを待つ
case "$CODE" in
    0)
        if [ "$IS_PR" = true ]; then
            NEXT="wait-merge"
        elif [ -n "$WT_DIR" ]; then
            NEXT="collect $TASK_ID"
        else
            NEXT="review $TASK_ID"
        fi
        ;;
    8) NEXT="escalate reason=tampered" ;;
    4)
        if [ "$PROVIDER_ERROR" = yes ]; then
            NEXT="escalate reason=provider-error"
        elif [ "$KIND" = idle-timeout ]; then
            NEXT="escalate reason=idle-timeout"
        else
            NEXT="escalate reason=abnormal-exit"
        fi
        ;;
    6)
        if [ "$VERDICT" = permission-denied ]; then
            NEXT="escalate reason=permission-denied"
        else
            NEXT="escalate reason=outside-access"
        fi
        ;;
    5)
        case "$REPORT_RESULT" in
            "missing (no output after the last tool call"*) NEXT="escalate reason=token-limit" ;;
            *) NEXT="escalate reason=no-report" ;;
        esac
        ;;
    7) NEXT="escalate reason=no-changes" ;;
esac
echo "Next: $NEXT"

exit "$CODE"
