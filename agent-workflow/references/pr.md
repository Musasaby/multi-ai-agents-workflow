# PR 作成と完了報告の手順

`agent-workflow/SKILL.md` からリンクされている。PR を作るとき、完了報告を書くときに読む。

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.agents/workflow/scripts/<名>.ps1` を使い、`--pr` `--summary` のようなオプションを `-Pr` `-Summary` の形の名前付き引数に読み替える。報告・説明はすべて日本語で行う。

## 要件の充足確認

PR 作成の前に、要件が満たされているかを親が確かめる。「PR作成(子への単発依頼)」の手順1の前に行う
(グループ完了時の `Next: create-pr` / `Next: update-pr`、サイクル完了時の両方)。

1. `req-status` を実行する。`No requirements section` と出たら、この確認は省略して PR 作成に進む
   ```bash
   .agents/workflow/scripts/req-status.sh
   ```
2. 対象は、この PR のタスクを含む要件(グループ完了時)または全要件(サイクル完了時)。
   要件ごとに、要件の本文を `git diff origin/<base_branch>...HEAD` と対応タスクの完了報告に照らし、
   「満たした / 部分 / 未対応」を判断する。`partial` の要件で未完了タスクが後のグループにあるものは、
   このグループで担う分だけを判断する。`## 対象外` 節に記録済みの要件・要件の一部は除外する
3. 部分・未対応があれば PR 作成に進まず停止する。要件と判断の根拠を報告し、追加モード
   (`agent-task-plan`)でタスクを足すか、対象外にするかをユーザーに確認する。対象外にする場合は
   `## 対象外` 節に `- R3 の〜: 〜のため対象外(充足確認で合意)` と追記してコミットする
4. すべて満たしていれば PR 作成に進む。PR 本文には要件の一覧が機械的に載る(`dispatch-prompt-gen --pr`)

## PR作成(子への単発依頼)

グループ完了時(group-advance が `Next: create-pr`(PR 未作成)または `Next: update-pr`
(既存 PR の更新)を出した場合)とサイクル完了時に、PR 作成を子エージェントへ
単発で依頼する。PR 作成はタスクではないため、tasks.md / state.json には載せない
(タスクIDは採番しない)。親は PR のタイトル・本文を自分で書かず、gh コマンドも直接実行しない。

0. 先に「要件の充足確認」を行い、満たしていなければここで停止する
1. `git status --porcelain` が空であることを確認する
2. `dispatch-start --pr` を実行する。対象タスク(state.json で `done` かつ commit が
   `git log origin/<base_branch>..HEAD` に含まれるもの)は自動で選ばれ、プロンプト生成・疎通確認・
   デタッチ起動までが行われる。`base_branch` は config.json の値で、無ければ `main`。
   スクリプトが `git fetch origin <base_branch>` を行い、ローカルの `<base_branch>` ではなく
   最新の `origin/<base_branch>` と比べる(origin が無い・fetch に失敗した場合は失敗する)
   ```bash
   .agents/workflow/scripts/dispatch-start.sh --pr
   ```
   `Next: wait` なら stdout の `Run: pr-<N>-1` を控える。それ以外は reason と stderr を
   ユーザーに報告する(`main` 上で実行した、対象タスクが無い 等)。プロンプトには、
   push(`git push -u`)、`gh pr create --base <base_branch>`、日本語のタイトル・本文、既存 PR の
   確認、既存 PR があれば push して本文を作り直し、`gh api -X PATCH` で更新すること、
   マージ禁止が含まれている
3. `dispatch-wait`(`pr-<N> 1`)で完了を待つ。出力の `Next:` 行で分岐する。
   - `Next: wait-merge` → 手順4(PR の検証)に進む(レビュー・コミットは行わない)
   - `Next: wait`(1回の呼び出しの待ち時間の上限に達しただけで、子はまだ実行中) → 同じ引数で
     `dispatch-wait` を再度実行して待ちを続ける
   - それ以外(`Next: escalate reason=...` 等) → reason と stderr、`output.log` の末尾を
     ユーザーに報告して停止する
4. **PR の検証**: `gh pr view <作業ブランチ> --json url,state,baseRefName` を実行し、
   PR が存在し、`baseRefName` が `<base_branch>` であることを確認する。確認できなければ、
   `output.log` の末尾を添えてユーザーに報告する
5. **PR 本文の推敲**: `text-refine pr_body .agents/workflow/runs/pr-<N>-1/pr-body.md` を実行する。
   `Next: refine` なら、`Request:` の依頼文どおりに推敲させ、テンプレートの「日本語の推敲」の
   `--check` の手順を通す。そのあと `gh pr view <作業ブランチ> --json number` で
   PR 番号を取り、`gh api -X PATCH "repos/{owner}/{repo}/pulls/<number>" -F body=@<Output: のパス>` で
   本文を更新する。`Next: continue` なら、この手順は飛ばす
6. PR URL をユーザーに報告して停止する(マージはユーザーが行う)

## 完了時のサマリー報告

先に `workflow-status --summary` を実行する。

```bash
.agents/workflow/scripts/workflow-status.sh --summary
```

出力(Task 行・Requirement 行・Comprehension 行・Worktree 行・PR 行)をもとに、
`report-template.md` の「完了時のサマリー」の形で `.agents/workflow/runs/refine/summary.md` に
下書きする。テンプレートの「日本語の推敲」の手順(場面 `summary`)を通してから、ユーザーに示す。
項目と、作るときに使う行は次のとおり。

- タスクごとの結果(done/failed、コミットハッシュ、リトライ回数): Task 行
- 残課題・子エージェントの報告にあった備考: 各タスクの完了報告
- 要件ごとの充足状況(判断を含む): Requirement 行
- 次のアクション提案(PR が未作成なら「PR作成(子への単発依頼)」を実行し、PR URL を報告する。
  マージはユーザーが行う): PR 行
- **理解確認**: 未回答の質問ファイルの一覧を提示する: Comprehension 行
- **git status のクリーン確認**: Worktree 行で確かめる。dirty の場合は、その内容を
  ユーザーに報告する(勝手にコミット・削除はしない)
