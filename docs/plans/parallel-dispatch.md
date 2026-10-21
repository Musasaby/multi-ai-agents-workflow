# 計画: 並列 dispatch の方式の検討(Issue #70 T5)

このドキュメントは検討結果の記録で、コードは変えない。採用する場合の実装は、4. の条件を満たしたうえで
5. の範囲ごとに別の Issue に切り出す。

## 1. 目的と期待できる効果

今の `agent-workflow` は、`next-task` が選んだタスクを1つずつ dispatch する直列のループである
(`agent-workflow/SKILL.md` の「フロー」)。依存の無いタスクが複数あっても、子エージェントの実行時間が
そのまま合計時間に足される。子の実行は数分〜数十分かかり、その間 親は待つだけになる。

依存の無いタスクを同時に dispatch できれば、合計時間は「最も長い子の実行時間 + 親の直列作業
(レビュー・コミット)」に近づく。効果が大きいのは、グループ内に依存の無いタスクが3件以上あるサイクルである。
タスクが一本鎖の依存でつながるサイクルでは効果が無い。

## 2. 方式案

- 並列に dispatch できるタスク(依存が全て完了済み、かつ互いに変更対象が重ならないもの)ごとに
  `git worktree add` で作業ツリーを作り、worktree ごとに子を起動する
- 子は worktree の中だけを編集する。レビュー・コミットは親が1タスクずつ直列に行う
  (worktree の変更を本体のブランチに取り込んでからコミットする。取り込み方法は 3.(a))
- 同時に走らせる子の数は `config.json` の `max_parallel`(既定 `1`)で決める。`1` なら今の直列動作と同じで、
  既存の利用先の挙動は変わらない
- `state.json` の更新・コミット・PR 作成は今までどおり親だけが行う

## 3. 論点ごとの検討

### (a) 同じファイルを変更するタスク同士の衝突

- **事前の判定**: tasks.md の「参照ファイル」欄には、変更するファイルに `(変更対象` の注記が付く。
  タスクの組ごとに、この注記が付いたファイルの集合が重なるかを調べれば、機械的に判定できる
  (`next-task` の仲間のスクリプトで実装できる)。重なる組は並列にせず、後のタスクを待たせる
- **判定の限界**: 注記は計画時の申告であり、子が注記に無いファイルを変えることは防げない。
  検出するため、取り込みの前に worktree の `git diff --name-only` を申告と照らし、
  申告外の変更があればそのタスクを不合格にして直列で再 dispatch する。
  また `AGENTS.md`・`README.md` のように複数タスクが追記しがちなファイルは、
  申告が一致していても衝突しやすいので、並列の対象から外す設定が要る
- **取り込み方法**: 案は2つ。(1) 子が worktree 内でコミットし、親が `git cherry-pick` で本体に取り込む。
  子のコミットは `dispatch-check` の tampered 判定に引っかかるため採れない(3.(c))。
  (2) 子はコミットせず、親が worktree の差分を `git diff` のパッチにして本体に `git apply` し、
  レビュー後に本体でコミットする。現行の「子はコミットしない、コミットは親」という規則を保てるので、
  (2) を採る。パッチが当たらなければそのタスクは衝突として直列で再 dispatch する

### (b) state.json の更新競合

現行の仕様では state.json は `state-sync` などのスクリプトが書き、LLM は直接編集しない
(`_templates/workflow/README.md` の state.json の節)。子の指示にも state.json を触らないことが
書かれており、`dispatch-run` は起動時に state.json の SHA-256 を `guard.sha256` に記録して、
子が変更すれば `dispatch-check` が改ざんとして検知する。

したがって書き込むのは親だけにできる。並列でも親は1つのプロセスで、レビュー・コミットを直列に処理するので、
state.json の更新は直列のまま変わらない。競合が起きうるのは、親が複数の完了を同時に処理しようとした場合だけで、
それは「完了の処理は1件ずつ」という手順で避ける。

残る確認事項: 各 worktree に state.json・tasks.md・config.json のコピーが無い(利用先では `.agents/` が
コミット対象なので worktree にも出るが、このリポジトリのように git 管理外なら出ない)。
子が参照する管理ファイルは本体のものを読み取り専用で見せる必要があり、
どのパスで見せるかは実装時に決める(5. の段階1)。

### (c) `runs/` と `dispatch-check` の tampered 判定

