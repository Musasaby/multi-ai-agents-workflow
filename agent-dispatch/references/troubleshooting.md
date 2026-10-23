# agent-dispatch のトラブルシュートと reason ごとの詳細

`agent-dispatch/SKILL.md` からリンクされている。本文の手順で原因が分からないときに読む。
子CLI固有の確かめ方は `references/<CLI>.md`(opencode: `references/opencode.md`)に書く。

## 手動プロンプト作成

指摘事項が複雑で fix-notes に収まらない場合のみ、`dispatch-prompt-gen` を使わず、親が
`runs/<タスクID>-<試行回数>/prompt.md` を直接書く。`## 実装ルール`・テスト検証指示・
完了報告フォーマットは `dispatch-prompt-template.md` に準じる。書いたら `task-state <ID> start` の後、
`dispatch-run` を直接デタッチ起動する(`run_in_background` での直接起動は行わない):

```powershell
Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/scripts/dispatch-run.ps1 -TaskId T1 -Attempt 2"
```
```bash
nohup .agents/workflow/scripts/dispatch-run.sh T1 2 > /dev/null 2>&1 &
```

## 子のエラーの切り分け

`child_agent.idle_timeout_seconds` が設定されている場合、その時間 `output.log` が更新されずに
経過すると `dispatch-run` が子を止め、`done` マーカーが `EXIT:idle-timeout` で書き出される。
ハングや `idle-timeout` では、`child_agent.cli_log`(子CLI自身のログ。未設定なら子CLIの
デフォルトのログ先)の末尾の ERROR 行を確認する(`dispatch-check` も `CLI log:` 欄に出力する)。
利用上限(usage/rate limit)・プロバイダー障害(エンドポイントの 429・unavailable 等)を表す行が
あれば、子の作業の失敗ではなくプロバイダー側の問題が原因である可能性が高い(`Provider error: yes`)。

## 無効な検査の扱い

`dispatch-check` の `Disabled checks:` が `none` 以外なら、無効な検査(その子CLIでは検知できないこと)を
ユーザーへの報告に添え、検証では `output.log` の末尾を目で確かめる。

## dispatch-check の判定

`dispatch-check` は終了状態の区分・管理ファイルの改ざん検知(Guard)・権限拒否の有無・完了報告の判定・
変更件数・`git status --porcelain`・`git diff --stat`・`output.log` の末尾30行をまとめて出力し、
完了報告を `report.md` に保存する(出力の `Report:` 行)。完了報告は「`output.log` の最後の
`## 完了報告`」だけを対象にし、その後にツール実行の記録が続く場合や、必須項目(`- 変更ファイル:` /
`- テスト結果:`。PR 作成の run は `- PR URL:`。区切りは全角 `：` も可)が無い・テンプレートのままの
場合は無効とする。単体でも実行できる(`dispatch-check.sh T1 1` / `dispatch-check.ps1 -TaskId T1 -Attempt 1`)。

## reason ごとの詳細

### timeout

経過が `child_agent.timeout_seconds` を超えた(`dispatch-wait` の exit 3)。タスクを `in_progress` の
ままユーザーに報告する。ハングの可能性があるため、`output.log` の末尾と `cli_log` の ERROR 行も添える。

### provider-error / idle-timeout

