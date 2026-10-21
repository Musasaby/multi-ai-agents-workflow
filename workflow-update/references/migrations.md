# 更新に伴う移行の注意

`workflow-update` でスクリプトを更新したあと、旧形式の `config.json`・`tasks.md` が原因で
動作が変わったり止まったりしたときに読む。

## XDG 切り替えの既定変更に伴う移行

`dispatch-run` は `child_agent.isolate_xdg` が `true` のときだけ
子CLIの XDG をプロジェクト内(`.agents/workflow/.config`)に切り替える(以前は常に切り替えていた)。
キーが無い既存の config.json では切り替えなくなる。sandbox 環境で切り替えが必要な利用先には、
`config.json` の `child_agent` に `"isolate_xdg": true` を追加するよう提案する

## 子へのプロンプトからのプロジェクト固有指示の削除に伴う移行

`dispatch-prompt-template.md` から
Kotlin/Gradle 固有の指示(`-Pkotlin.incremental=false` での切り分け、Gradle 引数の引用符)を削除した。
これらに依存していた利用先には、利用先の `AGENTS.md` の「テスト・検証の注意(子エージェント向け)」節
(雛形は `_templates/AGENTS.md`)に同じ内容を書くよう提案する

## 依存欄の検証強化に伴う移行

`state-sync` / `next-task` は全タスクの依存欄を厳密に検証する
(依存行の欠落・注記付きの値・存在しないID・循環をエラーにする)。進行中のサイクルの
tasks.md が旧形式(例: `- **依存**: T30(完了済み)`、依存行の無いタスク)の場合、スクリプトを
更新すると `state-sync` / `next-task` が exit 1 で止まる。更新後に `next-task` を1回実行し、
exit 1 になった場合は stderr に列挙されたタスクの依存欄を `なし` / `T1, T2` 形式に直す
(注記は目的欄へ移す)ようユーザーに提案する

## 配布ブランチの `dist` への移行

配布は `dist` ブランチ(`main` から `tests/`・`docs/`・`AGENTS.md` 等を除いたもの)に移った。
`workflow-update` が `WARN: upstream.branch is main` を出したら、`config.json` の
`upstream.branch` を `"dist"` に変えて再実行するようユーザーに提案する。
その pull で `.agents/skills/` から `tests/`・`docs/`・`AGENTS.md` 等が消えるのは正常
