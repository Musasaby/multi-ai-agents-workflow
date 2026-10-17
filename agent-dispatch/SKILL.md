---
name: agent-dispatch
description: タスクIDを引数に取り、子エージェント(OpenCode等、CLIコマンドテンプレートで指定)に実装とテスト実行を指示する。完了報告(変更ファイル一覧・テスト結果)を検証して返す。マルチエージェント実装ワークフローの実装フェーズ。
---

# 子エージェントへの実装dispatch

タスクを子エージェントCLIに依頼し、完了(プロセス終了)を検知して結果を検証する。

## 引数

- 第1引数: タスクID(例: `T1`)。省略時は `next-task`(PowerShell:
  `.agents/workflow/scripts/next-task.ps1` / POSIX: `next-task.sh`)が出力するタスク
  (state.json の並び順ではなく、依存がすべて `done` の最初の `pending` タスク)
- `--agent-cmd "<テンプレート>"`: 子エージェントCLIのコマンドテンプレート。省略時は
  `.agents/workflow/config.json` の `child_agent.command_template` を使う。
  テンプレート内の `{prompt}` がタスクプロンプトに展開される

エージェント名をこのskill内に固定しないこと。テンプレートが正本である。

## 手順

### 1. 起動(dispatch-start)

`dispatch-start`(PowerShell: `.agents/workflow/scripts/dispatch-start.ps1 -TaskId <ID> [-Attempt <n>]` /
POSIX: `dispatch-start.sh <ID> [<n>]`)を1回実行する。事前チェック(`branch-check --state`・作業ツリーの
クリーン確認・タスクの状態・疎通確認・初回のウォームアップ)、プロンプト生成、`task-state start`、
デタッチ起動をスクリプトが順に行う。

```powershell
.agents/workflow/scripts/dispatch-start.ps1 -TaskId T3
```
```bash
.agents/workflow/scripts/dispatch-start.sh T3
```

stdout の最後の `Next:` 行で機械的に分岐する(exit code の帯と reason は
`.agents/workflow/README.md` の dispatch-start の節):

- **`Next: wait`**: 起動できた。ユーザーに Run ID・`Log:`・`Watch:` の行を報告して §2 へ進む
- **`Next: switch-branch` / `Next: escalate`**: 起動していない。reason と stderr の内容をユーザーに
  説明して中断する

**親は生成された prompt.md の全文を会話に読み込まない**(読み込むとスクリプト化によるトークン節約が
無意味になる)。異常が疑われる場合のみ、先頭数十行を確認するにとどめる。

**リトライ(試行回数 2 以上)**: 先に、レビュー指摘事項を `runs/<タスクID>-<試行回数>/fix-notes.md` に
親が保存する(ここだけは親の LLM 出力)。生成スクリプトがそれをプロンプト冒頭に結合する。
`fix-notes.md` が無いと失敗する。

**フォールバック(手動プロンプト作成)**: 指摘事項が複雑で fix-notes に収まらない場合のみ、
`dispatch-prompt-gen` を使わず、親が `runs/<タスクID>-<試行回数>/prompt.md` を直接書く。
`## 実装ルール`・テスト検証指示・完了報告フォーマットは `dispatch-prompt-template.md` に準じる。
書いたら `task-state <ID> start` の後、`dispatch-run` を直接デタッチ起動する
(`run_in_background` での直接起動は行わない):

```powershell
Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/scripts/dispatch-run.ps1 -TaskId T1 -Attempt 2"
```
```bash
nohup .agents/workflow/scripts/dispatch-run.sh T1 2 > /dev/null 2>&1 &
```

**Claude Code を子エージェントとして使う場合**: `command_template` に
`--output-format stream-json --verbose` を指定すると、`dispatch-run` が出力を1行ずつ人が読める
テキストとして `output.log` に逐次書き出すため、実行中の閲覧が機能する
(生 JSON は `output.jsonl` に残る)。既定の `text` は子 CLI 側でバッファリングされる。

`config.json` の `child_agent.timeout_seconds` は**親側ポーリング**(§2)で管理する。
タイムアウトを超えた場合はタスクを `in_progress` のままユーザーに報告する。