子の作業の失敗ではないため `task-state <タスクID> retry` は使わない(retries は増やさない。
state.json は `in_progress` のまま)。ユーザーに状況(利用上限・プロバイダー障害で中断した旨と
成果物の有無)を報告し、モデル(`config.json` の `child_agent.command_template`)の切り替えの
承認を得てから、`task-state <タスクID> start` のまま次の試行番号で再dispatch する。試行番号 2 以上の
再dispatch には `fix-notes.md` が要るため、「前回はプロバイダーの利用上限(または障害)で中断した。
作業ツリーの変更は無い」等の事実を書く(テンプレート経由で子に引き継がれる)。
引き取る場合は [引き取り](#引き取り) の手順で `report.md` を書く。

### abnormal-exit

異常終了(非0・`signal:*`・`crashed:*`)。出力された成果物の有無(`git status` / `git diff --stat` に
変更があるか、`output.log` の末尾で作業がどこまで進んだか、完了報告があるか)をユーザーに報告し、
再dispatch するか、成果物を引き取るかの判断を仰ぐ。`signal:*` の場合は、外部から強制終了された
(メモリ逼迫・監督プロセス等)可能性が高いことも添える。
引き取る場合は [引き取り](#引き取り) の手順で `report.md` を書く。

### tampered

管理ファイルの改ざん・git 状態の変化(`prompt.md`・`state.json`・`tasks.md`・`config.json` が
`dispatch-run` の起動時から変わった・消えた、`guard.sha256`・`output.log`・`git-state.txt` が無い、
`output.log` が実行中に切り詰められた)。`Guard:` 欄の内容を添えてユーザーに報告する。
`state.json` / `tasks.md` が変わっている場合は、子の変更を戻すか(`git diff` / アーカイブとの比較)を
ユーザーに確認する。

`Guard:` 欄に `git changed:` がある場合(本物のリポジトリの git 状態が変わった。`git-state.txt` の
記録と現在の git 状態の比較で検出)は、`git log` / `git reflog` / `git config --local --list` で
変化の内容(どのコミット・参照・設定が変わったか)を確かめ、ユーザーに報告して復旧の要否を確認する。

### permission-denied

子CLIがプロジェクト外へのアクセス等を拒否されて終わった。`Permission denied:` 欄の拒否された
コマンドを添えてユーザーに報告する。再dispatch する場合は、拒否された操作をしなくて済むよう
fix-notes に方針を書く。

### outside-access

`Outside access: yes`。`Outside access:` 欄の該当行を添えてユーザーに報告する。再dispatch する場合は、
fix-notes に一時ファイルの置き場所(`$TMPDIR`)を書く(`dispatch-run` が `$TMPDIR`・`$TEMP`・`$TMP` を
プロジェクト内の `runs/<タスクID>-<試行回数>/tmp/` に設定済みなので、子はそこに置くことで検出を避けられる)。

### token-limit

子は最後のツール実行の後に応答を出力しきれずに打ち切られた(出力トークン上限に達した)可能性が高い。
確認方法は子CLIごとに異なる(セッションの記録で最後の assistant メッセージが出力トークン上限で
打ち切られていないかを見る。opencode: `references/opencode.md`)。親が確かめられない場合は、
ユーザーに確認を依頼する。この原因が濃厚な場合は、retries を消費する通常の再 dispatch の前に、
次の対処のどれかをユーザーに提案する:

1. タスクを細かく分ける(`agent-task-plan` の追加モードでタスクを分割する)
2. 実装方法・設計判断を計画(`tasks.md`)に具体的に書き、子の調査・推論量を減らす
3. 子のモデルの推論量(思考モード・reasoning トークン上限等)を下げる

### no-report

`Completion report:` 欄の理由と成果物の有無を添えてユーザーに報告する(子が途中で応答を終えた可能性がある)。

### no-changes

完了報告はあるが作業ツリーに変更が無い。タスクの受け入れ基準がファイルの変更を求めているなら失敗として
扱い、ユーザーに報告する。調査だけのタスクなど変更が無いのが正しい場合に限り、検証に進んでよい。

## 引き取り

親が子の作業を引き取った(子が時間切れ・異常終了した後に、親が残りの実装やテストを済ませた)とき:

1. `dispatch-check` は `report.md` を書かない。このままだと後続タスクの `dispatch-prompt-gen` が
   引き継ぎガード(exit 2)で止まる。
2. 親が `.agents/workflow/runs/<タスクID>-<最新の試行番号>/report.md` を、完了報告の書式
   (`## 完了報告`・`- 変更ファイル:`・`- テストコマンド:`・`- テスト結果:`・`- 備考:`)で書く。
   備考には親が引き取った理由(例: 子のテストが Bash の上限で打ち切られた)を書く。
   ファイルが既にあれば上書きしない。引き継ぎガードは最新の試行番号のディレクトリの `report.md` の
   有無だけを見る。
3. その後は通常どおり `agent-review-commit` に進む。

## `.config` の作成拒否

(`child_agent.isolate_xdg: true` で使っている場合)sandbox 環境で `.agents/workflow/.config` 配下の
ディレクトリ作成が権限不足等で拒否される場合は、以下のいずれかで対処する。

- **昇格実行**: ディレクトリ作成コマンドを管理者権限または昇格したコンテキストで実行する
- **事前作成**: `/agents-md-setup` 等のセットアップ時に、リポジトリのセットアップ権限で必要な
  ディレクトリを事前に作成しておく(子CLI固有のディレクトリは `references/<CLI>.md`)

対処後、事前チェックと実行の `XDG_CONFIG_HOME` / `XDG_DATA_HOME` 設定が正常に機能するようになる。

## 認証エラー

子CLIが認証エラー・`Unexpected server error` で失敗する場合。`child_agent.isolate_xdg` が `true` だと、
ホーム配下の認証情報が見えなくなる。sandbox 環境でなければ `isolate_xdg` を `false`(既定)にする。
sandbox 環境で `true` が必要な場合は、`.agents/workflow/.config` 配下で CLI のログインを行う
(コマンド例は `references/<CLI>.md`)。

## EEXIST

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` を設定した上で、子CLI起動時に
`EEXIST: file already exists, mkdir '~/.config/...'` 等のエラーが出る場合、テンプレートのエスケープや
環境変数の引き渡しに問題がある可能性がある。テンプレート内で `{prompt}` 以外の部分に `~`(チルダ)が
展開される等、意図しないパス解釈が起きていないか確認する。子CLI固有の原因は `references/<CLI>.md` を見る。

## 旧レイアウト

移行前の環境では `.agents/workflow/` 直下に `.dispatch-run.ps1` 等のスクリプトや `logs/`・`reports/`
ディレクトリが残っていることがある(`.dispatch-prompt-<タスクID>.md` も同様)。これらは新レイアウト
(`scripts/` 配下のスクリプト、`runs/<タスクID>-<試行回数>/` 配下の生成物)には自動移行されない。
`/agents-md-setup` または `/workflow-update` を実行し、旧レイアウトの検出・更新提案に従うこと。
