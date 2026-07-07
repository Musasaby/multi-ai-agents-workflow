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
  - **sandbox 環境で `~/.config` や `~/.local/share` 配下の作成が拒否される問題を回避するため、事前に `XDG_CONFIG_HOME` と `XDG_DATA_HOME` をプロジェクト内ディレクトリに設定して疎通確認する**:
    ```powershell
    # PowerShell
    $env:XDG_CONFIG_HOME = ".agents/workflow/.config"
    $env:XDG_DATA_HOME = ".agents/workflow/.config"
    <コマンドテンプレートの先頭コマンド> --version   # バージョン番号が返れば疎通OK
    ```
    ```bash
    # POSIX シェル
    XDG_CONFIG_HOME=.agents/workflow/.config XDG_DATA_HOME=.agents/workflow/.config <コマンドテンプレートの先頭コマンド> --version
    ```

### 2. プロンプト組み立て

以下を含むプロンプトを作る(子エージェントは会話文脈を持たない前提で自己完結させる):

1. タスク定義全文(tasks.md の該当セクション: 目的・対象・受け入れ基準)
2. `AGENTS.md のルールに従うこと`
3. **テスト実行指示(必須)**: 「実装後、テストを実行し全件パスするまで修正すること。
   テストコマンド: `<config.json の test_command、または受け入れ基準に記載のコマンド>`」
   - 親側の最終ゲートでは `quality_gate`(typecheck/lint/test 等)も検証されるため、
     `config.json` に `quality_gate` が定義されている場合は「以下の品質ゲートの
     blocking ステップも通すこと」を指示に加え、**各 blocking ステップの `name` と
     `command` をプロンプトに列挙する**(子は config.json を参照しない前提のため、
     コマンドを明示しないと実行できない。コミット前の手戻りを減らす)
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
- **実行時も `XDG_CONFIG_HOME` と `XDG_DATA_HOME` を事前チェックと同じ値に設定する**: sandbox 環境では
  `~/.config` や `~/.local/share` への書き込みが制限されるため、CLI起動前に必ずプロジェクト内ディレクトリを向けること
  ```powershell
  # PowerShell
  $env:XDG_CONFIG_HOME = ".agents/workflow/.config"
  $env:XDG_DATA_HOME = ".agents/workflow/.config"
  ```
  ```bash
  # POSIX シェル
  export XDG_CONFIG_HOME=.agents/workflow/.config
  export XDG_DATA_HOME=.agents/workflow/.config
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

### `.agents/workflow/.config` 配下のディレクトリ作成が拒否される

`sandbox` 環境で `.agents/workflow/.config` や `.agents/workflow/.config/opencode/log` ディレクトリの作成が権限不足等で拒否される場合は、以下のいずれかで対処する。

- **昇格実行**: ディレクトリ作成コマンドを管理者権限または昇格したコンテキストで実行する
- **事前作成**: `/agents-md-setup` 等のセットアップ時に、リポジトリのセットアップ権限で `.agents/workflow/.config/opencode/log` を事前に作成しておく

上記の対処後、事前チェックと実行の `XDG_CONFIG_HOME` / `XDG_DATA_HOME` 設定が正常に機能するようになる。

### それでも `EEXIST` 等のエラーが出る場合

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` を設定した上で、子エージェントCLI起動時に `EEXIST: file already exists, mkdir '~/.config/...'` 等のエラーが出る場合、テンプレートのエスケープや環境変数の引き渡しに問題がある可能性がある。テンプレート内で `{prompt}` 以外の部分に `~` (チルダ)が展開される等、意図しないパス解釈が起きていないか確認する。
