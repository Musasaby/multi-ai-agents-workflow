# 更新に伴う移行の注意

`workflow-update` でスクリプトを更新したあと、旧形式の `config.json`・`tasks.md` が原因で
動作が変わったり止まったりしたときに読む。

## git subtree から npx skills への移行

`workflow-update` が `escalate reason=not-npx` を出した利用先(`.agents/skills/` を `git subtree` で取り込んでいる)で行う。
subtree 時代の `workflow-update` が `escalate reason=sync-failed`
(`.agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh` が見つからない)で止まった場合も、この手順に進む。
subtree で取り込んだ配布物を `.agents/skills/` から消してコミットし、`npx skills add` で導入し直し、
`workflow-update` スクリプトで配置済みスクリプトとの差分を反映してコミットする。
コマンドは bash と PowerShell で同じものが使える。
`--overwrite` には、`workflow-update.sh` の `differs` 行に出た名前をカンマ区切りで渡す(`differs` が無ければその行は飛ばす):

```bash
git -C .agents/skills rm -r -q --ignore-unmatch agent-branch-guard agent-comprehension-check agent-dispatch agent-quality-gate agent-review-commit agent-task-plan agent-workflow agents-md-setup workflow-update _templates tests docs AGENTS.md README.md .gitignore .gitattributes .github
git commit -m "chore: subtree で取り込んだ配布物を削除する(npx skills へ移行)"
npx skills add Musasaby/multi-ai-agents-workflow --skill '*' -a universal -y
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --copy-missing
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --overwrite <workflow-update が differs と出した名前,...>
git add .agents/skills skills-lock.json .agents/workflow/scripts .agents/workflow/README.md
git commit -m "chore: npx skills で配布物を導入する"
```

移行後に次を行うよう、ユーザーに提案する:

- 利用先の `AGENTS.md` の「セットアップ(clone直後)」節にある subtree の説明を、`agents-md-setup/templates/AGENTS.md` の同じ節に合わせて書き換える
- `config.json` の `upstream.branch` はもう使わないので消してよい

## XDG 切り替えの既定変更に伴う移行

`dispatch-run` は `child_agent.isolate_xdg` が `true` のときだけ
子CLIの XDG をプロジェクト内(`.agents/workflow/.config`)に切り替える(以前は常に切り替えていた)。
キーが無い既存の config.json では切り替えなくなる。sandbox 環境で切り替えが必要な利用先には、
`config.json` の `child_agent` に `"isolate_xdg": true` を追加するよう提案する

## 子へのプロンプトからのプロジェクト固有指示の削除に伴う移行

`dispatch-prompt-template.md` から
Kotlin/Gradle 固有の指示(`-Pkotlin.incremental=false` での切り分け、Gradle 引数の引用符)を削除した。
これらに依存していた利用先には、利用先の `AGENTS.md` の「テスト・検証の注意(子エージェント向け)」節
(雛形は `agents-md-setup/templates/AGENTS.md`)に同じ内容を書くよう提案する

## 依存欄の検証強化に伴う移行

`state-sync` / `next-task` は全タスクの依存欄を厳密に検証する
(依存行の欠落・注記付きの値・存在しないID・循環をエラーにする)。進行中のサイクルの
tasks.md が旧形式(例: `- **依存**: T30(完了済み)`、依存行の無いタスク)の場合、スクリプトを
更新すると `state-sync` / `next-task` が exit 1 で止まる。更新後に `next-task` を1回実行し、
exit 1 になった場合は stderr に列挙されたタスクの依存欄を `なし` / `T1, T2` 形式に直す
(注記は目的欄へ移す)ようユーザーに提案する
