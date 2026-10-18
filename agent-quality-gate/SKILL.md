---
name: agent-quality-gate
description: プロジェクトの品質ゲート(typecheck / lint / test 等)を設定駆動で一括実行し、ステップごとの合否を構造化して報告する。config.json の quality_gate 定義、なければ package.json スクリプトから自動検出。マルチエージェント実装ワークフローの検証フェーズで再利用され、単体でも実行できる。
---

# 品質ゲート(quality gate)

typecheck・lint・test など複数の検証コマンドを**定義順に**実行し、
ステップごとの合否と、全体の PASS / FAIL を報告する。

このskillは特定のツール(vitest 等)に依存せず、**設定または自動検出**で
コマンドを解決するため、任意のプロジェクトで再利用できる。ワークフローの
検証フェーズ(`agent-review-commit` の最終ゲート)から呼ばれるほか、
実装の合間に単体で `/agent-quality-gate` として実行してもよい。

## 引数

- `--steps <name,...>`(任意): 実行するステップ名を絞り込む(例: `--steps typecheck,test`)
- `--fix`(任意): 実行前に自動修正を試みる(`lint`/`format` に `fix_command` が
  定義されている場合のみ。定義がなければ無視)

## ステップの解決(優先順)

`quality-gate` スクリプトが行う。解決順は config.json の `quality_gate.steps` → `package.json` の
自動検出で、どちらも解決できない場合や実行対象が0件の場合は中断する(仕様は
`.agents/workflow/README.md` の quality-gate の節)。

> **注意(npm 系以外のプロジェクト)**: 自動検出は `package.json` のみを対象とするため、
> Gradle / Cargo / Make 等では `quality_gate.steps` の `command` を config.json に**必ず明記**すること。

## 手順

`quality-gate` を実行する。解決順・実行・判定はスクリプトが行う。

- PowerShell: `.agents/workflow/scripts/quality-gate.ps1 [-Steps a,b] [-Fix]`
- POSIX: `.agents/workflow/scripts/quality-gate.sh [--steps a,b] [--fix]`

stdout の `Next:` 行に従い、`Result:` と各ステップの `PASS/FAIL/SKIP` 行を表にしてユーザーに報告する。
失敗ステップは stdout の末尾の抜粋を要約し、全文は `Logs:` のディレクトリにある。

## 責務の境界(重要)

- このskillは**検証と報告のみ**を行い、**コード修正はしない**(`--fix` による
  formatter/lint の自動修正を除く)。失敗をどう扱うか(修正依頼・コミット中止・
  ベースライン化)は呼び出し側(`agent-review-commit` またはユーザー)が判断する
- ワークフローから呼ばれた場合、FAIL(blocking)は最終ゲート不合格として扱われる
