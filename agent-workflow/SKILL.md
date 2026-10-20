---
name: agent-workflow
description: マルチエージェント実装ワークフローのオーケストレーター。GitHub Issue IDまたは計画ドキュメントのパスを引数に取り(省略時は state.json の source から再開)、タスク分解→子エージェントへの実装指示→レビュー→コミットをタスクごとにループ実行する。中断後の再実行で未完了タスクから再開する。
---

# マルチエージェント実装ワークフロー(オーケストレーター)

親エージェント(このskillの実行者)が計画とレビューを担い、実装とテスト実行を
子エージェント(CLI経由、エージェント名は引数/configで指定)に委譲する。

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.agents/workflow/scripts/<名>.ps1` を使い、`--branch` のようなオプションを `-Branch` の形の名前付き引数に読み替える。報告・説明はすべて日本語で行う(委譲先 skill の報告を中継・要約するときも同じ)。

## 引数

- 第1引数(任意): GitHub Issue ID または計画ドキュメントのパス。
  省略時は `.agents/workflow/state.json` の `source` を計画ソースとして再開する。
  state.json も無い場合はユーザーに計画ソースを質問する
- `--agent-cmd "<テンプレート>"`(任意): 子CLIのコマンドテンプレート(`{prompt}` 展開)。
  省略時は `.agents/workflow/config.json` の値
- タスク範囲(`T1~T3` 等)は引数で渡さない。次に処理するタスクは `next-task` スクリプトが、
  PR 作成・停止の範囲は tasks.md のグループ区切り(`<!-- グループ <名前> -->` 行、
  詳細は `agent-task-plan`)が決める

## 前提

- `agents-md-setup` 済みであること(`AGENTS.md` が正本、`.claude` リンク有効)。
  未了なら先に `/agents-md-setup` を実行
- 作業は `develop/*` ブランチで行う。`main` 上で開始された場合は
  `develop/<計画に基づく作業名>` ブランチを作成してから進める
- tasks.md のタスク実行**以外**の依頼(タスクの追加・計画の変更・ドキュメントや設定の
  変更 等)では、作業に着手する前に `agent-branch-guard` skill を使ってブランチを
  確かめる。グループ完了時のブランチ切替は従来どおり `group-advance` を使う

## グループ単位の PR とブランチ切替

tasks.md にグループ区切りがあり、config の `branch_per_group` が有効(既定)の場合、
グループが PR 作成・ブランチ切替の機械的な単位になる。次のタスクを選ぶ `next-task` が
`Next: group-advance`(作業グループ完了)を出したら、以下の手順に**必ず**従う。**グループ途中で
次のグループのタスクに進んではならない**。

1. `group-advance` を実行する。`--branch` には次のグループ用の新ブランチ名(`develop/` 始まり。
   MERGED 時のみ使用)を渡す。名前は親が計画・グループ名から決める(例: `develop/<作業名>-<グループ名>`)
   ```bash
   .agents/workflow/scripts/group-advance.sh --branch "develop/<作業名>-<グループ名>"
   ```
2. 出力の最後の `Next:` 行で分岐する:
   - **`Next: create-pr`**(PR 未作成): 先に「要件の充足確認」を行い、問題が無ければ
     「PR作成(子への単発依頼)」を必ず実行し、PR URL をユーザーに報告して停止する(マージはユーザーが行う)
   - **`Next: update-pr`**(PR はオープンだが、PR を作ったあとに足したコミットが未 push。
     stdout に `OPEN <PR URL>`): 先に「要件の充足確認」を行ってから「PR作成(子への単発依頼)」を実行する
     (子が push と PR 本文の作り直しを行う)。完了後に PR URL を報告して停止する。親は自分で
     `git push` や PR 本文の更新をしない。レビュー指摘への対応タスクを追加モードで同じグループに
     足して完了させたときに、この分岐になる
   - **`Next: wait-merge`**(マージ待ち。stdout に `OPEN <PR URL>`): 「マージ待ち」であることを
     PR URL とともに報告して停止する。マージ完了の連絡を受けて group-advance を再実行する
   - **`Next: escalate reason=pr-closed`**(PR が未マージのまま閉鎖): エスカレーションする
     (PR が閉じられた理由と再作成の要否をユーザーに確認する)
   - **`Next: continue`**(次グループへの切替完了): stdout の `ADVANCED <新ブランチ名> <新グループ名>` を
     確認する。state.json の更新とコミットは group-advance が行うので、親はコミットしない。
     新グループのタスクのループに進む

## フロー

```
1. 計画参照・タスク分解   → /agent-task-plan <引数>     (ユーザー承認を挟み、承認後に計画をコミット)
2. 各タスクについてループ(依存順。次のタスクは next-task スクリプトで選ぶ):
   a. 実装dispatch        → /agent-dispatch <タスクID>   (子がテスト実行まで担当)
   b. レビュー〜コミット   → /agent-review-commit <タスクID>
      - 不合格 → 子へ修正再依頼(リトライ上限あり) → b に戻る
      - 合格   → (verify_before_commit 有効時のみ)最終ゲート /agent-quality-gate
                 - FAIL(blocking) → 不合格扱いで修正再依頼へ(b に戻る)
                 - PASS → コミット(configで有効なら理解確認質問を生成)→ ループの先頭へ戻る
                   (next-task が `Next: group-advance` を出したら「グループ単位の PR とブランチ切替」の手順へ)
3. 全タスク完了 → サマリー報告(未回答の質問ファイル一覧を含む)
```

### 次のタスクの選び方

ループの各周回の先頭で `next-task`(`.agents/workflow/scripts/next-task.sh`)を実行し、
stdout の最後の `Next:` 行に従う: `dispatch <ID>` → `/agent-dispatch <ID>`、
`review <ID>` → `/agent-review-commit <ID>`、`finish` → 手順3、
`group-advance` → 「グループ単位の PR とブランチ切替」、`escalate` → reason と stderr を
ユーザーに説明する。`Next:` 行が無ければ stderr を添えて報告する。
語彙は `.agents/workflow/README.md` の「Next: 行」の節。
tasks.md の記述順や ID 順、state.json の並び順で次のタスクを決めない
(挿入したタスクの順序が崩れるため)。

## レビュー中に派生タスクが見つかった場合

コードレビューで新たな作業(派生タスク)が必要と判明した場合や、ユーザーがサイクル
途中で要件を追加した場合は、`/agent-task-plan` の**追加モード**(既存タスクを一切
書き換えず、新IDのセクションを tasks.md 末尾に追記するモード)を使う。既存タスク一覧の
再読・再提示は行わない。派生タスクを既存の未着手タスクより先に実行する必要がある場合は、
追加モードの**挿入**(`state-sync --insert <新ID> --before <後続ID>`)を使う。

## 一巡後の再実行

全タスク `done` で `/agent-task-plan` を再実行すると、作業ブランチの PR がマージ済みの
場合に限り、旧サイクルのファイルが `archive/` へ移され、新サイクルが空の状態から始まる。
PR が未マージなどで `workflow-archive` が止まった場合、残課題は追加モードで今のサイクルに足す
(詳細は `agent-task-plan` skill の §0)。

## 再開(レジューム)

開始時に `.agents/workflow/state.json` を確認する。未完了タスク(`pending` / `in_progress` /
`in_review`)が残っていて `source` が引数(省略時は state.json 自身の `source`)と一致するなら、
**手順1をスキップ**し、状態に応じたフェーズから再開する(`in_progress` → dispatch からやり直し、
`in_review` → レビューから)。`source` が引数と異なる場合は、進行中ワークフローの破棄可否を
ユーザーに確認する。state.json が無く引数も無ければ、ユーザーに計画ソースを質問する。

## 問題発生時の対応順序

問題(タスク失敗、子エージェントの異常終了、想定外の挙動等)が起きたら、切り分け → 機械的改善 →
ドキュメント改善 → エスカレーション → upstream への Issue 起票の順で検討する。
ワークフロー由来の問題を場当たり的な回避で押し通さず、利用先で skill・スクリプトを直さない。
5段階の説明と Issue 起票手順(ユーザー承認が必要)は `references/escalation.md` を読む。

## エスカレーション基準(ループを止めてユーザーに判断を仰ぐ)

- タスクが `failed` になった(修正リトライ上限超過後も受け入れ基準を満たせない)
- 子エージェントCLIが連続して異常終了・タイムアウトする
- タスク分解時点と前提が変わった(計画の矛盾、依存タスクの設計変更が必要 等)

## 要件の充足確認

PR 作成の前に、要件が満たされているかを親が確かめる(`req-status` と
`git diff origin/main...HEAD` を使い、要件ごとに「満たした / 部分 / 未対応」を判断する。
部分・未対応があれば PR 作成に進まず停止する)。手順は `references/pr.md` を読む。

## PR作成(子への単発依頼)

グループ完了時とサイクル完了時に、PR 作成を子エージェントへ単発で依頼する
(`dispatch-start --pr`。タスクではないので tasks.md / state.json には載せない)。
親は PR のタイトル・本文を自分で書かず、gh コマンドも直接実行しない。手順は `references/pr.md` を読む。

## 完了時のサマリー報告

先に `workflow-status --summary` を実行し、その出力をもとに
`references/report-template.md` の「完了時のサマリー」の形で下書きし、推敲を通してから示す。
項目と使う行は `references/pr.md` を読む。

## ユーザーへの報告

- 報告の形は `references/report-template.md` に従う
- **タスク1件が done になったとき**(リトライ途中は報告しない)に最低限報告する項目:
  タスクID・結果(done)、コミットハッシュ(コミット済みの場合)、リトライ回数。
  テンプレートの該当場面に従って `.agents/workflow/runs/refine/task_done.md` に下書きし、
  場面 `task_done` の推敲を通してから報告する
- ユーザーに判断を求めて停止するときは、場面 `confirm`(`.agents/workflow/runs/refine/confirm.md`)の
  推敲を通してから報告する
