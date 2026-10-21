# multi-ai-agents-workflow

AIエージェント(Claude Code、OpenCode 等)による複数エージェント協調の実装ワークフローを、任意のプロジェクトに `npx skills add` で導入できる配布物です。

## 概要

2種類のエージェントが役割を分けて実装を進めます。

- **親エージェント**(Claude Code・Codex 等): 利用者と対話します。計画のタスク分解、子への依頼、レビュー、コミット、PR 作成を行います
- **子エージェント**(opencode・`claude -p` 等の CLI): 親から1タスクずつ依頼を受けて実装し、テストを実行して完了報告を書きます

```
1. 計画参照・タスク分解   → 親: /agent-task-plan
2. 各タスクを順次実行:
   a. 実装dispatch        → 親が依頼し、子が実装・テスト実行・完了報告(/agent-dispatch)
   b. レビュー・コミット  → 親: /agent-review-commit
      - 合格時、verify_before_commit 有効なら最終ゲート → 親: /agent-quality-gate
        (FAIL(blocking) なら修正再依頼に戻る)
      - config有効時、合格時に質問ファイルを生成
3. 全タスク完了 → 親: サマリー報告(未回答の質問一覧含む)
```

理解確認(任意・デフォルト無効): 質問ファイルに回答後、`/agent-comprehension-check` で判定・解説を依頼できます(別セッション可)。

状態は `.agents/workflow/` の `tasks.md`(タスク定義)と `state.json`(進捗)に残ります。中断しても、`/agent-workflow` を引数なしで実行し直せば未完了のタスクから再開できます。

## 含まれる skill

| ディレクトリ | 説明 |
|---|---|
| `agent-workflow/` | 全体オーケストレーター(中断再開対応) |
| `agent-task-plan/` | 計画→タスク分解 |
| `agent-dispatch/` | 子エージェントへの実装指示・テスト実行 |
| `agent-quality-gate/` | 品質ゲート(typecheck/lint/test)の設定駆動一括実行・合否報告 |
| `agent-comprehension-check/` | 回答済み質問ファイルの判定・解説(別セッション対応) |
| `agent-review-commit/` | レビュー・修正再依頼・コミット |
| `agent-branch-guard/` | ワークフロー外の変更・コミットを伴う依頼のブランチ判定(branch-check) |
| `agents-md-setup/` | 正本化セットアップとリンク検証。`templates/` に利用先用テンプレート(`AGENTS.md`・`CLAUDE.md`・`workflow/` の config.json・README.md・scripts) |
| `workflow-update/` | `npx skills update` 後の確認と配置済みスクリプトの更新支援 |

`npx skills` が配るのは `SKILL.md` を持つディレクトリだけで、`tests/`・`docs/`・`AGENTS.md` は利用先に入りません。

## 前提

- プロジェクトは Git 管理されていること
- Node.js 22.20 以上(`npx skills` の要件。導入・更新のときだけ使う)
- `main` への直接コミットはしない。作業は `develop/<作業名>` ブランチで行う。`branch-check` は `main`(と `base_branch`)の上での作業を止め、`state-sync --set-branch` と `group-advance` は `develop/` で始まらないブランチ名を受け付けない
- 子CLI(既定は opencode)が使えること

## クイックスタート

1. 利用先プロジェクトのルートで以下を実行:
   ```bash
   npx skills add Musasaby/multi-ai-agents-workflow --skill '*' -a universal -y
   ```
   - `--skill '*'` で全 skill を入れます(このワークフローは全 skill が揃っている前提です)
   - `-a universal` で `.agents/skills/<name>/` にコピーで置かれます(symlink を作らないので Windows でも `--copy` は不要です)
   - ルートの `skills-lock.json` と `.agents/skills/` をコミットします(clone した人は Node.js なしで使えます)
   - `-a claude-code` は指定しません(`/agents-md-setup` が `.claude` を `.agents` へのリンクにするので、Claude Code からも同じ skill が見えます)
