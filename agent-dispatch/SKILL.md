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
- 初回dispatch前に、親側で quality_gate の typecheck コマンド(config.json の quality_gate.steps 内の blocking な typecheck の command)を1回実行してデーモンを起動しキャッシュを温めておく。具体例: `./gradlew compileDebugKotlin`

### 2. プロンプト生成(生成スクリプトの実行とexit code分岐)

プロンプトの組み立ては親エージェント(LLM)が行わない。定型文(実装ルール・テスト検証指示・
完了報告フォーマット等)は `.agents/workflow/scripts/dispatch-prompt-template.md` に
テンプレートとして配布済みであり、`dispatch-prompt-gen`(PowerShell:
`.agents/workflow/scripts/dispatch-prompt-gen.ps1` / POSIX: `dispatch-prompt-gen.sh`)が
tasks.md・config.json・依存タスクの完了報告を機械結合して
`.agents/workflow/runs/<タスクID>-<試行回数>/prompt.md` を生成する。

```powershell
# PowerShell(初回 = Attempt省略で1、リトライは -Attempt <n>)
.agents/workflow/scripts/dispatch-prompt-gen.ps1 -TaskId T3
.agents/workflow/scripts/dispatch-prompt-gen.ps1 -TaskId T3 -Attempt 2
```
```bash
# POSIX
.agents/workflow/scripts/dispatch-prompt-gen.sh T3
.agents/workflow/scripts/dispatch-prompt-gen.sh T3 2
```

**exit code で機械的に分岐する**(親はこのexit codeだけを見て判断すればよく、生成された
プロンプト全文を会話に読み込む必要はない):

- **exit 0**: 生成成功。`runs/<タスクID>-<試行回数>/prompt.md` を読まずに、そのまま
  §3 のデタッチ起動へ進む
- **exit 2**: 引き継ぎガード失敗(依存タスクが `done` でない、または依存タスクの
  `report.md` が見つからない)。stderr に欠落内容が列挙されるので、それをそのまま
  ユーザーに報告し、**dispatch は行わない**(古い prompt.md は生成スクリプト側で
  削除済み)
- **その他非0**(exit 1: tasks.md/state.json不備・タスクID未検出、exit 3:
  リトライなのに fix-notes.md が無い 等): stderr のエラー内容を添えてユーザーに
  報告し、dispatch は行わない

**親は生成されたプロンプトの全文を会話に読み込まない**(読み込むとスクリプト化による
トークン節約が無意味になる)。異常が疑われる場合のみ、`runs/<タスクID>-<試行回数>/prompt.md`
の先頭数十行を確認するにとどめる。

**フォールバック(手動プロンプト作成)**: 以下のいずれかに該当する場合のみ、親が
`runs/<タスクID>-<試行回数>/prompt.md` を直接作成してよい(生成スクリプトをバイパスする):

- リトライ時のレビュー指摘事項が複雑でテンプレートに収まらない場合
- 生成スクリプト自体が異常終了する(exit 1 等)場合の暫定対応

手動作成の場合も、`## 実装ルール`(AGENTS.md準拠・コミット禁止)・テスト検証指示・
完了報告フォーマットは `dispatch-prompt-template.md` の内容に準じること。

修正依頼(リトライ)の場合、レビュー指摘事項は `runs/<タスクID>-<試行回数>/fix-notes.md` に
親が保存し(要件の例外事項。ここだけは親のLLM出力)、生成スクリプトがそれを
プロンプト冒頭に結合する。`fix-notes.md` が無い状態で `-Attempt 2` 以上を実行すると
exit 3 になる。

### 3. 実行

- state.json の対象タスクを `in_progress` に更新
- **デタッチ起動**: 子エージェントを親プロセスの管理外で起動し、親のタイムアウト制限
  (例: OpenCode の10分上限)や親プロセス終了による子プロセスの巻き添え終了を防ぐため、
  `Start-Process`(PowerShell) / `nohup`+`&`(POSIX) でラッパースクリプトを起動する。
  `run_in_background` での直接起動は行わない
