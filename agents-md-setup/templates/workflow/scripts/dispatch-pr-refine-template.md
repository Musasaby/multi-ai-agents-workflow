## 推敲({scene})

{when}
対象は `{input}`。推敲に失敗しても、PR の作成・更新は続ける。

1. `{request_command}` を実行する
   - 最後の行が `Next: continue` なら推敲しない(この節を終える)
   - `Next: refine` なら、`Request:` 行の依頼文を一字も変えずに、自分への依頼として実行する(依頼文に skill の名前が入っている)
2. `{check_command}` を、出力を切らずに実行する
   - `Next: decide-candidates` なら、`Candidate:` 行ごとに直すか残すかを決め、`Decisions:` 行のファイルに
     `- <キー>: 直した` / `- <キー>: 残した(<理由>)` の形で書く。直したときは `{output}` を直し、
     skill の検査をもう一度実行する。そのあと同じコマンドを実行し直す
   - `Next: continue` なら推敲できている。推敲済みの本文は `{output}` にある
3. skill を呼べない、`{output}` ができない、`Next: escalate` が出た、のどれかのときは推敲をやめる。
   `{input}` は書き換えず、理由を完了報告の備考に書く
