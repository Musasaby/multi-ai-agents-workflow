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
- プロンプトは長文になるため、シェルエスケープ問題を避けて一時ファイル経由で渡す。
  `.agents/workflow/.dispatch-prompt-<タスクID>.md` にタスクプロンプトを書き込む
- **デタッチ起動**: 子エージェントを親プロセスの管理外で起動し、親のタイムアウト制限
  (例: OpenCode の10分上限)や親プロセス終了による子プロセスの巻き添え終了を防ぐため、
  `Start-Process`(PowerShell) / `nohup`+`&`(POSIX) でラッパースクリプトを起動する。
  `run_in_background` での直接起動は行わない
- **ラッパースクリプト**(PowerShell: `.agents/workflow/.dispatch-run.ps1`)が以下の責務を担う:
  - プロンプトを `.agents/workflow/.dispatch-prompt-<タスクID>.md` から読み込む
  - `XDG_CONFIG_HOME` / `XDG_DATA_HOME` をプロジェクト内ディレクトリに設定
  - stdin を閉じて CLI(`$null | <CLI> run $prompt`)を実行し、stdout/stderr を
    `.agents/workflow/logs/<タスクID>-<試行回数>.log` に書き出す
  - CLI 終了後、exit code と終了時刻(ISO 8601)を
    `.agents/workflow/logs/<タスクID>-<試行回数>.done` に書き出す
- **`.done` マーカーの仕様**:
  - パス: `.agents/workflow/logs/<タスクID>-<試行回数>.done`
  - 内容(2行):
    ```
    EXIT:<exit code(数値)。異常終了時は crashed:<エラーメッセージ>>
    END:<ISO 8601形式の終了時刻(例: 2026-07-09T15:30:00.0000000+09:00)>
    ```
  - 例:
    ```
    EXIT:0
    END:2026-07-09T15:30:00.0000000+09:00
    ```
- **デタッチ起動の実行例**:
  ```powershell
  # PowerShell: Start-Process でラッパースクリプトを非同期起動
  $env:XDG_CONFIG_HOME = ".agents/workflow/.config"
  $env:XDG_DATA_HOME = ".agents/workflow/.config"
  Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/.dispatch-run.ps1 -TaskId T1 -Attempt 1"
  ```
  ```bash
  # POSIX: nohup ＋ & でデタッチ起動
  nohup .agents/workflow/.dispatch-run.sh T1 1 > /dev/null 2>&1 &
  ```
- 起動直後、ユーザーが別ターミナル/別セッションでリアルタイム閲覧できるよう、以下のいずれかのコマンドを提示する(親エージェント自身が実行し続ける必要はない):
  ```powershell
  Get-Content .agents/workflow/logs/T1-1.log -Wait -Tail 20
  ```
  ```bash
  tail -f .agents/workflow/logs/T1-1.log
  ```
- `config.json` の `child_agent.timeout_seconds` は**親側ポーリング**(§4)で管理する。
  タイムアウトを超えた場合はタスクを `in_progress` のままユーザーに報告する
  (ログファイルには打ち切り時点までの出力が残るため、途中経過の確認に使える)

### 4. 完了検知と結果検証

- **ポーリングによる完了検知**: 親は一定間隔(推奨: 30秒)で `.done` マーカーファイルの
  存在を確認する。マーカーが存在すれば終了と判断し、マーカーの内容(exit code / 終了時刻)と
  ログファイル末尾を確認する
  ```powershell
  # PowerShell: ポーリングループ例
  $startTime = Get-Date
  $donePath = ".agents/workflow/logs/T1-1.done"
  $logPath = ".agents/workflow/logs/T1-1.log"
  $timeout = (Get-Content .agents/workflow/config.json | ConvertFrom-Json).child_agent.timeout_seconds
  while (-not (Test-Path $donePath)) {
      $elapsed = ((Get-Date) - $startTime).TotalSeconds
      if ($elapsed -gt $timeout) { Write-Warning "Timeout ($timeout 秒)"; break }
      # ハング検知: ログファイルの最終更新が10分以上前なら警告
      $log = Get-Item $logPath -ErrorAction SilentlyContinue
      if ($log -and ((Get-Date) - $log.LastWriteTime).TotalMinutes -gt 10) {
          Write-Warning "ログの更新が10分以上停止 - ハングの可能性"
      }
      Start-Sleep -Seconds 30
  }
  ```
  ```bash
  # POSIX: ポーリングループ例
  done=".agents/workflow/logs/T1-1.done"
  log=".agents/workflow/logs/T1-1.log"
  timeout=$(jq -r '.child_agent.timeout_seconds' .agents/workflow/config.json)
  start=$(date +%s)
  while [ ! -f "$done" ]; do
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -gt "$timeout" ] && echo "Timeout ($timeout 秒)" && break
    # ハング検知: ログファイルの最終更新が10分以上前なら警告
    if [ -f "$log" ] && [ "$(( $(date +%s) - $(stat -c %Y "$log") ))" -gt 600 ]; then
      echo "警告: ログの更新が10分以上停止 - ハングの可能性"
    fi
    sleep 30
  done
  ```
- **タイムアウト管理**: `config.json` の `child_agent.timeout_seconds`(デフォルト: 3600秒)を
  親側のポーリングループ内で監視する。タイムアウト超過時はループを抜け、タスクを
  `in_progress` のままユーザーに報告する
- **ハング検知**: ポーリングループ内で、ログファイルの最終更新時刻が10分以上前の場合に
  警告を出力する。ハングの可能性があるためユーザーに報告する
- 完了確認後、子エージェントの出力(.log ファイル)と `git status` / `git diff --stat` を突き合わせる:
  - 完了報告フォーマットが出力に含まれているか
  - テスト結果が「全件パス」か。失敗が残っている・テスト結果の記載がない場合は
    **レビューに進まず**、その旨を指示に含めて再dispatchする(`max_fix_retries` の範囲内)
  - 変更ファイル一覧と実際の diff が大きく食い違う場合は異常としてユーザーに報告

### 5. 状態更新

検証を通過したら state.json を `in_review` に更新し、子エージェントの完了報告を
`.agents/workflow/reports/<タスクID>-<試行回数>.md` に保存して、レビューフェーズ
(`/agent-review-commit`)に引き継ぐ。ログファイル(`.agents/workflow/logs/<タスクID>-<試行回数>.log`)は
削除せず残す(リトライ時の比較や事後調査に使えるため。`.gitignore` 済みでコミットはされない)。

## トラブルシューティング

### `.agents/workflow/.config` 配下のディレクトリ作成が拒否される

`sandbox` 環境で `.agents/workflow/.config` や `.agents/workflow/.config/opencode/log` ディレクトリの作成が権限不足等で拒否される場合は、以下のいずれかで対処する。

- **昇格実行**: ディレクトリ作成コマンドを管理者権限または昇格したコンテキストで実行する
- **事前作成**: `/agents-md-setup` 等のセットアップ時に、リポジトリのセットアップ権限で `.agents/workflow/.config/opencode/log` を事前に作成しておく

上記の対処後、事前チェックと実行の `XDG_CONFIG_HOME` / `XDG_DATA_HOME` 設定が正常に機能するようになる。

### それでも `EEXIST` 等のエラーが出る場合

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` を設定した上で、子エージェントCLI起動時に `EEXIST: file already exists, mkdir '~/.config/...'` 等のエラーが出る場合、テンプレートのエスケープや環境変数の引き渡しに問題がある可能性がある。テンプレート内で `{prompt}` 以外の部分に `~` (チルダ)が展開される等、意図しないパス解釈が起きていないか確認する。
