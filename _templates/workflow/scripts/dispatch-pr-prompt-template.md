# PR作成依頼(単発)

これは非対話のワンショット実行です。確認の質問はせず、ただちに以下の手順を実行してください。
コードの変更・コミット・PR のマージは行わないこと(マージはユーザーが行う)。

## 対象

- 作業ブランチ: `{branch}`
- ベースブランチ: `{base_branch}`
- この PR に含まれるタスク(`.agents/workflow/tasks.md` の該当セクションに目的・受け入れ基準がある):
{task_list}

## 手順

1. `git branch --show-current` が `{branch}` であること、`git status --porcelain` が空であることを確認する。
   どちらかを満たさない場合は何もせず、その内容を完了報告の備考に書いて終了する
2. `gh pr view {branch} --json url` で、このブランチの PR が既に存在するか確認する。
   存在する場合は新規作成せず、その URL を完了報告に書いて終了する
3. `git push -u origin {branch}` で push する
4. PR 本文を `{run_dir}/pr-body.md` に書き出す。本文は日本語で書き、以下を含める:
   - 概要(この PR で何が変わるか)
   - 含まれるタスク(上記の一覧)
   - 変更点の要約(`git log {base_ref}..HEAD --oneline` と `git diff {base_ref}...HEAD --stat` をもとに書く。
     ローカルの `{base_branch}` は古いことがあるため、必ず `{base_ref}` と比較する)
   - テスト計画(各タスクの受け入れ基準をもとにしたチェックリスト)
5. `gh pr create --base {base_branch} --head {branch} --title "<タイトル>" --body-file {run_dir}/pr-body.md`
   で PR を作成する。タイトルは日本語で、変更内容を簡潔に表す

## 完了報告フォーマット
```
## 完了報告
- PR URL: <作成した(または既存の) PR の URL>
- タイトル: <PR タイトル>
- 備考: <判断に迷った点、手順を中断した場合はその理由>
```