### 2. 完了検知と結果検証

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
- **タイムアウト管理**: `config.json` の `child_agent.timeout_seconds`(デフォルト: 1800秒)を
  親側のポーリングループ内で監視する。タイムアウト超過時はループを抜け、タスクを
  `in_progress` のままユーザーに報告する
- **ポーリング実行の上限への注意**: 上記のポーリングループは親エージェントのコマンド実行上限
  (例: OpenCode の Bash/PowerShell ツールは最大10分)を超えると途中で打ち切られる。
  1回のポーリング実行は親ツールのコマンド上限未満(例: 8分=480秒)で区切り、
  `done` 未検出なら再度ポーリングコマンドを実行する。累計経過時間で `timeout_seconds` を
  判定する。上記のサンプルコードは `timeout_seconds` が小さく1回のポーリング内で
  完結する場合の例示であり、実際の利用時は適宜分割すること
- **ハング検知**: ポーリングループ内で、ログファイルの最終更新時刻が10分以上前の場合に
  警告を出力する。ハングの可能性があるためユーザーに報告する。`config.json` の
  `child_agent.idle_timeout_seconds` が設定されている場合は、その時間 `output.log` が
  更新されずに経過すると `dispatch-run` が子を止め、`done` マーカーが `EXIT:idle-timeout`
  で書き出され、`dispatch-check` が異常終了(区分 `idle-timeout`)の exit 4 になる。
  ハング検知をしたら(または `idle-timeout` で終了したら)、子のエラーの切り分けのために
  `child_agent.cli_log`(子CLI自身のログ。未設定なら子CLIのデフォルトのログ先。
  例: opencode は `~/.local/share/opencode/log/opencode.log`)の末尾の ERROR 行を
  確認する(`dispatch-check` も `CLI log:` 欄に出力する)。利用上限(usage/rate limit)・
  プロバイダー障害(エンドポイントの 429・unavailable 等)を表す行があれば、
  子の作業の失敗ではなくプロバイダー側の問題が原因である可能性が高い(`Provider error: yes`)
