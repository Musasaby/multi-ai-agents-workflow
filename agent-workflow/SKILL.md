---
name: agent-workflow
description: マルチエージェント実装ワークフローのオーケストレーター。GitHub Issue IDまたは計画ドキュメントのパスを引数に取り(省略時は state.json の source から再開)、タスク分解→子エージェントへの実装指示→レビュー→コミットをタスクごとにループ実行する。中断後の再実行で未完了タスクから再開する。
---

# マルチエージェント実装ワークフロー(オーケストレーター)

親エージェント(このskillの実行者)が計画とレビューを担い、実装とテスト実行を
子エージェント(CLI経由、エージェント名は引数/configで指定)に委譲する。

## 引数

- 第1引数(任意): GitHub Issue ID または計画ドキュメントのパス。
  省略時は `.agents/workflow/state.json` の `source` を計画ソースとして再開する。
  state.json も無い場合はユーザーに計画ソースを質問する
- `--agent-cmd "<テンプレート>"`(任意): 子エージェントCLIのコマンドテンプレート。
  `{prompt}` 展開。省略時は `.agents/workflow/config.json` の値
- タスク範囲(`T1~T3` 等)は引数で渡さない。次に処理するタスクは `next-task` スクリプトが、
  PR 作成・停止の範囲は tasks.md のグループ区切り(`<!-- グループ <名前> -->` 行、
  詳細は `agent-task-plan` skill)が決める

## 前提

- `agents-md-setup` 済みであること(`AGENTS.md` が正本、`.claude` リンク有効)。
  未了なら先に `/agents-md-setup` を実行する
- 作業は `develop/*` ブランチで行う。`main` 上で開始された場合は
  `develop/<計画に基づく作業名>` ブランチを作成してから進める
- tasks.md のタスク実行**以外**の依頼(タスクの追加・計画の変更・ドキュメントや設定の
  変更 等)では、作業に着手する前に `agent-branch-guard` skill を使ってブランチを
  確かめる。グループ完了時のブランチ切替は従来どおり `group-advance` を使う

## グループ単位の PR とブランチ切替

tasks.md にグループ区切りがあり、config の `branch_per_group` が有効(既定)の場合、
グループが PR 作成・ブランチ切替の機械的な単位になる。次のタスクを選ぶ `next-task` が
`Next: group-advance`(作業グループ完了)を出したら、以下の手順に**必ず**従う。**グループ途中で
次のグループのタスクに進んではならない**(next-task は現在の作業グループのタスクしか
選ばないため、この手順のループを守れば自然に防げる)。

1. `group-advance`(PowerShell: `.agents/workflow/scripts/group-advance.ps1` /
   POSIX: `group-advance.sh`)を実行する。`--branch`(PowerShell: `-Branch`)には
   次のグループ用の新ブランチ名(`develop/` 始まり。MERGED 時のみ使用)を渡す。
   ブランチ名は親が計画・グループ名から決める(例: `develop/<作業名>-<グループ名>`)
   ```powershell
   .agents/workflow/scripts/group-advance.ps1 -Branch "develop/<作業名>-<グループ名>"
   ```
   ```bash
   .agents/workflow/scripts/group-advance.sh --branch "develop/<作業名>-<グループ名>"
   ```
2. 出力の最後の `Next:` 行で分岐する:
   - **`Next: create-pr`**(exit 7。PR 未作成): 「PR作成(子への単発依頼)」を必ず実行し、
     PR URL をユーザーに報告して停止する(マージはユーザーが行う)
   - **`Next: update-pr`**(exit 10。PR はオープンだが、PR を作ったあとに足したコミットが未 push。
     stdout に `OPEN <PR URL>`): 「PR作成(子への単発依頼)」を実行する(子が push と PR 本文の
     作り直しを行う)。完了後に PR URL をユーザーに報告して停止する。親は自分で `git push` や
     PR 本文の更新をしない。レビュー指摘への対応タスクを追加モードで同じグループに足して
     完了させたときに、この分岐になる
   - **`Next: wait-merge`**(exit 8。マージ待ち。stdout に `OPEN <PR URL>`): PR がオープンのため
     「マージ待ち」であることを PR URL とともに報告して停止する。マージ完了の連絡を
     受けて group-advance を再実行する
   - **`Next: escalate reason=pr-closed`**(exit 9。PR が未マージのまま閉鎖):
     エスカレーションする(PR が閉じられた理由と再作成の要否をユーザーに確認する)
   - **`Next: continue`**(exit 0。次グループへの切替完了): stdout の
     `ADVANCED <新ブランチ名> <新グループ名>` を確認する(state.json の `branch` / `group` は
     group-advance が更新済み)。state.json のコミットは group-advance が行う
     (stdout の `State commit:` 行)。親がコミットする必要はない。新グループのタスクのループに進む

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

