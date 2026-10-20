# 理解確認の質問の作り方

`config.json` の `comprehension_check.enabled` が `true` のとき、`agent-review-commit` §5 のコミット前に行う。
質問ファイルを `task-commit` の状態ファイルのコミットに含めるため、コミットの**前**に作る。

## 手順

1. `.agents/workflow/comprehension/` ディレクトリがなければ作成する
2. レビューで把握済みの diff・受け入れ基準・完了報告のみから質問を生成する(追加のファイル読み込みは行わない)
3. 質問数は `comprehension_check.questions_per_task` に従う
4. 次の観点からバランスよく質問を作る:
   - **設計判断**: なぜこの実装方針か、トレードオフ
   - **動作の仕組み**: 変更したコードの処理フロー、エッジケース
   - **依存の理解**: 実装で利用した既存モジュール・外部ライブラリ・フレームワーク機能について、その大まかな役割と仕組み
   - **影響範囲**: この変更が他のどこに影響しうるか
5. `agent-comprehension-check/SKILL.md` の「質問ファイルのフォーマット」に従い、
   `.agents/workflow/comprehension/<タスクID>.md` に保存する。質問ファイルに `## 解説` 見出しは含めない(未解説判定のため)
6. 保存したファイルパスを会話に出力する