- **完了検知後は毎回 `dispatch-check` を実行し、出力の最後の `Next:` 行で機械的に分岐する**
  (`EXIT` の値を親が目視で解釈しない。非0終了の見落としを防ぐため)。
  `dispatch-check` は終了状態の区分・管理ファイルの改ざん検知(Guard)・権限拒否の有無・
  完了報告の判定・変更件数・`git status --porcelain`・`git diff --stat`・`output.log` の
  末尾30行をまとめて出力する。完了報告は「`output.log` の最後の `## 完了報告`」だけを対象にし、
  その後にツール実行の記録が続く場合や、必須項目(`- 変更ファイル:` / `- テスト結果:`。
  PR 作成の run は `- PR URL:`。区切りは全角 `：` も可)が無い・テンプレートのままの場合は無効とする
  (子がテンプレートを表示しただけの行を完了報告と誤認しないため)
  ```powershell
  .agents/workflow/scripts/dispatch-check.ps1 -TaskId T1 -Attempt 1
  ```
  ```bash
  .agents/workflow/scripts/dispatch-check.sh T1 1
  ```
  - **`Next: review <ID>`(exit 0)**(正常終了かつ完了報告あり): 下記の検証に進む
  - **`reason=abnormal-exit`(exit 4)**(異常終了: 非0・`signal:*`・`crashed:*`・`idle-timeout`): レビューには進まない。
    出力された成果物の有無(`git status` / `git diff --stat` に変更があるか、
    `output.log` の末尾で作業がどこまで進んだか、完了報告があるか)をユーザーに報告し、
    再dispatch するか、成果物を引き取るかの判断を仰ぐ。`signal:*` の場合は、外部から
    強制終了された(メモリ逼迫・監督プロセス等)可能性が高いことも添える
  - **`reason=idle-timeout` / `reason=provider-error`(exit 4)**(子CLIが無応答に
    なった・利用上限やプロバイダー障害に当たった): 子の作業の失敗ではないため
    `task-state <タスクID> retry` は使わない(retries は増やさない。state.json は
    `in_progress` のまま)。ユーザーに状況(利用上限・プロバイダー障害で中断した旨と
    成果物の有無)を報告し、モデル(`config.json` の `child_agent.command_template`)の
    切り替えの承認を得てから、`task-state <タスクID> start` のまま次の試行番号で
    再dispatch する。試行番号 2 以上の再dispatch には `fix-notes.md` が要るため、
    「前回はプロバイダーの利用上限(または障害)で中断した。作業ツリーの変更は無い」等の
    事実を書く(レビュー指摘事項ではないが、テンプレート経由で子に引き継がれる)
  - **`reason=tampered`(exit 8)**(管理ファイルの改ざん・git 状態の変化: `prompt.md`・`state.json`・`tasks.md`・
    `config.json` が `dispatch-run` の起動時から変わった・消えた、`guard.sha256`・`output.log`・
    `git-state.txt` が無い、`output.log` が実行中に切り詰められた): レビューには進まない。
    `Guard:` 欄の内容を添えてユーザーに報告する。`state.json` / `tasks.md` が変わっている場合は、
    子の変更を戻すか(`git diff` / アーカイブとの比較)をユーザーに確認する
  - **`reason=tampered` で `Guard:` 欄に `git changed:` がある場合**(本物のリポジトリの git 状態が変わった:
    `git-state.txt` の記録と現在の git 状態の比較で検出): レビューには進まない。
    `git log` / `git reflog` / `git config --local --list` で変化の内容(どのコミット・参照・設定が
    変わったか)を確かめ、ユーザーに報告して復旧の要否を確認する
  - **`reason=permission-denied`(exit 6)**(権限拒否で中断・プロジェクト外アクセスの検出: 子CLIがプロジェクト外への
    アクセス等を拒否されて終わった): レビューには進まない。`Permission denied:` 欄の拒否された
    コマンドを添えてユーザーに報告する。再dispatch する場合は、拒否された操作をしなくて済むよう
    fix-notes に方針を書く
  - **`reason=outside-access`(exit 6)**(プロジェクト外アクセスの検出:
    `Outside access: yes`): レビューには進まない。`Outside access:` 欄の該当行を添えて
    ユーザーに報告する。再dispatch する場合は、fix-notes に一時ファイルの置き場所(`$TMPDIR`)を
    書く(dispatch-run が `$TMPDIR`・`$TEMP`・`$TMP` をプロジェクト内の
    `runs/<タスクID>-<試行回数>/tmp/` に設定済みなので、子はそこに置くことで検出を避けられる)
  - **`reason=no-report`(exit 5)**(完了報告が無い・無効): `Completion report:` 欄の理由と成果物の有無を添えて
    ユーザーに報告する(子が途中で応答を終えた可能性がある)。
  - **`reason=token-limit`(exit 5)**: 子は最後のツール実行の後に応答を出力しきれずに
    打ち切られた(出力トークン上限に達した)可能性が高い。確認方法:
    opencode ならセッション DB(`~/.local/share/opencode/opencode.db` の `message` テーブル)で
    該当セッションの最後の assistant メッセージを見て、`finish` が `length`(出力トークン上限で
    打ち切り)であること、または `tokens` の `reasoning` が上限(例: 32000)に近いことを確かめる
    (親がセッション DB を確かめられない場合は、ユーザーに確認を依頼する)。
    この原因が濃厚な場合は、retries を消費する通常の再 dispatch の前に、次の対処のどれかを
    ユーザーに提案する:
    1. タスクを細かく分ける(`agent-task-plan` の追加モードでタスクを分割する)
    2. 実装方法・設計判断を計画(`tasks.md`)に具体的に書き、子の調査・推論量を減らす
    3. 子のモデルの推論量(思考モード・reasoning トークン上限等)を下げる
  - **`reason=no-changes`(exit 7)**(変更0件: 完了報告はあるが作業ツリーに変更が無い): タスクの受け入れ基準が
    ファイルの変更を求めているなら失敗として扱い、ユーザーに報告する。調査だけのタスクなど
    変更が無いのが正しい場合に限り、下記の検証に進んでよい
  - **`Next: wait`(exit 2)**: done マーカーが無い(まだ終了していない)。exit 1 は使い方不備
  - **`Next:` 行が無い**(exit 1。使い方の誤り): stderr の内容をユーザーに伝える
