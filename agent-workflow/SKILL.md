---
name: agent-workflow
description: マルチエージェント実装ワークフローのオーケストレーター。GitHub Issue IDまたは計画ドキュメントのパスを引数に取り、タスク分解→子エージェントへの実装指示→レビュー→コミットをタスクごとにループ実行する。中断後の再実行で未完了タスクから再開する。
---

# マルチエージェント実装ワークフロー(オーケストレーター)

親エージェント(このskillの実行者)が計画とレビューを担い、実装とテスト実行を
子エージェント(CLI経由、エージェント名は引数/configで指定)に委譲する。

## 引数

- 第1引数(必須): GitHub Issue ID または計画ドキュメントのパス
- `--agent-cmd "<テンプレート>"`(任意): 子エージェントCLIのコマンドテンプレート。
  `{prompt}` 展開。省略時は `.agents/workflow/config.json` の値

## 前提

- `agents-md-setup` 済みであること(`AGENTS.md` が正本、`.claude` リンク有効)。
  未了なら先に `/agents-md-setup` を実行する
- 作業は `develop/*` ブランチで行う。`main` 上で開始された場合は
  `develop/<計画に基づく作業名>` ブランチを作成してから進める

## ブランチ分割の推奨(親の裁量)

同一タスクファイル(`tasks.md`)内でも、タスクが意味的なまとまり(機能グループ)に
分かれる場合は、グループ単位でブランチを分割することを推奨する(機械的な強制はしない。
`state.json` のスキーマもグループ単位の分割を前提にしない)。

- **区切り方**: `tasks.md` 上でタスクが機能グループごとに並んでいる場合、そのグループ境界を
  ブランチ分割の候補とする(依存関係の記述だけで十分に整理できている場合は無理に
  分割しなくてよい)
- **分割の流れ**: グループ内の全タスクが `done` になった時点で、後述の「PR作成(子への
  単発依頼)」で PR を作成する。**マージはユーザーが行う**。親は PR URL を報告して停止し、
  ユーザーからマージ完了の連絡を受けてから、次のグループを最新の `main` から作成した
  新しい `develop/*` ブランチで着手する
- **切替手順**:
  1. 切替前に `git status --porcelain` が空であることを確認する(ワークフロー状態の
     choreコミット(`agent-review-commit` skill の手順7)が完了していれば未コミット変更は残らないはず)
  2. `main` を最新化し、そこから新しい `develop/*` ブランチを作成して切り替える
  3. 切替後、`state.json` の `branch` を現在のブランチ名に更新し、次のグループの
     choreコミット(進捗状態コミット)に含める(`branch` フィールドは「現在の作業
     ブランチ」を表す。意味の詳細は `_templates/workflow/README.md` の state.json 節を参照)

## フロー

```
1. 計画参照・タスク分解   → /agent-task-plan <引数>     (ユーザー承認を挟む)
2. 各タスクについてループ(依存順。次のタスクは next-task スクリプトで選ぶ):
   a. 実装dispatch        → /agent-dispatch <タスクID>   (子がテスト実行まで担当)
   b. レビュー〜コミット   → /agent-review-commit <タスクID>
      - 不合格 → 子へ修正再依頼(リトライ上限あり) → b に戻る
      - 合格   → (verify_before_commit 有効時のみ)最終ゲート /agent-quality-gate
                 - FAIL(blocking) → 不合格扱いで修正再依頼へ(b に戻る)
                 - PASS → コミット(configで有効なら理解確認質問を生成)→次のタスクへ
3. 全タスク完了 → サマリー報告(未回答の質問ファイル一覧を含む)
```

### 次のタスクの選び方

ループの各周回の先頭で `next-task`(PowerShell: `.agents/workflow/scripts/next-task.ps1`
/ POSIX: `next-task.sh`)を実行し、exit code で分岐する。tasks.md の記述順や ID 順、
state.json の並び順で次のタスクを決めない(挿入したタスクの順序が崩れるため)。

- **exit 0**: stdout の `<タスクID> <status>` に従う。`pending` / `in_progress` →
  `/agent-dispatch <タスクID>`、`in_review` → `/agent-review-commit <タスクID>`
- **exit 3**: 全タスク `done`。手順3(サマリー報告)へ進む
- **exit 4**: 実行できるタスクが無い(`failed` や未完了の依存で止まっている)。stderr の
  内容を添えてユーザーにエスカレーションする
- **exit 1**: tasks.md / state.json の不備(依存欄の不正など)。stderr の内容を添えて
  ユーザーに報告する

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

- 未完了タスク(`pending` / `in_progress` / `in_review`)が残っていて `source` が
  引数と一致する場合、**手順1をスキップ**し、状態に応じたフェーズから再開する
  (`in_progress` → dispatch からやり直し、`in_review` → レビューから)
- `source` が引数と異なる場合は、進行中ワークフローの破棄可否をユーザーに確認する

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

グループ完了時(「ブランチ分割の推奨」)とサイクル完了時に、PR 作成を子エージェントへ
単発で依頼する。PR 作成はタスクではないため、tasks.md / state.json には載せない
(タスクIDは採番しない)。親は PR のタイトル・本文を自分で書かず、gh コマンドも直接実行しない。

1. `git status --porcelain` が空であることを確認する
2. `dispatch-prompt-gen` の PR モードでプロンプトを生成する。対象タスク(state.json で
   `done` かつ commit が `git log origin/main..HEAD` に含まれるもの)は自動で選ばれる。スクリプトが
   `git fetch origin main` を行い、ローカルの `main` ではなく最新の `origin/main` と比べる
   (origin が無い・fetch に失敗した場合は exit 1)
   ```powershell
   .agents/workflow/scripts/dispatch-prompt-gen.ps1 -Pr
   ```
   ```bash
   .agents/workflow/scripts/dispatch-prompt-gen.sh --pr
   ```
   stdout の `RunId: pr-<N>` を控える(出力先は `runs/pr-<N>-1/prompt.md`)。exit 1 の場合
   (`main` 上で実行した、対象タスクが無い 等)は stderr を添えてユーザーに報告する
3. `/agent-dispatch` §3 と同じ方法で、`dispatch-run` に `pr-<N>` と試行回数 `1` を渡して
   デタッチ起動する(例: `dispatch-run.ps1 -TaskId pr-<N> -Attempt 1`)。プロンプトには、
   push(`git push -u`)、`gh pr create --base main`、日本語のタイトル・本文、既存 PR の
   確認、マージ禁止が含まれている
4. `/agent-dispatch` §4 と同じ方法で完了を検知し、`dispatch-check`(`pr-<N>` / `1`)で判定する
5. **PR の検証**: `gh pr view <作業ブランチ> --json url,state,baseRefName` を実行し、
   PR が存在し、`baseRefName` が `main` であることを確認する。確認できなければ、
   `output.log` の末尾を添えてユーザーに報告する
6. PR URL をユーザーに報告して停止する(マージはユーザーが行う)

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
