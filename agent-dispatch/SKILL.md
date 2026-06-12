---
name: agent-dispatch
description: タスクIDを引数に取り、子エージェント(OpenCode等、CLIコマンドテンプレートで指定)に実装とテスト実行を指示する。完了報告(変更ファイル一覧・テスト結果)を検証して返す。マルチエージェント実装ワークフローの実装フェーズ。
---

# 子エージェントへの実装dispatch

タスクを子エージェントCLIに依頼し、完了(プロセス終了)を検知して結果を検証する。

## 引数

- 第1引数: タスクID(例: `T1`)。省略時は state.json の最初の `pending` タスク
- `--agent-cmd "<テンプレート>"`: 子エージェントCLIのコマンドテンプレート。省略時は
  `.agents/workflow/config.json` の `child_agent.command_template` を使う。
  テンプレート内の `{prompt}` がタスクプロンプトに展開される

エージェント名をこのskill内に固定しないこと。テンプレートが正本である。

## 手順

### 1. 事前チェック

- `git status` で作業ツリーがクリーンであることを確認(未コミット変更があれば中断してユーザーに報告)
- state.json の対象タスクが `pending` または `in_progress`(リトライ)であることを確認
- 依存タスク(`依存:` 欄)がすべて `done` であることを確認
- 子エージェントCLIの疎通確認: コマンドテンプレートの先頭コマンドに `--version` 等を付けて実行し、正常終了することを確認。失敗した場合はエラー出力を添えて中断しユーザーに報告する

### 2. プロンプト組み立て

以下を含むプロンプトを作る(子エージェントは会話文脈を持たない前提で自己完結させる):

1. タスク定義全文(tasks.md の該当セクション: 目的・対象・受け入れ基準)
2. `AGENTS.md のルールに従うこと`
3. **テスト実行指示(必須)**: 「実装後、テストを実行し全件パスするまで修正すること。
   テストコマンド: `<config.json の test_command、または受け入れ基準に記載のコマンド>`」
4. 完了報告フォーマットの指定:
   ```
   ## 完了報告
   - 変更ファイル: <一覧>
   - テストコマンド: <実行したコマンド>
   - テスト結果: <パス/失敗の件数、失敗があればその内容>
   - 備考: <判断に迷った点、残課題>
   ```
5. 「コミットは行わないこと(コミットは親エージェントが行う)」

修正依頼(リトライ)の場合は、上記に加えてレビュー指摘事項を冒頭に明記する。

### 3. 実行

- state.json の対象タスクを `in_progress` に更新
- テンプレートの `{prompt}` を展開してCLIを実行する。プロンプトは長文になるため、
  シェルエスケープ問題を避けて一時ファイル経由で渡す:
  ```powershell
  $prompt = Get-Content .agents/workflow/.dispatch-prompt.md -Raw
  # テンプレート例: opencode run "{prompt}" → opencode run $prompt
  ```
- **stdin を必ず閉じて起動する**: 子エージェントCLIは stdin が TTY でない場合に
  パイプ入力(EOF まで)を待ち続けることがあり、非対話環境では stdin が開いたままだと
  無限にハングする。PowerShell では `$null | <CLI> run $prompt`、POSIX シェルでは
  `<CLI> run "$prompt" < /dev/null` の形で起動すること
- `run_in_background` で起動し、プロセス終了 = 完了通知として扱う
- `config.json` の `timeout_seconds` を超えたら打ち切り、タスクを `in_progress` のまま
  ユーザーに報告する

### 4. 結果検証

子エージェントの出力(stdout)と `git status` / `git diff --stat` を突き合わせる:

- 完了報告フォーマットが出力に含まれているか
- テスト結果が「全件パス」か。失敗が残っている・テスト結果の記載がない場合は
  **レビューに進まず**、その旨を指示に含めて再dispatchする(`max_fix_retries` の範囲内)
- 変更ファイル一覧と実際の diff が大きく食い違う場合は異常としてユーザーに報告

### 5. 状態更新

検証を通過したら state.json を `in_review` に更新し、子エージェントの完了報告を
`.agents/workflow/reports/<タスクID>-<試行回数>.md` に保存して、レビューフェーズ
(`/agent-review-commit`)に引き継ぐ。

## トラブルシューティング

### EEXIST: file already exists, mkdir '~/.config/...'

子エージェントCLI起動時に `EEXIST: file already exists, mkdir '~/.config/opencode'` 等のエラーが出てCLIが起動しない場合、サンドボックス環境でのホームディレクトリ書込制限が原因の可能性がある。

**回避策**: 子エージェントCLIの起動時に `XDG_CONFIG_HOME` をプロジェクト内の書き込み可能なディレクトリ(例: `.agents/workflow/.config`)に向ける。

```powershell
# PowerShell の例
$env:XDG_CONFIG_HOME = ".agents/workflow/.config"
$null | <コマンドテンプレートの先頭コマンド> run $prompt
```

```bash
# POSIX シェルの例
XDG_CONFIG_HOME=.agents/workflow/.config <コマンドテンプレートの先頭コマンド> run "$prompt" < /dev/null
```

これにより、CLIがホームディレクトリ直下の設定ディレクトリを作成しようとするのを防ぎ、プロジェクト内のサンドボックスで動作する。
