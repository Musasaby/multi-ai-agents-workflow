#!/bin/bash
# 全テスト(tests/test-*.sh)を名前順に実行する。
# --jobs <N> でテストファイル単位の並列実行(既定は 1 = 直列)。
# 直列では各テストの出力をそのまま流し、各ファイルが終わり次第
# PASS / FAIL と所要秒数を 1 行ずつ出す(作業ディレクトリは作らない)。
# 並列では各ファイルの出力をログに隔離し、実行後に
# 「----- ファイル -----」→ そのログ → その直後に PASS / FAIL の順で出す。
# 最後に失敗したファイルの一覧(または ALL PASSED)を出す。
# 1 本でも失敗すれば exit 1、すべて成功なら exit 0。
# (syntax-check.ps1 は品質ゲートとして別に実行するため、ここには含めない)
set -u
cd "$(dirname "$0")/.." || exit 1

jobs=1
prev=""
for arg in "$@"; do
    if [ "$prev" = "--jobs" ]; then
        case "$arg" in
            ''|*[!0-9]*) echo "ERROR: --jobs requires a positive integer" >&2; exit 2 ;;
        esac
        [ "$arg" -ge 1 ] || { echo "ERROR: --jobs requires a positive integer" >&2; exit 2; }
        jobs="$arg"
    elif [ "$prev" = "" ]; then
        case "$arg" in
            --jobs) ;;
            *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
        esac
    fi
    prev="$arg"
done
if [ "$prev" = "--jobs" ]; then
    echo "ERROR: --jobs requires a value" >&2
    exit 2
fi

files=""
for f in tests/test-*.sh; do
    [ -e "$f" ] || continue
    files="$files $f"
done
[ -n "$files" ] || { echo "ALL PASSED: 0 files"; exit 0; }
total=0
for f in $files; do
    total=$((total + 1))
done

failed=0
failed_files=""

# 1 ファイルを実行する(直列・並列で同じ起動方法)。
# 第 2 引数(ログ出力先)が指定された場合は並列用: 出力をそのファイルに隔離し、
# 結果を "$run_root/<base>.status" に「PASS/FAIL と所要秒数」で書く。
# 第 2 引数が無い場合は直列用: 出力をそのまま流し、終了コードで成否を返す。
run_one() {
    f="$1"
    base="$(basename "$f" .sh)"
    SECONDS=0
    if [ -n "${2:-}" ]; then
        if bash "$f" >"$2" 2>&1; then
            printf 'PASS\t%s\t%s\n' "$f" "$SECONDS" >"$run_root/$base.status"
            return 0
        fi
        printf 'FAIL\t%s\t%s\n' "$f" "$SECONDS" >"$run_root/$base.status"
        return 1
    fi
    bash "$f"
}

if [ "$jobs" -eq 1 ]; then
    # 直列実行: 各テストの出力をそのまま流し、終わり次第結果を 1 行ずつ出す
    for f in $files; do
        if run_one "$f"; then
            echo "PASS: $f (${SECONDS}s)"
        else
            failed=$((failed + 1))
            failed_files="$failed_files $f"
            echo "FAIL: $f (${SECONDS}s)"
        fi
    done
else
    # 並列実行: ログ・結果を出す作業ディレクトリを 1 つだけ作り、終了時に消す
    run_root="$(mktemp -d)"
    trap 'rm -rf "$run_root"' EXIT

    # 同時実行数を jobs に制限してバックグラウンド起動
    running=0
    for f in $files; do
        run_one "$f" "$run_root/$(basename "$f" .sh).log" &
        running=$((running + 1))
        if [ "$running" -ge "$jobs" ]; then
            wait -n 2>/dev/null || wait
            running=$((running - 1))
        fi
    done
    wait

    # 各ファイルごとに「ヘッダ → ログ → その直後に結果行」の順に出す
    for f in $files; do
        base="$(basename "$f" .sh)"
        echo "----- $f -----"
        cat "$run_root/$base.log" 2>/dev/null
        line=""
        [ -e "$run_root/$base.status" ] && line="$(cat "$run_root/$base.status")"
        result="FAIL"
        secs="0"
        case "$line" in
            PASS*)
                result="PASS"
                secs="$(printf '%s' "$line" | cut -f3)"
                ;;
            FAIL*)
                failed=$((failed + 1))
                failed_files="$failed_files $f"
                secs="$(printf '%s' "$line" | cut -f3)"
                ;;
            *)
                # status ファイルが無い(起動に失敗した等)場合はそのファイルを FAIL として扱う
                failed=$((failed + 1))
                failed_files="$failed_files $f"
                ;;
        esac
        echo "$result: $f (${secs}s)"
    done
fi

echo
if [ "$failed" -gt 0 ]; then
    echo "FAILED: $failed/$total"
    for f in $failed_files; do
        echo "  $f"
    done
    exit 1
fi
echo "ALL PASSED: $total files"
