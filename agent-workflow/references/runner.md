# workflow-run でのグループの実行

グループのタスクのループ(起動・完了待ち・レビュー・collect・品質ゲート・コミット)は、通常は
`workflow-run` に任せて待つ。コード例は `.sh` 版だけを示す(PowerShell への読み替えは
`agent-workflow/SKILL.md` の冒頭と同じ)。

## 起動

```bash
.agents/workflow/scripts/workflow-run.sh --max-wait 480
```

`--max-wait` は親ツールのコマンド実行上限より短くする(上限10分なら 480)。
コマンドをバックグラウンドで実行でき、終了の通知を受け取れる親は `--max-wait 0` で1回だけ起動して待つ。

親が読むのは stdout だけ。`Done: <ID> <ハッシュ> retries=<n>` の行はそのまま利用者に伝える
(下書き・推敲はしない)。ほかの行は伝えなくてよい。

## 最後の行で分岐する

- `Next: wait` → 同じコマンドを呼び直す
- `Next: group-advance` → SKILL.md の「グループ単位の PR とブランチ切替」
- `Next: finish` → フローの3
- `Next: escalate reason=runner-unsupported` → [タスクごとのループ](loop.md)の手順で進める
- `Next: escalate reason=already-running` → 別の `workflow-run` の終了を待つ
- そのほかの `Next: escalate` と `Next: review <ID>` → 下の「止まったとき」

## 止まったとき

`Stopped: <ID> reason=<理由>` のタスクだけを下の表の手順で処理し、`next-task` に戻らずに
`workflow-run` を呼び直す。`In flight:` に出たほかの run は実行中のままなので触らない。
詳しい出力は `Detail:` のファイルにある(必要なときだけ読む)。

| 理由 | 親の行動 |
|------|----------|
| `timeout`・`provider-error`・`idle-timeout`・`abnormal-exit`・`tampered`・`permission-denied`・`outside-access`・`token-limit`・`no-report`・`no-changes` | `agent-dispatch` §2 の同じ名前の reason の手順。再 dispatch した後の完了待ちは `workflow-run` が引き継ぐ |
| `dirty-tree`・`worktree`・`prompt-gen`・`launch`・`healthcheck`・`warmup`・`task-status`・`review-config` | `agent-dispatch` §1 と [並列の実行](parallel.md) の「注意」 |
| `review-invalid` | `dispatch-worktree.sh collect <ID> <N>` と `task-state.sh <ID> review` を実行してから、`agent-review-commit` の §1〜§3 で親がレビューする(レビュー役は再実行しない) |
| `commit-format` | タスクは `in_review` で、collect と品質ゲートは済んでいる。親が type と説明を決めて `agent-review-commit` の §6 でコミットする |
| `retry-limit` | タスクは `in_review` で変更は本体にある。`agent-review-commit` の §4 の「上限超過」 |
| `conflict` | 試行の上限まで衝突が続いた。利用者に報告する |
| `manual`(`Next: review <ID>`) | `/agent-review-commit <ID>` |
| `quality-gate-error`・`task-state`・`commit`・`blocked`・`next-task`・`not-worktree`・`unknown-phase` | `Detail:` のファイルの内容を添えて利用者に報告する |
