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

1. **config.json の `quality_gate.steps`**(正本): 各ステップは以下の形:
   ```json
   {
     "name": "typecheck",
     "command": "npm run typecheck",
     "blocking": true,
     "fix_command": null
   }
   ```
   - `blocking`(省略時 `true`): `false` のステップは失敗しても全体を FAIL にしない
     (既存の未解消 lint 等のベースラインを段階的に解消したい場合に使う)
   - `fix_command`(省略可): `--fix` 指定時に、`command` の前に実行する自動修正コマンド
   - `command` が**空文字または未指定**の場合: リポジトリ直下 `package.json` に同名スクリプト
     (`<name>`)があれば `npm run <name>` を採用し、なければそのステップを
     **スキップ**する(テンプレートの雛形をそのまま置いても動くようにするため)
2. **`quality_gate` が未定義の場合**: リポジトリ直下の `package.json` の `scripts` から
   `typecheck` → `lint` → `test` の順に**存在するものだけ**を採用する
   (`npm run <name>`。`blocking` は typecheck/test=true, lint=false を既定とする)
3. どちらも解決できない場合は、その旨を報告して中断する(勝手にコマンドを推測しない)
4. **実行対象が0件になった場合も同様に中断する**: スキップや `--steps` フィルタの結果、
   実行するステップが1つも残らなかった場合は PASS とせず、「実行ステップなし」として
   報告して中断する(テンプレートの雛形をコマンド未記入のまま package.json のない
   プロジェクトに置いた場合などに、品質ゲートが素通りになるのを防ぐ)

> **注意(npm 系以外のプロジェクト)**: 自動検出は `package.json` のみを対象とする。
> Gradle / Cargo / Make 等のプロジェクトでは検出手段がないため、`quality_gate.steps` の
> `command` を config.json に**必ず明記**すること(例: `"command": "./gradlew test"`)。
> また、`test_command` と `quality_gate.steps` の test ステップの両方を定義する場合は、
> 内容が乖離しないよう**同じコマンドに揃える**こと(子エージェントへのテスト指示は
> `test_command`、親の最終ゲートは `quality_gate` を参照するため)。

## 手順

1. 上記の優先順でステップ一覧を解決する。`--steps` があれば名前でフィルタする
2. `--fix` 指定時、`fix_command` を持つステップについて先に修正コマンドを実行する
3. 各ステップを**定義順に**実行する:
   - 実行はプロジェクトルートで行う
   - 出力(stdout/stderr)と終了コードを取得する。以降のステップは、前段が
     `blocking` で失敗しても**続行**する(全ステップの結果を一度に集めるため)
   - 出力が長い場合は、失敗要因が分かる末尾〜要点のみを抜粋して保持する
4. 結果を集計して報告する(下記フォーマット)

## 報告フォーマット

```
## 品質ゲート結果: PASS | FAIL

| ステップ | コマンド | 結果 | blocking |
|---|---|---|---|
| typecheck | npm run typecheck | ✅ pass | yes |
| test | npm test --workspaces --if-present | ✅ pass (231) | yes |
| lint | npm run lint | ❌ fail (27 errors) | no |

- 全体判定: PASS(blocking ステップは全て pass。lint は non-blocking のため参考)
- 失敗ステップの要点:
  - lint: `packages/web/...` の no-explicit-any 等 27 件(抜粋を添付)
```

- **全体判定**: `blocking: true` のステップがすべて成功したら **PASS**、
  1つでも失敗したら **FAIL**
- `blocking: false` のステップの失敗は判定に影響しないが、**必ず結果を表示**して
  放置されないようにする

## 責務の境界(重要)

- このskillは**検証と報告のみ**を行い、**コード修正はしない**(`--fix` による
  formatter/lint の自動修正を除く)。失敗をどう扱うか(修正依頼・コミット中止・
  ベースライン化)は呼び出し側(`agent-review-commit` またはユーザー)が判断する
- ワークフローから呼ばれた場合、FAIL(blocking)は最終ゲート不合格として扱われる
