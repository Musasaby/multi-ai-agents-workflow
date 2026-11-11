# レビュー役への dispatch

`config.json` の `review.mode` が `dispatch` のときに読む。`agent-review-commit` の §1〜§3 と §5.2 の
代わりに次の手順でレビューする。コード例は `.sh` 版だけを示す(PowerShell への読み替えは
`agent-review-commit/SKILL.md` の冒頭と同じ)。

## 手順

### 1. レビューの run を起動する

```bash
.agents/workflow/scripts/dispatch-start.sh --review <ID>
```

サブエージェントを起動できる親は `--subagent-capable` を付ける。
`Next: subagent review-<ID> <N>` なら [サブエージェントでの起動](../../agent-dispatch/references/subagent.md)
の手順で起動する。親はプロンプトのパスだけを渡し、内容は読まない。

stdout の最後の `Next:` 行で分岐する。

- **`Next: wait`**: 起動できた。手順2へ(`Run:` 行の `review-<ID>-<N>` から `<N>` を知る)
- **`Next: subagent ...`**: サブエージェントを起動した。手順2へ
- **`Next: escalate reason=review-mode` / `review-config`**: 起動していない。config.json を直すか、
  今の手順(§1〜§3)で親がレビューするかを利用者に確かめる
- **その他の `Next: escalate`**: 起動していない。reason と stderr をユーザーに報告して中断する

### 2. 完了を待つ

```bash
.agents/workflow/scripts/dispatch-wait.sh review-<ID> <N>
```

`<N>` はレビューの試行回数。`Next: wait` なら同じコマンドを再実行する。
サブエージェントの run は `dispatch-wait` で待たず、
[サブエージェントでの起動](../../agent-dispatch/references/subagent.md)の手順で完了させる
(その後の判定は同じ)。

### 3. 出力で分岐する

親は diff・`report.md`・`prompt.md` を読まない。読むのは `dispatch-check` の出力の
`Review verdict:`・`Review findings:`・`Review summary:`・`Fix notes:` と `Next:` 行だけ。

- **`Next: commit <ID>`**(`Review verdict:` が pass): `Review findings:` を使ってユーザーに「レビュー結果」を
  報告する。次に §5.1(品質ゲート)を行い、`Review summary:` をもとにコミットの説明を決めて §6 に進む。
  理解確認が有効なら質問ファイルはレビュー役が作っている(§5.2 は行わない)
- **`Next: retry <ID>`**(`Review verdict:` が fail): `fix-notes.md` はレビュー役が書いている
  (`Fix notes:` にパス)。§4 のうち `fix-notes.md` を書く手順を飛ばし、`task-state <ID> retry` から進める
  (上限超過・`task-state` が exit 4 のときの扱いは §4 のまま)
- **`Next: escalate`**(reason が `review-mode`・`review-config` 以外)・判定が無効(exit 4〜8 など)のとき:
  その試行は今の手順(§1〜§3)で親がレビューする。レビュー役は再実行しない
- **`Next: escalate reason=review-mode` / `review-config`**: 手順1のとおり、config を直すか今の手順で
  親がレビューするかを利用者に確かめる
