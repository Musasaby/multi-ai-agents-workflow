# タスクの粒度(task_sizing)

config.json の `task_sizing` が、1タスクの件数の上限(`max_acceptance_criteria`・`max_changed_files`・`max_reference_files`)と、目的欄の書き込みの深さ(`design_detail`)を決める。既定値は README の config.json 節にある。

## design_detail が outline のとき

`skeleton`(既定)では、実装方法が複数ありうる箇所を計画時に決め、必要ならコードの骨格を目的欄に書く。`outline` では次のように書く。

- 目的欄には、方針・制約・守るべき既存の書式だけを書く
- 実装方法の選択(関数の分け方・正規表現 等)は子に任せる
- 受け入れ基準を検証可能に書くこと(「〜を実行すると〜になる」)は、`outline` でも変わらない
- 外部コマンド(gh・git 等)の挙動を事実で書くこと(計画時に実際に確かめた結果を書く)も、`outline` でも変わらない

## 子が設計に迷って止まったとき

子が設計に迷って止まった(出力トークン上限・タイムアウト)ら、そのタスクは `skeleton` の書き方で書き直して再 dispatch する。
