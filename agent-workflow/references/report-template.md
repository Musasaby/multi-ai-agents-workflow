# ユーザーへの報告テンプレート

親エージェントがユーザーに向けて書く報告の共通テンプレート。`agent-workflow`・`agent-dispatch`・
`agent-review-commit` の各 skill の「ユーザーへの報告」から参照される。報告は日本語で書く。

## 基本の形

見出しは付けず、次の3点を3つの段落か箇条書きで書く。

- **状況**: 今どこにいるか。何タスク中何件が完了していて、どのタスク・グループを扱っているかを書く。
  `workflow-status` の Progress・Group・Current 行から作る
- **起きたこと**: 直前に何が起きたか(子の作業が終わった、レビューに合格した 等)を、利用者の言葉で書く
- **次にすること**: 親が続けて何をするかを書く。利用者の操作が要るとき(PR のマージ、判断、回答)は、
  それを先頭に書いて明示する

## 内部語の扱い

exit code・Verdict・`Next:` 行・reason(`idle-timeout` 等)・ステータス値(`in_review` 等)は、
本文にそのまま書かない。意味を言葉で書き、必要なら括弧で補足する。
例:「子の作業が途中で止まりました(idle-timeout)」。

コマンド・パス・タスクID・コミットハッシュ・URL は、そのまま書く。

## 場面ごとの書き方

各場面で、3点(状況・起きたこと・次にすること)に何を書くかを示す。
括弧内は、日本語の推敲の場面名(`text_refine.targets` の値)。

- **子の起動直後**: 状況=タスクID・試行回数(例: `T3-1`)と進捗。起きたこと=子に実装を依頼したこと。
  次にすること=完了を待つこと。ログファイルのパスと、ログの見方のコマンド(§1の `Watch:` 行)を添える
- **子の実行待ち**: `dispatch-wait` が `Next: wait` で戻るたびに、`Elapsed:`・`Log idle:` から
  「T3 の作業中です(経過 8分、ログの最終更新 20秒前)」のような1行だけを書く。3点の形にはしない
- **子の完了検知後**: 状況=タスクIDと試行回数。起きたこと=子の作業が終わったことと、完了報告の検証結果
  (テストが全件パスしたか、失敗があればその概要)。`Disabled checks:` が `none` 以外なら、無効な検査の内容も書く。
  次にすること=レビューへ進むか、再依頼するか、ユーザーに判断を仰ぐか
- **レビュー結果**: 状況=タスクIDと進捗。起きたこと=合格か、修正依頼か(修正が要る点の要約)。
  次にすること=コミットするか、子に修正を依頼するか
- **コミット完了**(`commit`): 状況=タスクIDと進捗。起きたこと=コミットしたこと(コミットハッシュ)。
  次にすること=次のタスクへ進むか、グループの区切りに進むか
- **タスク1件が done になったとき**(`task_done`): 状況=進捗(何タスク中何件完了)。
  起きたこと=タスクID・結果(done)・コミットハッシュ・リトライ回数。次にすること=次のタスク。
  リトライの途中では報告しない
- **PR 作成・マージ待ち**(`pr_body` は PR 説明の推敲): 状況=作業ブランチと PR の状態。起きたこと=PR を作成したこと(PR の URL)。
  次にすること=**利用者がマージする**ことを先頭に書く
- **停止して判断を仰ぐとき**(`confirm`): 状況=止まった場所(タスク・グループ)。起きたこと=止まった理由を言葉で。
  次にすること=利用者に求める判断や回答を先頭に書き、選べる案があれば添える
- **完了時のサマリー**(`summary`): `workflow-status --summary` の出力から作る。タスクごとの結果
  (done / failed、コミットハッシュ、リトライ回数)、残課題と子の備考、要件ごとの充足状況、次のアクション
  (マージは利用者が行う)、未回答の理解確認の一覧、`git status` が空かどうかを書く

## 日本語の推敲(yomiyasu、任意)

yomiyasu は同梱しない。利用者が導入し、config.json の `text_refine.skill` を設定したときだけ使う。

1. 推敲する場面(`text_refine.targets` の値)の文を、`.agents/workflow/runs/refine/<場面>.md` に下書きする
2. `text-refine <場面> <下書き>` を実行する(PowerShell: `.agents/workflow/scripts/text-refine.ps1` /
   bash: `.agents/workflow/scripts/text-refine.sh`)
3. `Next: continue` のときは、下書きをそのまま使う。`Hint:` 行があるときは、そのセッションで1回だけ、
   次のことを利用者に伝える
   - `Found:` の場所に yomiyasu が見つかったこと
   - 親自身の skill 一覧に出ている yomiyasu の名前を `text_refine.skill` に設定すると、推敲できること
     (例: Claude Code の `npx skills add` では `yomiyasu`、Claude Code のプラグインと Codex では `yomiyasu:yomiyasu`)
   - 親の skill 一覧に yomiyasu が無いとき(別のエージェント用に入っているとき)は、その旨

   config.json は、利用者の承認なしに書き換えない
4. `Next: refine` のときは、`Request:` 行の依頼文を**一字も変えずに**そのまま自分への依頼として実行する
   (依頼文に skill 名が入っている)。そのあと `Output:` のファイルを読んで使う
5. 推敲の後に `text-refine <場面> <下書き> --check`(PowerShell は `-Check`)を、出力を切らずに実行する
   (`head`・`sed -n`・`Select-Object -First` 等で切らない)。対象は yomiyasu だけで、`text_refine.skill` が
   `yomiyasu` / `yomiyasu:yomiyasu` 以外のときは、確かめずに `Next: continue` が返る
   - `Next: decide-candidates` のときは、`Candidate:` 行ごとに直すか残すかを決め、`Decisions:` のファイルに
     `- <キー>: 直した` / `- <キー>: 残した(<理由>)` の形で書く。直したときは、推敲済みファイルを直し、
     yomiyasu の検査をもう一度実行してから、`--check` を実行し直す
   - `Next: escalate reason=refine-unchecked` のときは、下書きを使わずに止め、理由(`Unchecked:` 行)を
     利用者に伝える
   - `Next: escalate reason=refine-structure-changed` のとき(場面 `tasks` で、機械パースする行が推敲で
     変わったとき)は、下書きを使わずに止め、`Changed:`・`Refined:` 行を利用者に示して判断を仰ぐ。
     `tasks` の手順の詳細は agent-task-plan の SKILL.md にある
   - `Next: continue` のときは、`Text:` の節の本文を一字も変えずに、報告・コミット・PR 本文に使う
     (返答を書くときに組み立て直さない)。`Text:` が無いときは、今までどおり下書きか `Output:` のファイルを使う
6. yomiyasu を呼べなかったとき(Unknown skill 等)、`Output:` のファイルができなかったとき、
   `commit` の結果が1行でないときは、下書きを使う。そのうえで、`text_refine.skill` の名前が入れ方と
   合っているかを確かめるよう、利用者に1回伝える

推敲の対象外:

- 子へのプロンプト(prompt.md・fix-notes.md)
- state.json などの管理ファイル
- スクリプトの出力
- コード
- 途中経過の報告

注意: yomiyasu の SKILL.md は大きく、トークンを多く使う。
