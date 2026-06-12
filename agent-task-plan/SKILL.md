---
name: agent-task-plan
description: GitHub IssueのIDまたは計画ドキュメントのパスを引数に取り、計画を実装タスクに分解して .agents/workflow/tasks.md と state.json を生成する。マルチエージェント実装ワークフローの計画フェーズ。
---

# 計画参照とタスク分解

引数で与えられた計画ソースを読み、子エージェントに依頼可能な粒度のタスクに分解する。

## 引数

- 数値(例: `42`)または `#42` 形式 → GitHub Issue とみなし `gh issue view <ID> --comments` で取得
- それ以外 → 計画ドキュメントのパスとみなし Read で読む

引数がない場合はユーザーに計画ソースを質問する。

## 手順

### 1. 計画の読解

計画ソースを読み、目的・スコープ・制約を把握する。関連する既存コードを Grep/Glob で
調査し、変更対象の見当をつける。

### 2. タスク分解

以下の基準でタスクに分解する:

- 1タスク = 子エージェントへの1回の依頼で完結する粒度(目安: 変更ファイル数個、1コミット相当)
- 各タスクに**検証可能な受け入れ基準**を必ず書く(「〜が動く」ではなく「〜を実行すると〜になる」)
- タスク間の依存関係を明示し、依存順に並べる
- テスト方法が自明でないタスクには、受け入れ基準にテストコマンド・確認手順を含める

### 3. ファイル生成

`.agents/workflow/README.md` に記載のフォーマットに従って生成する(`.agents/workflow/README.md` が存在しない場合は `.agents/skills/_templates/workflow/README.md`（配布元リポジトリではルートの `_templates/workflow/README.md`）を参照する。本来は `/agents-md-setup` の再実行で `.agents/workflow/README.md` が配置されるため、利用先で欠落している場合はセットアップ手順を見直すこと):

- `.agents/workflow/tasks.md` — タスク定義の正本(子エージェントも参照する)
- `.agents/workflow/state.json` — 全タスクを `"status": "pending"`, `"retries": 0`, `"commit": null` で初期化。`source` に計画ソース、`branch` に現在のブランチを記録

既存の state.json に未完了タスクが残っている場合は上書きせず、ユーザーに
「進行中のワークフローがあるが破棄してよいか」を確認する。

### 4. Claude Code Task への同期

TaskCreate で各タスクを進捗表示用に登録する(正本はあくまでファイル側)。

### 5. ユーザー承認

分解結果(タスク一覧と受け入れ基準)を提示し、承認を得てから次フェーズ
(`/agent-dispatch` または `/agent-workflow` のループ)に進む。
