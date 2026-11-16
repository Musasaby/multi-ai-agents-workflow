# タスクごとのループ(workflow-run を使えないとき)

`workflow-run` を使えないとき(`Next: escalate reason=runner-unsupported`。`review.mode` が `dispatch` でない・
`max_parallel` が 1・サブエージェントで起動する場合)に、親がタスクごとにスクリプトを呼んで進める手順。
コード例は `.sh` 版だけを示す(PowerShell への読み替えは `agent-workflow/SKILL.md` の冒頭と同じ)。

## 進め方

「フロー」の 2.a・2.b を、タスクごとに親がスクリプトを呼んで進める。実装の dispatch は
`/agent-dispatch <ID>`、レビュー〜コミットは `/agent-review-commit <ID>` に従う。
各周回の先頭で `next-task`(`.agents/workflow/scripts/next-task.sh`)を実行し、
stdout の最後の `Next:` 行に従う: `dispatch <ID>` → `/agent-dispatch <ID>`、
`review <ID>` → `/agent-review-commit <ID>`、`finish` → フローの3、
`group-advance` → 「グループ単位の PR とブランチ切替」、`escalate` → reason と stderr を
ユーザーに説明する。`Next:` 行が無ければ stderr を添えて報告する。
語彙は `.agents/workflow/README.md` の「Next: 行」の節。
`max_parallel` が 2 以上なら、`dispatch`・`wait` の後の手順は [並列の実行](parallel.md) に従う。
tasks.md の記述順や ID 順、state.json の並び順で次のタスクを決めない
(挿入したタスクの順序が崩れるため)。

- 2.a 実装dispatch: `/agent-dispatch <ID>`(子がテスト実行まで担当)
- 2.b レビュー〜コミット: `/agent-review-commit <ID>`
  - 不合格 → 子へ修正再依頼(リトライ上限あり) → 2.b に戻る
  - 合格 → (verify_before_commit 有効時のみ)最終ゲート `/agent-quality-gate`
    - FAIL(blocking) → 不合格扱いで修正再依頼へ(2.b に戻る)
    - PASS → コミット(configで有効なら理解確認質問を生成)→ ループの先頭へ戻る
      (next-task が `Next: group-advance` を出したら「グループ単位の PR とブランチ切替」の手順へ)
