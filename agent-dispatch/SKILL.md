---
name: agent-dispatch
description: タスクIDを引数に取り、子エージェント(OpenCode等、CLIコマンドテンプレートで指定)に実装とテスト実行を指示する。完了報告(変更ファイル一覧・テスト結果)を検証して返す。マルチエージェント実装ワークフローの実装フェーズ。
---

# 子エージェントへの実装dispatch

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.agents/workflow/scripts/<名>.ps1` を使い、位置引数を `-TaskId` `-Attempt` `-MaxWait` の名前付き引数に読み替える。報告・説明はすべて日本語で行う(子の出力が英語でも同じ)。

タスクを子エージェントCLIに依頼し、完了(プロセス終了)を検知して結果を検証する。

## 引数

- 第1引数: タスクID(例: `T1`)。省略時は `next-task` が出力するタスク
  (依存がすべて `done` の最初の `pending` タスク)
- `--agent-cmd "<テンプレート>"`: 子エージェントCLIのコマンドテンプレート。省略時は
  `.agents/workflow/config.json` の `child_agent.command_template`。`{prompt}` がタスクプロンプトに展開される

エージェント名をこのskill内に固定しないこと。テンプレートが正本である。
子CLIの種類は `child_agent.profile` で指定する(`.agents/workflow/README.md` の「子CLIのプロファイル」)。
子CLI固有の確かめ方は `references/<CLI>.md`(opencode: `references/opencode.md`)。

## 手順

### 1. 起動(dispatch-start)

`dispatch-start.sh <ID> [<試行回数>]` を1回実行する。事前チェック・プロンプト生成・`task-state start`・
デタッチ起動をスクリプトが順に行う。

```bash
.agents/workflow/scripts/dispatch-start.sh T3
```

stdout の最後の `Next:` 行で分岐する(exit code と reason は `.agents/workflow/README.md` の dispatch-start の節):

- **`Next: wait`**: 起動できた。Run ID・`Log:`・`Watch:` の行をユーザーに報告して §2 へ
- **`Next: switch-branch` / `Next: escalate`**: 起動していない。reason と stderr をユーザーに説明して中断する。
  `reason=launch` は state.json が `in_progress` のままなので、原因を直して同じ引数で再実行できる

**親は生成された prompt.md の全文を読み込まない**(異常が疑われる場合のみ先頭数十行)。

**リトライ(試行回数 2 以上)**: 先に、レビュー指摘事項を `runs/<タスクID>-<試行回数>/fix-notes.md` に
親が保存する(生成スクリプトがプロンプト冒頭に結合する)。無いと `dispatch-start` が止まる。
指摘が複雑で収まらない場合は
[手動プロンプト作成](references/troubleshooting.md#手動プロンプト作成)。

`child_agent.timeout_seconds` は `dispatch-wait`(§2)が判定する。超えたらタスクを `in_progress` のまま報告する。

### 2. 完了検知と結果検証

完了検知は `dispatch-wait` で行う。`done` マーカーを待ち、タイムアウトを判定し、done を検知したら
`dispatch-check` を実行してその結果を返す(`dispatch-check` の出力項目と完了報告の有効条件は
[dispatch-check の判定](references/troubleshooting.md#dispatch-check-の判定))。

```bash
.agents/workflow/scripts/dispatch-wait.sh T1 1 --max-wait 480
```

`--max-wait` は親ツールのコマンド実行上限より短くする(上限10分なら 480)。`Next: wait` なら、
`references/report-template.md` の「子の実行待ち」の1行を伝えてから同じコマンドを再実行する。
`Disabled checks:` が `none` 以外なら、報告に添えて `output.log` の末尾を目で確かめる
([無効な検査の扱い](references/troubleshooting.md#無効な検査の扱い))。
ハングや `idle-timeout` は `cli_log` の ERROR 行を見る
([子のエラーの切り分け](references/troubleshooting.md#子のエラーの切り分け))。

出力の最後の `Next:` 行で機械的に分岐する(`EXIT` の値を目視で解釈しない)。
各 reason の詳細は [reason ごとの詳細](references/troubleshooting.md#reason-ごとの詳細) の同名の見出し。

- **`Next: review <ID>`**: 正常終了かつ完了報告あり。下記の検証へ
- **`reason=timeout`**: 経過が `timeout_seconds` を超えた。`in_progress` のまま `output.log` 末尾を添えて報告
  ([詳細](references/troubleshooting.md#timeout))
- **`reason=provider-error` / `idle-timeout`**: 利用上限・障害・無応答。`retry` は使わず、ユーザーの承認を得て
  モデルを替え、fix-notes に事実を書いて次の試行番号で再dispatch
  ([詳細](references/troubleshooting.md#provider-error--idle-timeout))
- **`reason=abnormal-exit`**: レビューに進まない。成果物の有無を報告し、再dispatch か引き取りかを仰ぐ
  ([詳細](references/troubleshooting.md#abnormal-exit))
- **`reason=tampered`**: レビューに進まない。`Guard:` 欄を添えて報告し、`git changed:` があれば git の変化を調べて復旧の要否を確認
  ([詳細](references/troubleshooting.md#tampered))
- **`reason=permission-denied`**: 拒否されたコマンドを添えて報告。再dispatch は fix-notes に方針を書く
  ([詳細](references/troubleshooting.md#permission-denied))
- **`reason=outside-access`**: 該当行を添えて報告。再dispatch は fix-notes に `$TMPDIR` の使用を書く
  ([詳細](references/troubleshooting.md#outside-access))
- **`reason=token-limit`**: 出力上限で打ち切られた可能性。通常の再dispatch の前に、タスク分割・計画の具体化・
  推論量の低減のどれかをユーザーに提案
  ([詳細](references/troubleshooting.md#token-limit))
- **`reason=no-report`**: 完了報告が無い・無効。`Completion report:` 欄の理由を添えて報告
  ([詳細](references/troubleshooting.md#no-report))
- **`reason=no-changes`**: 変更0件。受け入れ基準が変更を求めるなら失敗として報告。変更が無いのが正しい
  調査タスクに限り検証へ進んでよい([詳細](references/troubleshooting.md#no-changes))
- **`Next:` 行が無い**: exit 1(使い方の誤り)。stderr をユーザーに伝える

#### 検証

`output.log` と `git status` / `git diff --stat` を突き合わせる:

- 完了報告フォーマットが出力に含まれているか
- テスト結果が「全件パス」か。失敗が残る・記載が無い場合は**レビューに進まず**、その旨を指示に含めて
  再dispatchする(`max_fix_retries` の範囲内)
- 変更ファイル一覧と実際の diff が大きく食い違う場合は異常としてユーザーに報告

### 3. 状態更新

検証を通過したら `task-state <タスクID> review` で `in_review` に更新し、`/agent-review-commit` に引き継ぐ。
完了報告は `dispatch-check` が `runs/<タスクID>-<試行回数>/report.md` に保存済み(手で保存しない)。
`report.md` は後続タスクの `dispatch-prompt-gen` が引き継ぎ資料として結合するため削除しない。
`output.log` も残す(リトライ時の比較や事後調査用)。

## ユーザーへの報告

報告は `agent-workflow/references/report-template.md` に従う(状況・起きたこと・次にすること)。
この skill で使う場面:

- **デタッチ起動直後**(「子の起動直後」): タスクID・試行回数(例: `T3-1`)、`output.log` のパス、`Watch:` 行
- **実行待ち**(「子の実行待ち」): 待ちが続く間は1行で経過を伝える
- **完了検知後**(「子の完了検知後」): 子が正常に終わったかと `dispatch-check` の検証結果、テスト結果、
  次のフェーズ(レビュー/再dispatch/エスカレーション)、`Disabled checks:` が `none` 以外ならその内容

## トラブルシューティング

[`.config` の作成拒否](references/troubleshooting.md#config-の作成拒否)・
[認証エラー](references/troubleshooting.md#認証エラー)・
[EEXIST](references/troubleshooting.md#eexist)・
[旧レイアウト](references/troubleshooting.md#旧レイアウト)は `references/troubleshooting.md` を見る。