- **ラッパースクリプト**が存在しない場合(例: clone 直後で `/agents-md-setup` 未実行)、
  `_templates/workflow/scripts/dispatch-run.ps1`(または `.sh`)から
  `.agents/workflow/scripts/` にコピーする。
  POSIX 環境ではコピー後に `chmod +x .agents/workflow/scripts/dispatch-run.sh` を実行する。
  **既存のスクリプトは上書きしない**(利用先でカスタマイズ済みの可能性があるため)。
  同様に `dispatch-prompt-gen.ps1/.sh` と `dispatch-prompt-template.md` も
  `_templates/workflow/scripts/` から `.agents/workflow/scripts/` にコピーする。
- **ラッパースクリプト**(PowerShell: `.agents/workflow/scripts/dispatch-run.ps1`)が
  以下の責務を担う:
  - プロンプトを `.agents/workflow/runs/<タスクID>-<試行回数>/prompt.md` から読み込む
  - `XDG_CONFIG_HOME` / `XDG_DATA_HOME` をプロジェクト内ディレクトリに設定
  - **PowerShellのコンソールエンコーディングをUTF-8に設定する**(`[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` および `$OutputEncoding = [System.Text.Encoding]::UTF8` をスクリプト冒頭で実行)。
    `Start-Process` でデタッチ起動した子コンソールはOSのシステムロケール既定コードページ(日本語Windowsでは932/Shift_JIS)を引き継ぐため、未設定だとUTF-8で出力するCLIのstdout/stderrをリダイレクトする際に文字化けする
  - stdin を閉じて CLI(`$null | <CLI> run $prompt`)を実行し、stdout/stderr を
    `.agents/workflow/runs/<タスクID>-<試行回数>/output.log` に書き出す
  - CLI 終了後、exit code と終了時刻(ISO 8601)を
    `.agents/workflow/runs/<タスクID>-<試行回数>/done` に書き出す
- **`done` マーカーの仕様**:
  - パス: `.agents/workflow/runs/<タスクID>-<試行回数>/done`
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
  Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/scripts/dispatch-run.ps1 -TaskId T1 -Attempt 1"
  ```
  ```bash
  # POSIX: nohup ＋ & でデタッチ起動
  nohup .agents/workflow/scripts/dispatch-run.sh T1 1 > /dev/null 2>&1 &
  ```
  (XDG環境変数の設定はラッパースクリプト内で行われるため、起動コマンド側での設定は不要)
- 起動直後、ユーザーが別ターミナル/別セッションでリアルタイム閲覧できるよう、以下のいずれかのコマンドを提示する(親エージェント自身が実行し続ける必要はない):
  ```powershell
  Get-Content .agents/workflow/runs/T1-1/output.log -Wait -Tail 20
  ```
  ```bash
  tail -f .agents/workflow/runs/T1-1/output.log
  ```
  **Claude Code を子エージェントとして使う場合**: `command_template` に
  `--output-format stream-json --verbose` を指定すると、`dispatch-run` が
  出力を1行ずつパースして人が読めるテキストとして `output.log` に逐次書き出す
  (生JSONは `output.jsonl` に残る)ため、上記コマンドでの実行中閲覧が機能する。
  デフォルトの `--output-format text` は子CLI側でバッファリングされ実行中の
  逐次閲覧ができないため、実行中のログ閲覧が必要な場合は `stream-json` を使うこと。
- `config.json` の `child_agent.timeout_seconds` は**親側ポーリング**(§4)で管理する。
  タイムアウトを超えた場合はタスクを `in_progress` のままユーザーに報告する
  (ログファイルには打ち切り時点までの出力が残るため、途中経過の確認に使える)

### 4. 完了検知と結果検証

- **ポーリングによる完了検知**: 親は一定間隔(推奨: 30秒)で `done` マーカーファイルの
  存在を確認する。マーカーが存在すれば終了と判断し、マーカーの内容(exit code / 終了時刻)と
  ログファイル末尾を確認する
  ```powershell
  # PowerShell: ポーリングループ例
  $startTime = Get-Date
  $donePath = ".agents/workflow/runs/T1-1/done"
  $logPath = ".agents/workflow/runs/T1-1/output.log"
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
  done=".agents/workflow/runs/T1-1/done"
  log=".agents/workflow/runs/T1-1/output.log"
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
- **ポーリング実行の上限への注意**: 上記のポーリングループは親エージェントのコマンド実行上限
  (例: OpenCode の Bash/PowerShell ツールは最大10分)を超えると途中で打ち切られる。
  1回のポーリング実行は親ツールのコマンド上限未満(例: 8分=480秒)で区切り、
  `done` 未検出なら再度ポーリングコマンドを実行する。累計経過時間で `timeout_seconds` を
  判定する。上記のサンプルコードは `timeout_seconds` が小さく1回のポーリング内で
  完結する場合の例示であり、実際の利用時は適宜分割すること
