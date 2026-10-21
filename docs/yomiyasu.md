# yomiyasu による日本語の推敲(任意)

[yomiyasu](https://github.com/nanaism/yomiyasu) は、AI が書いた日本語を推敲する skill です。本リポジトリには**同梱しません**。理由は次の3つです。

1. SKILL.md が大きく、トークンを多く使うため
2. `yomiyasu_check.py` の実行に Python が要るため
3. 入れ方と skill の名前が、利用者ごとに違うため

## 有効にする手順

1. `npx skills add nanaism/yomiyasu` などで yomiyasu を導入します
2. `.agents/workflow/config.json` の `text_refine.skill` に、入れ方に合う名前を書きます。名前は、親エージェントの skill 一覧に出る名前です
3. 必要なら `text_refine.targets`(推敲する場面)と `text_refine.reader`(想定する読み手)を変えます

入れ方と `text_refine.skill` の対応は次のとおりです(yomiyasu の資料で分かっているもの)。

| 入れ方 | `text_refine.skill` |
|--------|---------------------|
| Claude Code の `npx skills add` / `gh skill install` | `yomiyasu` |
| Claude Code のプラグイン | `yomiyasu:yomiyasu` |
| Codex | `yomiyasu:yomiyasu` |
| `npx openskills install` | `yomiyasu` |

それ以外のエージェントは、親の skill 一覧で名前を確かめてください。

## 推敲する場面と推敲しないもの

推敲される場面は、次の6つです(`targets` の値)。

- `commit`: コミットメッセージの説明
- `task_done`: タスク1件が done になったときの報告
- `pr_body`: PR の説明
- `confirm`: 停止して判断を仰ぐときの報告
- `summary`: 完了時のサマリー
- `tasks`: agent-task-plan で書く tasks.md(要件・前提・解釈・対象外・目的欄・受け入れ基準の文)

次のものは推敲されません: 子へのプロンプト(prompt.md・fix-notes.md)、state.json などの管理ファイル、スクリプトの出力、コード、途中経過の報告。

`text_refine.skill` が未設定のまま yomiyasu を導入していると、推敲の場面で知らせが出ます。どのエージェント用に入れた場合も対象です(プロジェクトとホームの `*/skills/yomiyasu/`、Claude Code のプラグイン)。

設定キーの詳細は、[../agents-md-setup/templates/workflow/README.md](../agents-md-setup/templates/workflow/README.md) の「config.json」節と「text-refine」節にあります。