- 完了確認後、子エージェントの出力(`output.log`)と `git status` / `git diff --stat` を突き合わせる:
  - 完了報告フォーマットが出力に含まれているか
  - テスト結果が「全件パス」か。失敗が残っている・テスト結果の記載がない場合は
    **レビューに進まず**、その旨を指示に含めて再dispatchする(`max_fix_retries` の範囲内)
  - 変更ファイル一覧と実際の diff が大きく食い違う場合は異常としてユーザーに報告

### 3. 状態更新

検証を通過したら `task-state <タスクID> review` で state.json を `in_review` に更新し、子エージェントの完了報告を
`.agents/workflow/runs/<タスクID>-<試行回数>/report.md` に保存して、レビューフェーズ
(`/agent-review-commit`)に引き継ぐ。この `report.md` は後続タスクの `dispatch-prompt-gen`
実行時に引き継ぎ資料として機械結合されるため、削除しないこと(`runs/` は `.gitignore`
済みでコミットはされない)。`output.log` も同様に残す(リトライ時の比較や事後調査に使えるため)。

## ユーザーへの報告

- **報告・説明はすべて日本語で行うこと**(AGENTS.md の再掲。このskillは実行のたびに
  読み込まれるため、ここに明記しておくことで日本語指定の効きを強くする)。子エージェントの
  出力が英語であっても、親がユーザーに向けて要約・報告する内容は日本語にすること
- **デタッチ起動直後**(§1完了時)に最低限報告する項目:
  - タスクID・試行回数(例: `T3-1`)
  - ログファイルパス(`output.log` の絶対/相対パス)
  - 実行中ログをリアルタイム閲覧するコマンド(§1の `Watch:` 行)
- **完了検知後**(§2完了時)に最低限報告する項目:
  - exit code(`done` マーカーの内容)と `dispatch-check` の判定(Verdict)
  - テスト結果の検証結果(全件パスか、失敗があればその概要)
  - 次のフェーズ(レビューへ進む/再dispatchする/ユーザーへエスカレーションする)のどれになったか

## トラブルシューティング

### `.agents/workflow/.config` 配下のディレクトリ作成が拒否される

(`child_agent.isolate_xdg: true` で使っている場合)`sandbox` 環境で `.agents/workflow/.config` や `.agents/workflow/.config/opencode/log` ディレクトリの作成が権限不足等で拒否される場合は、以下のいずれかで対処する。

- **昇格実行**: ディレクトリ作成コマンドを管理者権限または昇格したコンテキストで実行する
- **事前作成**: `/agents-md-setup` 等のセットアップ時に、リポジトリのセットアップ権限で `.agents/workflow/.config/opencode/log` を事前に作成しておく

上記の対処後、事前チェックと実行の `XDG_CONFIG_HOME` / `XDG_DATA_HOME` 設定が正常に機能するようになる。

### 子エージェントCLIが認証エラー・`Unexpected server error` で失敗する

`child_agent.isolate_xdg` が `true` だと、`~/.local/share/opencode/auth.json` 等の認証情報が
見えなくなる。sandbox 環境でなければ `isolate_xdg` を `false`(既定)にする。sandbox 環境で
`true` が必要な場合は、`.agents/workflow/.config` 配下で CLI のログイン(例:
`XDG_CONFIG_HOME=.agents/workflow/.config XDG_DATA_HOME=.agents/workflow/.config opencode auth login`)を行う。

### それでも `EEXIST` 等のエラーが出る場合

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` を設定した上で、子エージェントCLI起動時に `EEXIST: file already exists, mkdir '~/.config/...'` 等のエラーが出る場合、テンプレートのエスケープや環境変数の引き渡しに問題がある可能性がある。テンプレート内で `{prompt}` 以外の部分に `~` (チルダ)が展開される等、意図しないパス解釈が起きていないか確認する。

### 旧レイアウト(`.dispatch-prompt-<タスクID>.md` / `logs/` / `reports/`)が残っている場合

移行前の環境では `.agents/workflow/` 直下に `.dispatch-run.ps1` 等のスクリプトや
`logs/`・`reports/` ディレクトリが残っていることがある。これらは新レイアウト
(`scripts/` 配下のスクリプト、`runs/<タスクID>-<試行回数>/` 配下の生成物)には
自動移行されない。`/agents-md-setup` または `/workflow-update` を実行し、旧レイアウトの
検出・更新提案に従うこと。