tampered の判定は、`dispatch-run` が起動時に `git-state.txt` に記録した4行(`head`・`branch`・`refs`・`config`)と、
`dispatch-check` 実行時の `git-state` の出力の比較である。並列にすると次の問題がある。

- `head`・`branch`: worktree ごとに HEAD とブランチが別になる。`git-state` を worktree 内で実行すれば、
  その worktree の値を比べるので、自分の worktree の中だけの判定になり問題は小さい。
  ただし本体のブランチを親が進めても、worktree の値は変わらないことを確認する必要がある
- `refs`: `refs/heads`・`refs/tags`・`refs/stash` は全 worktree で共有される。
  親が先に完了したタスクをコミットすると本体のブランチの参照が動き、まだ走っている他の子の
  `refs` が変わって、**子が何もしていないのに `git changed: refs` で tampered になる**。
  これは並列化の最大の障害である
- `config`: `.git/config` は共有されるので、`git worktree add` 自体は config を変えないが、
  どれかの子が `git config` を使えば全員の config が変わる

対処案: 並列の run では `refs` の比較を、「子の worktree のブランチ(`refs/heads/<worktree 用ブランチ>`)だけ」の
値に絞る。`dispatch-check` に比較範囲を絞るオプションを足す形になる。
`runs/<タスクID>-<試行回数>/` は本体の `.agents/workflow/runs/` に置いたままにし、
タスクID・試行回数が一意なので、並列でもディレクトリは衝突しない。

### (d) 子の一時ディレクトリ・利用上限・ログの監視

- **一時ディレクトリ**: `dispatch-run` は `TMPDIR`・`TEMP`・`TMP` を `runs/<ID>-<N>/tmp/` に
  設定済みで、ID・試行回数ごとに別なので並列でも衝突しない。プロジェクト外アクセスの検出
  (`Outside access:`)も run ごとの `output.log` で判定するので影響を受けない
- **利用上限(provider-error)**: 同じプロバイダーに複数の子が同時に接続するので、利用上限やレート制限
  (429)に当たりやすくなる。`dispatch-check` の `Provider error:` は参考情報で Verdict に影響しないため、
  並列では「1つが provider-error なら他の run も同じ原因を疑う」手順が要る。
  `max_parallel` の既定を 1 にしておき、利用者が上げて様子を見る形にする
- **ログの監視**: 親は run ごとに `output.log` を見る。今の `dispatch-wait` は1つの run を待つので、
  複数の run を順に待つ手順(完了した run から `dispatch-check` する)が必要になる。
  `timeout_seconds`・`idle_timeout_seconds` は run ごとに効くので、そのまま使える

## 4. 採否と理由

**条件付き採用**。

理由: 1. の効果は大きく、(b)(d) は現行の仕組みのまま問題が小さい。一方 (c) の `refs` 共有は
そのままだと並列の run が必ず誤って tampered になるため、**先に `dispatch-check` の比較範囲を絞る変更が必要**。
(a) も、事前判定のスクリプトと「申告外の変更を検出する手順」が先に要る。

先に必要な変更:

1. `dispatch-check` が `refs` の比較を run 単位に絞れること(3.(c))
2. 参照ファイルの `(変更対象` から、並列にできるタスクの組を機械的に出すスクリプト(3.(a))
3. 子の worktree から管理ファイルを読み取り専用で見せる方法の確定(3.(b))

## 5. 段階的な進め方

最初の Issue に切り出す範囲は、**挙動を変えない準備**に限る。

1. 段階1(最初の Issue): `config.json` に `max_parallel`(既定 1)を足し、README に書く。
   あわせて `dispatch-check` の `refs` 比較を絞るオプションと、そのテスト(`.sh`・`.ps1` の対)を実装する。
   `max_parallel` が 1 の間は何も変わらない
2. 段階2: 並列にできるタスクの組を出すスクリプト(`next-task` の拡張、または別スクリプト)と、
   申告外の変更を検出する手順
3. 段階3: `dispatch-run` の worktree 対応と、`agent-workflow` skill のループを `max_parallel` > 1 で
   動かす手順。パッチによる取り込み(3.(a) の案 (2))を含む
4. 段階4: 実際の利用先で `max_parallel: 2` から試し、provider-error の頻度を見て既定値や注意書きを見直す
