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

### 0. 開始時判定(新規 or 追加)

既存の `.agents/workflow/state.json` の有無と状態で分岐する:

- **state.json が無い** → 通常モード(§1〜§5)で新規作成する
- **state.json があり、全タスクが `done`** → 一巡完了とみなし、確認なしで
  `scripts/workflow-archive`(PowerShell: `.agents/workflow/scripts/workflow-archive.ps1`
  / POSIX: `workflow-archive.sh`)にスラッグを渡してアーカイブしてから、通常モードで
  新規作成する
  ```powershell
  .agents/workflow/scripts/workflow-archive.ps1 <スラッグ>
  ```
  ```bash
  .agents/workflow/scripts/workflow-archive.sh <スラッグ>
  ```
  スラッグは計画ソースやIssue番号から簡潔に生成する(例: `issue-42`)。
- **state.json があり、未完了タスクが残っている** → 「進行中のワークフローがあるが
  破棄してよいか」をユーザーに確認する。破棄する場合も削除ではなく上記と同じ
  `workflow-archive` でアーカイブする(履歴が残るため安全に「破棄」できる)。
  破棄しない場合は §「追加モード」に進む(ユーザーが途中追加を意図している場合)か、
  作業を中断する。

### 1. 計画の読解

計画ソースを読み、目的・スコープ・制約を把握する。関連する既存コードを Grep/Glob で
調査し、変更対象の見当をつける。

### 2. タスク分解

以下の基準でタスクに分解する:

- 1タスク = 子エージェントへの1回の依頼で完結する粒度(目安: 変更ファイル数個、1コミット相当)
- 各タスクに**検証可能な受け入れ基準**を必ず書く(「〜が動く」ではなく「〜を実行すると〜になる」)
- タスク間の依存関係を明示し、依存順に並べる
- テスト方法が自明でないタスクには、受け入れ基準にテストコマンド・確認手順を含める

**依存欄の指針**:

- 機械パース可能な厳密フォーマットを厳守する: `- **依存**: なし | T1, T2`
  (依存が無い場合は `なし`、ある場合はカンマ区切りのタスクID列。この行を
  `dispatch-prompt-gen` が正規表現でパースするため、フォーマットを崩さない)
- 依存は**真の前提となるタスクのみ**記載する。単に記述の並び順を揃えたいだけの理由で
  依存を張らない
- **依存欄 = 引き継ぎが発生する欄**であることを踏まえる: 依存に挙げたタスクの完了報告
  (`runs/<依存ID>-<試行番号>/report.md`)が dispatch 時に自動結合される。不要な依存を
  書くと不要な引き継ぎ文がプロンプトに混入し、依存漏れがあると引き継ぎガードで
  dispatch が止まる(依存タスクが `done` かつ報告が存在することが条件)

### 3. ファイル生成

`.agents/workflow/README.md` に記載のフォーマットに従って生成する(`.agents/workflow/README.md` が存在しない場合は `.agents/skills/_templates/workflow/README.md`（配布元リポジトリではルートの `_templates/workflow/README.md`）を参照する。本来は `/agents-md-setup` の再実行で `.agents/workflow/README.md` が配置されるため、利用先で欠落している場合はセットアップ手順を見直すこと):

- `.agents/workflow/tasks.md` — タスク定義の正本(子エージェントも参照する)。**LLMが
  生成するのはこのファイルのみ**
- `.agents/workflow/state.json` — LLMは生成しない。tasks.md を書き終えたら
  `scripts/state-sync`(PowerShell: `.agents/workflow/scripts/state-sync.ps1` / POSIX:
  `state-sync.sh`)を `--init` オプションで実行し、機械生成する。`--source` には
  計画ソース(Issue URL やドキュメントパス)を渡す。branch は git から自動取得される

  ```powershell
  .agents/workflow/scripts/state-sync.ps1 -Init -Source "<計画ソース>"
  ```
  ```bash
  .agents/workflow/scripts/state-sync.sh --init --source "<計画ソース>"
  ```

  実行後、全タスクが `"status": "pending"`, `"retries": 0`, `"commit": null` で
  初期化された state.json が生成される。state.json が既に存在する場合はエラー
  終了する(§0 の分岐で新規作成が確定している状態でのみ実行すること)。

### 4. Claude Code Task への同期

TaskCreate で各タスクを進捗表示用に登録する(正本はあくまでファイル側)。

### 5. ユーザー承認

分解結果(タスク一覧と受け入れ基準)を提示し、承認を得てから次フェーズ
(`/agent-dispatch` または `/agent-workflow` のループ)に進む。

## 追加モード(タスクの途中追加)

サイクル途中でレビューにより派生タスクが見つかった場合や、ユーザーが要件を
追加した場合に使う。**既存タスクは一切書き換えず、追記のみで完結させる**。

1. **新IDの採番**: `.agents/workflow/state.json` から既存の最大タスクID
   (例: 既存最大が `T7` なら次は `T8`)を取得する。**tasks.md 全文は読み直さない**
   (state.json だけで採番が完結する)
2. **追記専用**: `.agents/workflow/tasks.md` の末尾に、新IDのセクションのみを
   §2 と同じ基準(検証可能な受け入れ基準・依存欄の厳密フォーマット)で追記する。
   既存セクションには一切触れない
3. **依存**: 既存タスク(`done` 済みタスクも含む)を依存先にしてよい。`done`
   タスクへの依存は、引き継ぎガードが `report.md` の存在を保証しているため
   問題なく解決できる
4. **state.json への反映**: `state-sync` を `--init` なしで実行し、追加分のみを
   `pending` として追記する(既存タスクの `status` / `retries` / `commit` は
   一切変更されない)

   ```powershell
   .agents/workflow/scripts/state-sync.ps1
   ```
   ```bash
   .agents/workflow/scripts/state-sync.sh
   ```

5. **TaskCreate も追加分のみ**登録する(既存タスクの再登録はしない)
6. **ユーザー承認も追加分のみ**提示する(既存タスク一覧の再提示はしない)

このモードでの親のLLM出力は「追加するタスクのセクション」だけに限る。既存部分の
再読・再出力・state.json の手書き編集は行わない。