ループの各周回の先頭で `next-task`(PowerShell: `.agents/workflow/scripts/next-task.ps1`
/ POSIX: `next-task.sh`)を実行し、stdout の最後の `Next:` 行に従う: `dispatch <ID>` →
`/agent-dispatch <ID>`、`review <ID>` → `/agent-review-commit <ID>`、`finish` →
手順3、`group-advance` → 「グループ単位の PR とブランチ切替」、`escalate` →
reason と stderr をユーザーに説明する。`Next:` 行が無ければ stderr を添えて報告する。
語彙の一覧は `.agents/workflow/README.md` の「Next: 行」の節。
tasks.md の記述順や ID 順、state.json の並び順で次のタスクを決めない
(挿入したタスクの順序が崩れるため)。

## レビュー中に派生タスクが見つかった場合

コードレビューで新たな作業(派生タスク)が必要と判明した場合や、ユーザーがサイクル
途中で要件を追加した場合は、`/agent-task-plan` の**追加モード**(既存タスクを一切
書き換えず、新IDのセクションを tasks.md 末尾に追記するモード)を使う。既存タスク一覧の
再読・再提示は行わない。派生タスクを既存の未着手タスクより先に実行する必要がある場合は、
追加モードの**挿入**(`state-sync --insert <新ID> --before <後続ID>`)を使う。

## 一巡後の再実行

全タスクが `done` になった状態で `/agent-task-plan` を再度実行すると、既存の
tasks.md / state.json / runs/ / comprehension/ は自動的に `archive/<日時-スラッグ>/`
へアーカイブされ、新サイクルは空の状態から始まる(ユーザー確認は不要)。旧サイクルの
完了報告が新サイクルの同名タスクIDに誤って引き継がれることはない。

## 再開(レジューム)

開始時に `.agents/workflow/state.json` を確認する:

- 引数がある場合: 未完了タスク(`pending` / `in_progress` / `in_review`)が残っていて
  `source` が引数と一致するなら、**手順1をスキップ**し、状態に応じたフェーズから再開する
  (`in_progress` → dispatch からやり直し、`in_review` → レビューから)。`source` が
  引数と異なる場合は、進行中ワークフローの破棄可否をユーザーに確認する
- 引数がない場合: state.json が存在すればその `source` を計画ソースとみなして上記と同じ
  再開判定を行う。state.json が無ければユーザーに計画ソースを質問する

## 問題発生時の対応順序

ワークフロー実行中に問題(タスク失敗、子エージェントの異常終了、想定外の挙動等)が
発生した場合、以下の順序で対応を検討する。上位の段階で解決できなければ次の段階に進む:

1. **切り分け**: その問題が `multi-ai-agents-workflow` 由来(オーケストレーション・
   skill・スクリプトの不備)か、それ以外(子エージェント側の実装ミス、対象プロジェクト
   固有の問題等)かを切り分ける
2. **機械的改善を最優先で検討**: スクリプトによる自動化・検証強化など、AIの性能に
   依存しない機械的な改善で恒久対処できないかをまず検討する(再現性・確実性が高いため)
3. **ドキュメント改善で対処**: 2 が難しい場合のみ、`skills/` 配下の各SKILL.mdや
   `AGENTS.md`、その他ドキュメントの記述改善で対処する
4. **エスカレーション**: 1 の切り分けの結果 `multi-ai-agents-workflow` 由来と判明した
   問題、または 2・3 でも解決が困難な問題は、ここで対応を打ち切りユーザーに報告して
   中断する。ワークフロー由来の問題を子エージェントへの再依頼や場当たり的な回避で
   押し通さないこと。利用先で skill・スクリプトを勝手に直すこともしない
   (修正は配布元で行い、`workflow-update` で取り込む)
5. **upstream への Issue 起票**(ワークフロー由来と判明した場合): 改善提案が会話の中で
   消えないよう、配布元リポジトリに Issue として残す。下記「upstream への Issue 起票手順」に従う

### upstream への Issue 起票手順

起票は外部への公開を伴うため、**ユーザーの承認を得るまで `--create` を実行しない**。
起票先は `.agents/workflow/config.json` の `upstream.url` から `upstream-issue` スクリプトが
決める(利用先リポジトリに誤って起票しないよう、`gh issue create` を直接実行しない)。

1. **重複確認**: 現象を表すキーワードで既存 Issue(open / closed)を検索する
   ```powershell
   .agents/workflow/scripts/upstream-issue.ps1 -Search "<キーワード>"
   ```
   ```bash
   .agents/workflow/scripts/upstream-issue.sh --search "<キーワード>"
   ```
   同じ問題の Issue があれば、新規起票ではなく、その Issue の URL をユーザーに示す
   (追加情報をコメントするかどうかもユーザーに確認する)
2. **本文の作成**: `.agents/workflow/scripts/upstream-issue-template.md` をもとに本文を作り、
   `.agents/workflow/runs/<タスクID>-<試行回数>/upstream-issue.md` に保存する
   (現象 / 確定していること / 除外した原因 / 推定原因 / 改善提案 / 再現情報)。
   利用先固有のコード・機密情報・個人情報は含めない
