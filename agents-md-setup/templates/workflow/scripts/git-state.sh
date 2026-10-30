#!/bin/bash
set -uo pipefail

# カレントディレクトリのリポジトリの git 状態を4行で出力する。何も書き換えない。
# dispatch-run が子の起動時にこの出力を git-state.txt に記録し、dispatch-check が
# 実行後の出力と比べて、子がリポジトリのどこを変えたか(HEAD・ブランチ・参照・設定)を特定する。
# 出力形式(この順に4行。項目の取得に失敗したら値を "-" にする):
#   head <HEAD コミットの SHA-1(git rev-parse --verify -q HEAD)>
#   branch <HEAD の参照名(git symbolic-ref -q HEAD。例: refs/heads/main)>
#   refs <参照一覧の SHA-256(16進小文字)>: 参照一覧は
#        git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash の出力。
#        refs/remotes は push で正当に変わるため含めない
#   config <git rev-parse --git-path config が指すファイルの SHA-256(16進小文字)>
# git リポジトリの中でなければ(git rev-parse --git-dir が失敗したら)stderr に
# "not a git repository" を出して exit 1 する。

#   --ref <refname> を付けると、refs 行はその参照だけ
#   (git for-each-ref --format='%(objectname) %(refname)' <refname> の出力。無ければ空の出力)のハッシュにする。
#   ほかのブランチの参照が変わっても変わらない。ほかの行は変わらない
#   --run <自分の run のブランチの参照名> --parent <親の作業ブランチの参照名> を付けると、refs 行は既定の参照一覧から
#   次の行を除いたもののハッシュにする(worktree は ref を本体と共有しているため、ほかの run や親の動きを除く)
#     - 参照名が refs/heads/agents-run/ で始まり、--run の値と一致しない行(ほかの run のブランチ)
#     - 参照名が --parent の値と一致する行(--parent が - か空なら何も除かない)
#   --run と --parent は両方そろって使う。--ref とは一緒に使えない
#   --other-runs <ID,ID,...> は --run のときだけ使える。上の1つ目の「ほかの run のブランチ」の除外を、
#   参照名が refs/heads/agents-run/<ID>-<数字> で <ID> が --other-runs にある行に限る
#   (--other-runs が無い・空なら、自分以外の agents-run/* を何も除かない)
# 未知の引数・値が無いオプション・--run と --parent の片方だけ・--ref との併用は、
# stderr に使い方を出して exit 1 する。

USAGE="Usage: git-state.sh [--ref <refname> | --run <refname> --parent <refname> [--other-runs <ID,ID,...>]]"

# --- 引数 ---
REF_ARG=""
USE_REF=0
RUN_ARG=""
USE_RUN=0
PARENT_ARG=""
USE_PARENT=0
OTHER_RUNS=""
USE_OTHER=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)
            if [ $# -lt 2 ]; then
                echo "$USAGE" >&2
                exit 1
            fi
            REF_ARG="$2"
            USE_REF=1
            shift 2
            ;;
        --run)
            if [ $# -lt 2 ]; then
                echo "$USAGE" >&2
                exit 1
            fi
            RUN_ARG="$2"
            USE_RUN=1
            shift 2
            ;;
        --parent)
            if [ $# -lt 2 ]; then
                echo "$USAGE" >&2
                exit 1
            fi
            PARENT_ARG="$2"
            USE_PARENT=1
            shift 2
            ;;
        --other-runs)
            if [ $# -lt 2 ]; then
                echo "$USAGE" >&2
                exit 1
            fi
            OTHER_RUNS="$2"
            USE_OTHER=1
            shift 2
            ;;
        *)
            echo "$USAGE" >&2
            exit 1
            ;;
    esac
done
if [ "$USE_OTHER" -eq 1 ] && [ "$USE_RUN" -eq 0 ]; then
    echo "$USAGE" >&2
    exit 1
fi
if [ "$USE_RUN" -ne "$USE_PARENT" ] || { [ "$USE_REF" -eq 1 ] && [ "$USE_RUN" -eq 1 ]; }; then
    echo "$USAGE" >&2
    exit 1
fi

# --- リポジトリ判定 ---
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "not a git repository" >&2
    exit 1
fi

# --- head ---
HEAD_SHA="$(git rev-parse --verify -q HEAD 2> /dev/null)"
[ -n "$HEAD_SHA" ] || HEAD_SHA=-

# --- branch ---
BRANCH="$(git symbolic-ref -q HEAD)"
[ -n "$BRANCH" ] || BRANCH=-

# --- refs(sha256sum が無ければ shasum -a 256。dispatch-run.sh と同じ分岐) ---
if [ "$USE_REF" -eq 1 ]; then
    REF_LIST() { git for-each-ref --format='%(objectname) %(refname)' "$REF_ARG"; }
elif [ "$USE_RUN" -eq 1 ]; then
    REF_LIST() {
        git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash |
            awk -v run="$RUN_ARG" -v parent="$PARENT_ARG" -v others="$OTHER_RUNS" '
                BEGIN { prefix = "refs/heads/agents-run/"; list = "," others "," }
                { n = $2 }
                index(n, prefix) == 1 && n != run {
                    rest = substr(n, length(prefix) + 1)
                    if (others != "" && match(rest, /-[0-9]+$/) && index(list, "," substr(rest, 1, RSTART - 1) ",") > 0) next
                }
                parent != "" && parent != "-" && n == parent { next }
                { print }'
    }
else
    REF_LIST() { git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash; }
fi
if command -v sha256sum > /dev/null 2>&1; then
    REFS_SHA="$(REF_LIST | sha256sum | cut -d' ' -f1)"
else
    REFS_SHA="$(REF_LIST | shasum -a 256 | cut -d' ' -f1)"
fi

# --- config(git rev-parse --git-path config が指すファイル。無ければ -) ---
CONFIG_FILE="$(git rev-parse --git-path config)"
CONFIG_SHA=-
if [ -f "$CONFIG_FILE" ]; then
    if command -v sha256sum > /dev/null 2>&1; then
        CONFIG_SHA="$(sha256sum "$CONFIG_FILE" | cut -d' ' -f1)"
    else
        CONFIG_SHA="$(shasum -a 256 "$CONFIG_FILE" | cut -d' ' -f1)"
    fi
fi

echo "head $HEAD_SHA"
echo "branch $BRANCH"
echo "refs $REFS_SHA"
echo "config $CONFIG_SHA"
exit 0
