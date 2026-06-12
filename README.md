# multi-ai-agents-workflow

AIエージェント(Claude Code、OpenCode 等)による複数エージェント協調の実装ワークフローを、任意のプロジェクトに導入できる汎用テンプレートです。

## 含まれるもの

| ファイル・ディレクトリ | 説明 |
|---|---|
| `AGENTS.md` | エージェント向け指示の正本。プロジェクト固有の内容を記入して使用してください |
| `CLAUDE.md` | Claude Code 用の `@AGENTS.md` import ラッパー |
| `.agents/skills/agents-md-setup/SKILL.md` | 正本化セットアップとリンク検証 |
| `.agents/skills/agent-task-plan/SKILL.md` | 計画→タスク分解 |
| `.agents/skills/agent-dispatch/SKILL.md` | 子エージェントへの実装指示・テスト実行 |
| `.agents/skills/agent-review-commit/SKILL.md` | レビュー・修正再依頼・コミット |
| `.agents/skills/agent-workflow/SKILL.md` | 全体オーケストレーター(中断再開対応) |
| `.agents/workflow/README.md` | `config.json` / `tasks.md` / `state.json` の仕様 |
| `.agents/workflow/config.json` | ワークフロー設定(子エージェントCLI・テスト・リトライ設定) |
| `.gitignore` | `.claude` リンクと個人設定の除外 |

## 使い方

1. このリポジトリのファイルをプロジェクトルートにコピー
2. `AGENTS.md` の「プロジェクト概要」をプロジェクトに合わせて書き換える
3. `agents-md-setup` skill を実行して `.claude` リンクを作成・検証
4. `/agent-workflow <Issue ID または計画ドキュメントのパス>` でワークフローを開始

## ワークフローの流れ

```
1. 計画参照・タスク分解   → /agent-task-plan
2. 各タスクを順次実行:
   a. 実装dispatch        → /agent-dispatch
   b. レビュー・コミット  → /agent-review-commit
3. 全タスク完了 → サマリー報告
```

## 前提

- プロジェクトは Git 管理されていること
- `main` ブランチへの直接コミットは禁止。`develop/<作業名>` ブランチで作業
- 子エージェントCLIは `.agents/workflow/config.json` の `child_agent.command_template` で設定