3. **ユーザー承認**: 起票先リポジトリ(`--dry-run` の `Repository:` 行)・件名・本文をユーザーに
   提示し、起票してよいか確認する
   ```powershell
   .agents/workflow/scripts/upstream-issue.ps1 -Create -Title "<件名>" -BodyFile <本文のパス> -DryRun
   ```
   ```bash
   .agents/workflow/scripts/upstream-issue.sh --create --title "<件名>" --body-file <本文のパス> --dry-run
   ```
4. **起票**: 承認後、`-DryRun` / `--dry-run` を外して実行し、作成された Issue の URL を
   ユーザーに報告する。ラベルは付けない

## エスカレーション基準(ループを止めてユーザーに判断を仰ぐ)

- タスクが `failed` になった(修正リトライ上限超過後も受け入れ基準を満たせない)
- 子エージェントCLIが連続して異常終了・タイムアウトする
- タスク分解時点と前提が変わった(計画の矛盾、依存タスクの設計変更が必要 等)

## PR作成(子への単発依頼)

グループ完了時(group-advance が `Next: create-pr`(PR 未作成)または `Next: update-pr`
(既存 PR の更新)を出した場合。「グループ単位の PR とブランチ切替」を参照)とサイクル完了時に、PR 作成を子エージェントへ
単発で依頼する。PR 作成はタスクではないため、tasks.md / state.json には載せない
(タスクIDは採番しない)。親は PR のタイトル・本文を自分で書かず、gh コマンドも直接実行しない。

1. `git status --porcelain` が空であることを確認する
2. `dispatch-start --pr` を実行する。対象タスク(state.json で `done` かつ commit が
   `git log origin/main..HEAD` に含まれるもの)は自動で選ばれ、プロンプト生成・疎通確認・
   デタッチ起動までが行われる。スクリプトが `git fetch origin main` を行い、ローカルの `main` ではなく
   最新の `origin/main` と比べる(origin が無い・fetch に失敗した場合は失敗する)
   ```powershell
   .agents/workflow/scripts/dispatch-start.ps1 -Pr
   ```
   ```bash
   .agents/workflow/scripts/dispatch-start.sh --pr
   ```
   `Next: wait` なら stdout の `Run: pr-<N>-1` を控える。それ以外は reason と stderr を
   ユーザーに報告する(`main` 上で実行した、対象タスクが無い 等)。プロンプトには、
   push(`git push -u`)、`gh pr create --base main`、日本語のタイトル・本文、既存 PR の
   確認、既存 PR があれば push して本文を作り直し、`gh api -X PATCH` で更新すること、
   マージ禁止が含まれている
3. `dispatch-wait` で完了を待つ(`-TaskId pr-<N> -Attempt 1` / `pr-<N> 1`)。
   出力の `Next:` 行で分岐する。
   - `Next: wait-merge` → 手順4(PR の検証)に進む(レビュー・コミットは行わない)
   - `Next: wait`(1回の呼び出しの待ち時間の上限に達しただけで、子はまだ実行中) → 同じ引数で
     `dispatch-wait` を再度実行して待ちを続ける
   - それ以外(`Next: escalate reason=...` 等) → reason と stderr、`output.log` の末尾を
     ユーザーに報告して停止する
4. **PR の検証**: `gh pr view <作業ブランチ> --json url,state,baseRefName` を実行し、
   PR が存在し、`baseRefName` が `main` であることを確認する。確認できなければ、
   `output.log` の末尾を添えてユーザーに報告する
5. PR URL をユーザーに報告して停止する(マージはユーザーが行う)

## 完了時のサマリー報告

- タスクごとの結果(done/failed、コミットハッシュ、リトライ回数)
- 残課題・子エージェントの報告にあった備考
- 次のアクション提案(PR が未作成なら「PR作成(子への単発依頼)」を実行し、PR URL を報告する。
  マージはユーザーが行う)
- **理解確認**: `.agents/workflow/comprehension/` に未回答の質問ファイル(`**あなたの回答**:` がコメントアウトのままのファイル)がある場合、その一覧を提示する
- **git status のクリーン確認**: `git status --porcelain` を実行し、出力が空であることを確認する。
  空でない場合(コミット漏れ・想定外の untracked ファイルが残っている等)は、その内容を
  ユーザーに報告する(勝手にコミット・削除はしない)

## ユーザーへの報告

- **報告・説明はすべて日本語で行うこと**(AGENTS.md の再掲。このskillは実行のたびに
  読み込まれるため、ここに明記しておくことで日本語指定の効きを強くする)。委譲先の
  `/agent-dispatch` `/agent-review-commit` 等のサブskillが返す報告も、親がユーザーに
  向けて中継・要約する際は日本語で行うこと
- **タスクごとのループを1周するたび**に最低限報告する項目:
  - タスクID・結果(done / failed)
  - コミットハッシュ(コミット済みの場合)
  - リトライ回数
- 出力の極端な減少や英語化が疑われる兆候(サブskillからの報告が要約されずそのまま
  省略される、日本語での言い換えが行われない等)に気づいた場合は、報告を省略せず
  「完了時のサマリー報告」の形式で改めて明示すること
