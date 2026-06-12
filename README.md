# multi-ai-agents-workflow

AIエージェント(Claude Code、OpenCode 等)による複数エージェント協調の実装ワークフローを、任意のプロジェクトに `git subtree` で導入できる配布物です。

## 含まれるもの

| ファイル・ディレクトリ | 説明 |
|---|---|
| `agent-workflow/` | 全体オーケストレーター(中断再開対応) |
| `agent-task-plan/` | 計画→タスク分解 |
| `agent-dispatch/` | 子エージェントへの実装指示・テスト実行 |
| `agent-comprehension-check/` | 回答済み質問ファイルの判定・解説(別セッション対応) |
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
      - config有効時、合格時に質問ファイルを生成
3. 全タスク完了 → サマリー報告(未回答の質問一覧含む)
```

理解確認(任意・デフォルト無効): 質問ファイルに回答後、`/agent-comprehension-check` で判定・解説を依頼(別セッション可)

## 開発者向け(本リポジトリの開発)

本リポジトリの `.claude` は `.agents` へのジャンクション(標準形)です。
skill の編集はリポジトリルート直下の各ディレクトリ(`agent-workflow/` 等)が正本です。

### 注意: `.claude/skills` 経由での反映遅延

ルート直下で skill を編集しても、subtree 同期(`git subtree pull` または `workflow-update` skill)で squash merge するまで、`.claude/skills` 経由の Claude Code 等には反映されません。

**即時反映が必要な場合**は以下のいずれかを行ってください:

1. **subtree 同期を実行する**(後述): ルートの変更をコミット後、下記の手動同期手順で `.agents/skills/` に反映します
2. **一時的に `.agents/skills/<name>/` へ手動コピーする**: 編集した skill ディレクトリを `.agents/skills/<name>/` に一時コピーします。ただし、subtree 同期時にコンフリクトが起きる可能性があるため、テスト用途に限定してください

### `.agents/skills/` への手動同期(配布元リポジトリ固有の手順)

> **なぜ `git subtree pull` が使えないか**: 本リポジトリは自分自身を `.agents/skills/` に subtree として取り込む構成のため、同一ブランチからの `git subtree pull` はマージが no-op になり、prefix 側のファイルが更新されません。

ルートのskill編集を `.agents/skills/` に反映する正しい手順:

```powershell
# 1. ルートの変更をコミット済みであることを確認
git status --porcelain  # クリーンであること

# 2. squash コミットを生成(ツリーのスナップショット)
$squash = git subtree split --prefix=.agents/skills HEAD
# → コミットハッシュ(例: 1a0aa4c)が出力される

# 3. 現在の .agents/skills を削除してステージ
git rm -rq .agents/skills

# 4. squash ツリーを .agents/skills に展開
git read-tree --prefix=.agents/skills/ $squash
git checkout-index -af

# 5. 自己再帰ディレクトリを除去(.agents/skills/.agents が混入するため)
git rm -rq .agents/skills/.agents

# 6. コミット
git commit -m "chore: .agents/skills を最新のskillに同期"
```

### 旧構成からの移行

以前の「`.claude/skills` 配下に各 skill への個別ジャンクション/シンボリックリンクを作成する」方式は、現在の「`.claude` 全体を `.agents` へのジャンクションとする」標準形に統一されています。

### ワークフロー設定

`.agents/workflow/config.json` は `_templates/workflow/config.json` をプロジェクトルートにコピーして使用してください。

```bash
cp _templates/workflow/config.json .agents/workflow/config.json
```

## サンドボックス環境での実行注意点

Codex 等のサンドボックス環境で子エージェント CLI(opencode 等)を実行する際、CLI がホームディレクトリ(`~/.config` 等)への書込を必要とする場合があります。

制限環境では `EEXIST: file already exists, mkdir '~/.config/opencode'` 等のエラーで CLI が起動失敗する場合があります。対処の詳細は `agent-dispatch/SKILL.md` の「トラブルシューティング」節を参照してください。

簡易対処として、子エージェント CLI 起動時に `XDG_CONFIG_HOME` と `XDG_DATA_HOME` をプロジェクト内の書き込み可能なディレクトリに向ける方法があります。`/agents-md-setup` は `.agents/workflow/.config/opencode/log` を事前作成します。

```powershell
# PowerShell の例
$env:XDG_CONFIG_HOME = ".agents/workflow/.config"
$env:XDG_DATA_HOME = ".agents/workflow/.config"
$null | opencode run $prompt
```

```bash
# POSIX シェルの例
XDG_CONFIG_HOME=.agents/workflow/.config XDG_DATA_HOME=.agents/workflow/.config opencode run "$prompt" < /dev/null
```
