# 問題発生時の対応順序と upstream への Issue 起票

`agent-workflow/SKILL.md` からリンクされている。ワークフロー実行中に問題が起きたときに読む。

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.agents/workflow/scripts/<名>.ps1` を使い、`--search` `--create` のようなオプションを `-Search` `-Create` の形の名前付き引数に読み替える。報告・説明はすべて日本語で行う。

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

## upstream への Issue 起票手順

起票は外部への公開を伴うため、**ユーザーの承認を得るまで `--create` を実行しない**。
起票先は `.agents/workflow/config.json` の `upstream.url` から `upstream-issue` スクリプトが
決める(利用先リポジトリに誤って起票しないよう、`gh issue create` を直接実行しない)。

1. **重複確認**: 現象を表すキーワードで既存 Issue(open / closed)を検索する
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
   ```bash
   .agents/workflow/scripts/upstream-issue.sh --create --title "<件名>" --body-file <本文のパス> --dry-run
   ```
4. **起票**: 承認後、`--dry-run` を外して実行し、作成された Issue の URL を
   ユーザーに報告する。ラベルは付けない
