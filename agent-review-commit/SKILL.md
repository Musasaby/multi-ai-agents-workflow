---
name: agent-review-commit
description: 子エージェントの実装をタスクの受け入れ基準に照らしてレビューし、不合格なら修正を依頼、合格ならコミットする。テスト実行は子エージェント側の責務で、親はテスト結果報告の検証を行う。マルチエージェント実装ワークフローのレビュー・コミットフェーズ。
---

# レビュー・修正依頼・コミット

`in_review` 状態のタスクについて、変更内容をレビューし、合格したらコミットする。

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.agents/workflow/scripts/<名>.ps1` を使い、位置引数を `-TaskId` `-Type` `-Description` などの名前付き引数に読み替える。報告・説明はすべて日本語で行う。

## 引数

- 第1引数: タスクID。省略時は最初の `in_review` タスク

## 手順

### 1. レビュー材料の収集

- `git diff` / `git status` で変更全体を取得
- tasks.md の該当タスク(受け入れ基準)を読む
- `.agents/workflow/runs/<タスクID>-<試行回数>/report.md`(最新の試行回数のもの)の完了報告(テスト結果を含む)を読む

### 2. テスト結果の検証(親は実行せず報告を検証する)

テストの**実行**は子エージェントの責務。親は報告を次のとおり検証する:

- 完了報告にテストコマンドと結果(全件パス)が明記されているか
- タスクがテスト追加・変更を要求している場合、diff にテストコードが含まれているか
- 報告内容と diff に矛盾がないか(例: 「○○を修正」とあるのに該当ファイルに変更がない)
- 子の「既存エラー」報告は鵜呑みにせず、親側で再実行して検証する(増分コンパイル不整合による誤診の可能性)

報告が欠落・曖昧・矛盾していれば不合格とし、「テストを実行し結果を報告せよ」を指摘に含めて手順4へ。

### 3. コードレビュー

受け入れ基準を1項目ずつ diff と照合し、次の観点でも確認する:

- 正しさ: ロジックの誤り、エッジケース、エラーハンドリング
- スコープ: タスク外の無関係な変更が混入していないか
- 規約: AGENTS.md・周辺コードのイディオムとの整合
- セキュリティ: 入力検証、秘密情報のハードコード等

判定は **合格 / 不合格(指摘事項リスト付き)** の二択。

### 4. 不合格時: 修正依頼

原因(コードレビュー指摘 / 品質ゲート FAIL)にかかわらず、修正依頼は state.json の同じ `retries` を消費する
(上限 `max_fix_retries`)。修正依頼には原因種別を明記する。状態の更新は `task-state` で行い、state.json を直接編集しない。

- `retries < max_fix_retries`(config.json): 指摘事項をまとめて **子エージェントに再依頼**する。
  - 先に、指摘事項を `runs/<タスクID>-<現在の試行回数+1>/fix-notes.md` に親が保存する
    (**ここだけは親のLLM出力**。要件の例外事項)。`/agent-dispatch <タスクID>` を次の試行回数で
    リトライ実行すると `dispatch-prompt-gen` がこれをプロンプト冒頭に結合する。
    ファイルが無いまま試行回数 2 以上で実行すると `dispatch-start` が止まる
  - 並列実行中(`max_parallel` が 2 以上)は、dispatch-start が前の試行の変更を本体から取り除いて
    新しい worktree に持ち越す。親は本体を編集しない
  - `fix-notes.md` にはタスク固有の指摘だけを書き、「実装ルール」が定める事項は書かない
    (理由と、指摘がテンプレートに収まらないとき `prompt.md` を直接書く手順は
    [手動プロンプト作成](../agent-dispatch/references/troubleshooting.md#手動プロンプト作成))
  - `task-state <タスクID> retry` を実行し(`retries` を +1、status を `in_progress` に戻す)、
    `/agent-dispatch <タスクID>` をリトライモードで実行する(テスト再実行も指示に含まれる)
    ```bash
    .agents/workflow/scripts/task-state.sh T1 retry
    ```
  - `task-state` が **exit 4**(`retries` が上限)を返したら再依頼せず、下の「上限超過」に進む
- 上限超過: 親のサブエージェントまたは親自身で修正する。それでも満たせなければ `task-state <タスクID> fail` で `failed` にし、経緯をまとめてユーザーに
  エスカレーションする(ユーザー判断でやり直す場合は `task-state <タスクID> reset` で `pending` に戻す)

### 5. 合格時: 品質ゲートと理解確認質問の生成

(5.1 で FAIL(blocking) なら不合格に転じ、手順4へ戻る)

1. `config.json` の `verify_before_commit` が `true` の場合のみ、最終ゲートとして
   親が品質ゲートを1回実行する:
   - `quality_gate` が定義されていれば `/agent-quality-gate` を実行する。
     `blocking` ステップの失敗のみ不合格(`Next: escalate reason=quality-gate`)
   - non-blocking の失敗が自動修正できそうなら、コミット前に `--fix` 付きで再実行してもよい
     (生じた差分もコミット対象に含め、報告に明記する)
   - 未定義なら従来どおり `test_command` を1回実行する
   - FAIL(blocking)なら不合格で手順4へ。non-blocking の失敗はコミット可だが、報告の「残課題」に必ず記載する
2. `config.json` の `comprehension_check.enabled` が `true` の場合のみ、コミットの前に
   [references/comprehension-questions.md](references/comprehension-questions.md) の手順で質問ファイルを作る

### 6. 合格時: コミット(task-commit)

`.agents/workflow/scripts/task-commit.sh <ID> <type> "<説明>"` を実行する。
親が決めるのは `type` と説明(タスクタイトルに基づく1行)だけ。説明は `.agents/workflow/runs/refine/commit.md` に書き、`agent-workflow/references/report-template.md` の
「日本語の推敲」の手順(場面 `commit`)で推敲してから `task-commit` に渡す(`type` は推敲しない)。
次の処理はスクリプトが行う:

- `branch-check`(コミットしてよいブランチかの判定)
- 本体コミット(状態ファイルを除く。タスク単位で1コミット)
- `task-state done`(status を `done` にし、`commit` を記録)
- 状態ファイル(state.json・tasks.md・comprehension ファイル等)の `chore` コミット

出力の最後の行が `Next: continue` 以外なら、コミットが済んだと見なさず中断し、
`Next:` 行の reason と stderr の内容をユーザーに報告する。
`Next: continue` なら、進捗表示用のタスクを登録していれば(`agent-task-plan` §4。任意)完了に更新する。

## ユーザーへの報告

- 報告の書き方は `agent-workflow/references/report-template.md` に従う。この skill では次の場面を使う
- **レビュー結果**(手順3完了時): 合格 / 不合格の判定。不合格なら指摘事項の件数と概要(原因種別つき)
- **コミット完了時**(手順6完了時。task-commit の出力から): コミットハッシュ、タイトル行、
  品質ゲートの結果(non-blocking の失敗は残課題)、状態ファイルを別コミットにした場合はそのハッシュ
- **修正再依頼時**(手順4): retries 回数 / `max_fix_retries`、`fix-notes.md`(または直接作成した `prompt.md`)の保存先パス
