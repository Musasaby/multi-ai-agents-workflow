# 並列の実行

config.json の `max_parallel` が 2 以上のとき、`next-task` は `Next: dispatch A B`(複数 ID)や
`Next: wait A B` を出す。各 run は専用の worktree で動く。コード例は `.sh` 版だけを示す
(PowerShell への読み替えは `agent-workflow/SKILL.md` の冒頭と同じ)。
スクリプトの出力・exit code の意味は `.agents/workflow/README.md` を読む。

## 手順

1. `next-task` の最後の `Next:` 行で分岐する
   - **`Next: dispatch A B`**: 並んだ ID の**全部**を `dispatch-start` する(1件ずつ `/agent-dispatch <ID>`)
   - **`Next: wait A B`**: 起動順に `dispatch-wait` を呼び、完了した run を `dispatch-check` する
2. `dispatch-check` の最後の `Next:` 行で分岐する
   - **`Next: collect <ID>`**: `dispatch-worktree collect` を実行する
     ```bash
     .agents/workflow/scripts/dispatch-worktree.sh collect <ID> <試行回数>
     ```
     成功すると `Next: review <ID>` が出る
   - **`Next: review`**: `task-state <ID> review` を実行し、`/agent-review-commit <ID>` に進む
3. 完了の処理(collect・レビュー・コミット)は**1件ずつ**行う。collect は本体の作業ツリーが
   クリーンなときだけ実行できるので、前のタスクをコミットしてから次を collect する

## 注意

- `collect` が `reason=conflict`(exit 40)で止まったら、fix-notes.md に「最新の HEAD でやり直す」と、
  前の試行の `.agents/workflow/runs/<ID>-<N>/changes.patch` のパスを書き、次の試行番号で再 dispatch する
  (取り込まれなかった前の試行の変更は次の試行に持ち越されない。子が前のパッチを見て作り直す)
- `dispatch-start` の `dispatch-worktree create` が exit 40(前の試行の持ち越しの衝突)で止まったら、
  ユーザーに報告する(WT・ブランチは残らず、本体は元に戻っている)
- `Undeclared:` に出たファイルは、tasks.md の `changed` に無い変更。レビューで内容を確かめる
- `dispatch-start` が exit 60(起動待ちのタイムアウト)で止まったときは、WT を片付けていない。
  `dispatch-run` のプロセスが動いていないこと(`runs/<ID>-<N>/output.log` が伸びていない、`done` が無い)を
  確かめてから `dispatch-worktree abort` で片付け、同じ試行で `dispatch-start` をやり直す
  (片付けないと exit 61 になる)。動いているなら `dispatch-wait` で待つ
- 並列中(`in_progress` の run があるあいだ)は、本体の `tasks.md` を変えない。`state-sync --insert` などで
  修正タスクを足すのは、すべての run を collect してからにする(変えると実行中のすべての run が `tampered` になる)
- 異常終了などで引き取らない run は、`remove` ではなく `dispatch-worktree abort` で消す。
  試行 2 以降では、`create` が本体から取り除いた前の試行の変更を本体に当て直す(`reverted` が無ければ `remove` と同じ)
  ```bash
  .agents/workflow/scripts/dispatch-worktree.sh abort <ID> <試行回数>
  ```

## ログの見方

全 run のログは `workflow-logs` を1回起動すれば1画面で見られる。`--run <ID>-<N>` で1つに絞れる。

```bash
bash .agents/workflow/scripts/workflow-logs.sh
bash .agents/workflow/scripts/workflow-logs.sh --run T1-1
```