- **ハング検知**: ポーリングループ内で、ログファイルの最終更新時刻が10分以上前の場合に
  警告を出力する。ハングの可能性があるためユーザーに報告する
- 完了確認後、子エージェントの出力(`output.log`)と `git status` / `git diff --stat` を突き合わせる:
  - 完了報告フォーマットが出力に含まれているか
  - テスト結果が「全件パス」か。失敗が残っている・テスト結果の記載がない場合は
    **レビューに進まず**、その旨を指示に含めて再dispatchする(`max_fix_retries` の範囲内)
  - 変更ファイル一覧と実際の diff が大きく食い違う場合は異常としてユーザーに報告

### 5. 状態更新

検証を通過したら state.json を `in_review` に更新し、子エージェントの完了報告を
`.agents/workflow/runs/<タスクID>-<試行回数>/report.md` に保存して、レビューフェーズ
(`/agent-review-commit`)に引き継ぐ。この `report.md` は後続タスクの `dispatch-prompt-gen`
実行時に引き継ぎ資料として機械結合されるため、削除しないこと(`runs/` は `.gitignore`
済みでコミットはされない)。`output.log` も同様に残す(リトライ時の比較や事後調査に使えるため)。

## ユーザーへの報告

- **報告・説明はすべて日本語で行うこと**(AGENTS.md の再掲。このskillは実行のたびに
  読み込まれるため、ここに明記しておくことで日本語指定の効きを強くする)。子エージェントの
  出力が英語であっても、親がユーザーに向けて要約・報告する内容は日本語にすること
- **デタッチ起動直後**(§3完了時)に最低限報告する項目:
  - タスクID・試行回数(例: `T3-1`)
  - ログファイルパス(`output.log` の絶対/相対パス)
  - 実行中ログをリアルタイム閲覧するコマンド(§3で提示するもの)
- **完了検知後**(§4完了時)に最低限報告する項目:
  - exit code(`done` マーカーの内容)
  - テスト結果の検証結果(全件パスか、失敗があればその概要)
  - 次のフェーズ(レビューへ進む/再dispatchする/ユーザーへエスカレーションする)のどれになったか

## トラブルシューティング

### `.agents/workflow/.config` 配下のディレクトリ作成が拒否される

`sandbox` 環境で `.agents/workflow/.config` や `.agents/workflow/.config/opencode/log` ディレクトリの作成が権限不足等で拒否される場合は、以下のいずれかで対処する。

- **昇格実行**: ディレクトリ作成コマンドを管理者権限または昇格したコンテキストで実行する
- **事前作成**: `/agents-md-setup` 等のセットアップ時に、リポジトリのセットアップ権限で `.agents/workflow/.config/opencode/log` を事前に作成しておく

上記の対処後、事前チェックと実行の `XDG_CONFIG_HOME` / `XDG_DATA_HOME` 設定が正常に機能するようになる。

### それでも `EEXIST` 等のエラーが出る場合

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` を設定した上で、子エージェントCLI起動時に `EEXIST: file already exists, mkdir '~/.config/...'` 等のエラーが出る場合、テンプレートのエスケープや環境変数の引き渡しに問題がある可能性がある。テンプレート内で `{prompt}` 以外の部分に `~` (チルダ)が展開される等、意図しないパス解釈が起きていないか確認する。

### 旧レイアウト(`.dispatch-prompt-<タスクID>.md` / `logs/` / `reports/`)が残っている場合

移行前の環境では `.agents/workflow/` 直下に `.dispatch-run.ps1` 等のスクリプトや
`logs/`・`reports/` ディレクトリが残っていることがある。これらは新レイアウト
(`scripts/` 配下のスクリプト、`runs/<タスクID>-<試行回数>/` 配下の生成物)には
自動移行されない。`/agents-md-setup` または `/workflow-update` を実行し、旧レイアウトの
検出・更新提案に従うこと。
