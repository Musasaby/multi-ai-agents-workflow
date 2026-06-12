# multi-ai-agents-workflow

AIエージェント(Claude Code、OpenCode 等)による複数エージェント協調の実装ワークフローを、任意のプロジェクトに `git subtree` で導入できる配布物です。

## 含まれるもの

| ファイル・ディレクトリ | 説明 |
|---|---|
| `agent-workflow/` | 全体オーケストレーター(中断再開対応) |
| `agent-task-plan/` | 計画→タスク分解 |
| `agent-dispatch/` | 子エージェントへの実装指示・テスト実行 |
| `agent-review-commit/` | レビュー・修正再依頼・コミット |
| `agents-md-setup/` | 正本化セットアップとリンク検証 |
| `workflow-update/` | `git subtree` ベースの更新支援 |
| `_templates/` | 利用先用テンプレート(`AGENTS.md`, `CLAUDE.md`, `workflow/config.json`, `workflow/README.md`) |
| `.gitignore` | `.claude` リンクと個人設定の除外 |

## 前提

- プロジェクトは Git 管理されていること
- `git subtree` は標準 Git に同梱されているため、追加ツールは不要です
- `main` ブランチへの直接コミットは禁止。`develop/<作業名>` ブランチで作業
- 子エージェントCLIは `.agents/workflow/config.json` の `child_agent.command_template` で設定

## 導入手順

1. 利用先プロジェクトのルートで以下を実行:
   ```bash
   git subtree add --prefix=.agents/skills https://github.com/Musasaby/multi-ai-agents-workflow.git main --squash
   ```
2. `/agents-md-setup` skill を実行して、テンプレートから `AGENTS.md`・`CLAUDE.md`・`.agents/workflow/` 設定を非破壊でスキャフォールドし、`.claude` リンクを作成・検証
3. `AGENTS.md` の「プロジェクト概要」をプロジェクトに合わせて書き換える
4. `/agent-workflow <Issue ID または計画ドキュメントのパス>` でワークフローを開始

## 更新手順

`.agents/skills/` 以下の skill は `workflow-update` skill を実行するか、手動で以下を実行して更新します。

```bash
git subtree pull --prefix=.agents/skills https://github.com/Musasaby/multi-ai-agents-workflow.git main --squash
```

## 旧コピー方式からの移行手順

以前は「ファイルをコピーして配置」する方式でした。現在は `git subtree` 方式に統一しています。

1. 既存の `.agents/skills/` を削除します:
   ```bash
   git rm -rf .agents/skills
   git commit -m "chore: remove old copied skills for subtree migration"
   ```
2. 上記「導入手順」を実行して subtree で再導入します
3. テンプレートが既にコピー済みの場合は、差分を確認して必要に応じて上書きしてください

## 運用ルール

- **vendored skill (subtree由来)**: `.agents/skills/` 以下の配布元 skill は直接編集せず、変更が必要な場合は upstream リポジトリで行ってから `workflow-update` で取り込んでください
- **利用先固有 skill**: プロジェクト独自の skill は `.agents/skills/` 内に upstream の skill 名と被らない名前のディレクトリとして追加してください。`git subtree pull` のマージはローカル固有のファイルを保持するため、upstream 更新と共存できます
- **submodule ではない**: 本配布物は `git subtree` で管理します。`git submodule` とは仕組みが異なり、利用先のリポジトリに skill の内容が直接含まれるため、clone 時の追加操作が不要です

## ワークフローの流れ

```
1. 計画参照・タスク分解   → /agent-task-plan
2. 各タスクを順次実行:
   a. 実装dispatch        → /agent-dispatch
   b. レビュー・コミット  → /agent-review-commit
3. 全タスク完了 → サマリー報告
```

## 開発者向け(本リポジトリの開発)

本リポジトリを直接開発する際、skill を `.claude/skills/` 配下に個別にリンクすることで、編集を即座に反映できます。

### Windows (PowerShell)

```powershell
New-Item -ItemType Directory -Path .claude\skills -Force
foreach ($s in 'agent-workflow','agent-task-plan','agent-dispatch','agent-review-commit','agents-md-setup','workflow-update') {
  New-Item -ItemType Junction -Path ".claude\skills\$s" -Target "$PWD\$s"
}
```

### macOS / Linux

```bash
mkdir -p .claude/skills
for s in agent-workflow agent-task-plan agent-dispatch agent-review-commit agents-md-setup workflow-update; do
  ln -s "$PWD/$s" ".claude/skills/$s"
done
```

### ワークフロー設定

`.agents/workflow/config.json` は `_templates/workflow/config.json` をプロジェクトルートにコピーして使用してください。

```bash
cp _templates/workflow/config.json .agents/workflow/config.json
```