2. `/agents-md-setup` を実行して、テンプレートから `AGENTS.md`・`CLAUDE.md`・`.agents/workflow/` 設定を非破壊でスキャフォールドし、`.claude` リンクを作成・検証します
3. `AGENTS.md` の「プロジェクト概要」と「テスト・検証の注意(子エージェント向け)」をプロジェクトに合わせて書きます
4. `.agents/workflow/config.json` の `child_agent.command_template` で子CLIを決めます。既定は `opencode run "{prompt}"` です。Claude Code など他の CLI の設定例は [agents-md-setup/references/parent-child.md](agents-md-setup/references/parent-child.md) を参照してください
5. `test_command` と `quality_gate.steps` の `command` に、プロジェクトのテスト・型検査・lint のコマンドを書きます。設定キーの一覧は [config.json 節](agents-md-setup/templates/workflow/README.md) を参照してください
6. `develop/<作業名>` ブランチを作り、`skills-lock.json`・`.agents/skills/`・`.agents/workflow/`・`AGENTS.md`・`CLAUDE.md`・`.gitignore`・`.gitattributes` をコミットします
7. `/agent-workflow <Issue 番号または計画ドキュメントのパス>` を実行します。親がタスク分解を示して承認を求めるので、確かめて承認すると、子への依頼・レビュー・コミットがタスクごとに進みます

### `.agents/skills/` がすでにある場合

既存の skill はそのまま残り、配布物と同じディレクトリに共存します(配布物と名前が重ならないこと)。

その後はクイックスタートの手順2以降(`/agents-md-setup` の実行など)を続けます。`.claude/skills/` に
skill ごとの個別リンクを置く旧構成になっている場合、`/agents-md-setup` は `.claude` を
`.agents` へのリンクに置き換えるよう提案します(既存の skill も引き続き `.claude/skills/` から見えます)。

## 更新

`workflow-update` skill を実行すると、`npx skills update -p -y` から、配置済みスクリプトとの差分の反映までを行います。
手動で更新する場合は、次の2行を実行します。

```bash
npx skills update -p -y
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh
```

`.agents/workflow/scripts/` と `.agents/workflow/README.md` はセットアップ時のコピーのため、`npx skills update` だけでは更新されません。
差分の反映は `workflow-update` skill が行います。手順は [`workflow-update/SKILL.md`](workflow-update/SKILL.md) にあります。

### git subtree から移行する場合

`.agents/skills/` を `git subtree` で取り込んでいる利用先が対象です。`workflow-update` が `escalate reason=not-npx` を出した場合や、
旧 `workflow-update` が `escalate reason=sync-failed` で止まった場合に進みます。
手順は [`workflow-update/references/migrations.md`](workflow-update/references/migrations.md) の「git subtree から npx skills への移行」にあります。

## 運用ルール

- **配布元の skill**: `.agents/skills/` 以下の配布元 skill は直接編集しません(`npx skills update` で上書きされます)。変更が必要な場合は upstream リポジトリで行ってから `workflow-update` で取り込んでください
- **利用先固有 skill**: プロジェクト独自の skill は、配布物と重ならない名前のディレクトリで追加してください。`npx skills update` は `skills-lock.json` に記録された skill だけを更新するため、共存できます
- **submodule ではない**: `.agents/skills/` と `skills-lock.json` をコミットするので、clone 後の追加操作は `/agents-md-setup` だけです

## 報告と日本語の推敲

### 報告の形

- 親エージェントの報告は、`agent-workflow/references/report-template.md` の3点(状況・起きたこと・次にすること)の形で書きます。場面ごとの書き方も、このファイルにあります
- 進捗は、親が数えずに `workflow-status` で機械的に出します。完了時は `workflow-status --summary` の出力からサマリーを作ります

任意で yomiyasu による日本語の推敲を有効にできます。手順は [`docs/yomiyasu.md`](docs/yomiyasu.md) にあります。

## 困ったとき

- 子CLIの失敗の切り分けと、reason ごとの対処: [`agent-dispatch/references/troubleshooting.md`](agent-dispatch/references/troubleshooting.md)
- sandbox で子CLIがホーム(`~/.config` 等)に書けない場合は、`child_agent.isolate_xdg` を `true` にします(認証情報が見えなくなるので、sandbox 以外では `false` のままにします)。詳細は [`agent-dispatch/references/troubleshooting.md`](agent-dispatch/references/troubleshooting.md) と [`agent-dispatch/references/opencode.md`](agent-dispatch/references/opencode.md)
- スクリプトの exit code と `Next:` 行の意味: [`agents-md-setup/templates/workflow/README.md`](agents-md-setup/templates/workflow/README.md)

## 開発に参加する

本リポジトリの開発手順は [`CONTRIBUTING.md`](CONTRIBUTING.md) にあります。
