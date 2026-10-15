#!/bin/bash
# 全テスト(tests/test-*.sh)を名前順に直列実行する。
# 各ファイルの結果(PASS / FAIL と所要秒数)を 1 行ずつ出し、最後に失敗したファイルの一覧を出す。
# 1 本でも失敗すれば exit 1、すべて成功なら exit 0。
# (syntax-check.ps1 は品質ゲートとして別に実行するため、ここには含めない)
set -u
cd "$(dirname "$0")/.." || exit 1

total=0
failed=0
failed_files=""
for f in tests/test-*.sh; do
    [ -e "$f" ] || continue
    total=$((total + 1))
    SECONDS=0
    if bash "$f"; then
        echo "PASS: $f (${SECONDS}s)"
    else
        failed=$((failed + 1))
        failed_files="$failed_files $f"
        echo "FAIL: $f (${SECONDS}s)"
    fi
done

echo
if [ "$failed" -gt 0 ]; then
    echo "FAILED: $failed/$total"
    for f in $failed_files; do
        echo "  $f"
    done
    exit 1
fi
echo "ALL PASSED: $total files"
