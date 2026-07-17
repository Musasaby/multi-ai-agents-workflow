# workflow ディレクトリ

マルチエージェント実装ワークフローの状態・設定の正本。

## レイアウト

```
.agents/workflow/
├── config.json / tasks.md / state.json / README.md   ← 正本(人が直接読むファイルのみ)
├── scripts/                      ← 配布物(セットアップ時にコピー、既存は上書きしない)
│   ├── dispatch-run.ps1 / .sh
│   ├── dispatch-prompt-gen.ps1 / .sh
│   ├── dispatch-prompt-template.md
│   ├── state-sync.ps1 / .sh
│   └── workflow-archive.ps1 / .sh
├── runs/<タスクID>-<試行回数>/   ← 実行単位の生成物(.gitignore対象)
│   ├── prompt.md        生成プロンプト
│   ├── fix-notes.md     リトライ時のレビュー指摘(親が作成)
│   ├── output.log       子エージェントの出力
│   ├── done             完了マーカー(EXIT/END の2行)
│   └── report.md        完了報告
├── comprehension/                ← 理解確認(タスク単位)
├── archive/<日時-スラッグ>/      ← 一巡した過去サイクルの退避先(.gitignore対象)
└── .config/                      ← 子エージェントCLIのXDG退避先
```

- `runs/` はタスク×試行ごとにディレクトリが分かれるため、リトライ時に過去の
  プロンプト・ログ・報告が上書きされず残る(事後調査に使える)
- 一巡(全タスク `done`)した後は `workflow-archive` で `tasks.md` / `state.json` /
  `runs/` / `comprehension/` を `archive/` へ退避し、新サイクルは空の状態から始める
  (config.json と scripts/ は退避対象外)

## config.json

| キー | 説明 | デフォルト |
|------|------|-----------|
| `child_agent.command_template` | 子エージェントCLIのコマンドテンプレート。`{prompt}` がタスクプロンプトに展開される | `opencode run "{prompt}"` |
| `child_agent.timeout_seconds` | 子エージェント実行のタイムアウト(秒) | `1800` |
| `test_command` | 子エージェントに実行させるテストコマンド。空ならタスクごとに親が指定 | `""` |
| `verify_before_commit` | コミット直前に親がテストコマンドを1回実行する最終ゲート | `false` |
| `max_fix_retries` | レビュー不合格時の子エージェントへの再依頼上限。超過で親のサブエージェントにフォールバック | `2` |
| `comprehension_check.enabled` | タスク合格時に理解確認質問を生成するか | `false` |
| `comprehension_check.questions_per_task` | タスクあたりの質問数 | `3` |
| `quality_gate.steps` | 品質ゲートのステップ定義。各要素は `name`(表示名)・`command`(実行コマンド)・`blocking`(真なら不合格時に進行停止)を持つ | `[{name:typecheck,...},{name:test,...},{name:lint,...}]` |
| `quality_gate.child_dispatch_command` | 子エージェントへの検証指示に使う統合コマンド。空文字列でなければ blocking ステップの個別列挙に代えてこの1コマンドを子に指示する。Gradle 等のデーモンの多重コールドスタート回避に有効 | `""` |
| `upstream.url` | upstream リポジトリの URL。`workflow-update` skill で使用 | `https://github.com/Musasaby/multi-ai-agents-workflow.git` |
| `upstream.branch` | upstream 追従ブランチ名 | `main` |

## tasks.md(/agent-task-plan が生成)

タスク定義の正本。子エージェントもこのファイルを参照する。フォーマット:

```markdown
# タスク一覧: <計画ソース(Issue #N またはドキュメントパス)>

## T1: <タスクタイトル>
- **目的**: 何を達成するか
- **対象**: 変更が想定されるファイル・モジュール
- **受け入れ基準**:
  - [ ] 基準1(検証可能な形で記述)
  - [ ] 基準2
- **依存**: なし | T1, T2
```

`- **依存**:` 行は `dispatch-prompt-gen` が正規表現でパースする機械可読フォーマットである。
`なし` またはカンマ区切りのタスクID列(`T1, T2`)以外は書かない。依存欄に挙げたタスクは
dispatch 時に完了報告が自動結合される対象になるため、真に前提となるタスクのみ記載する。

## state.json(/agent-task-plan が `scripts/state-sync --init` で機械生成、各skillが更新)

機械可読な進捗状態。中断後の再開はこのファイルを起点にする。LLMは直接生成・編集しない。

```json
{
  "source": "Issue #12 | docs/plan.md",
  "branch": "develop/xxx",
  "updated_at": "2026-06-12T10:00:00+09:00",
  "tasks": [
    {
      "id": "T1",
      "title": "...",
      "status": "pending",
      "retries": 0,
      "commit": null
    }
  ]
}
```

`status` の遷移: `pending` → `in_progress`(dispatch) → `in_review`(子の完了報告)
→ `done`(レビュー合格・コミット済み、`commit` にハッシュを記録) / 不合格は `in_progress` に戻し `retries` をインクリメント。
回復不能な失敗は `failed`(ユーザーへエスカレーション)。

## scripts/ 配下のスクリプト

いずれも `.agents/workflow/scripts/` にコピーして実行する(PowerShell版 `.ps1` / POSIX版 `.sh` の
2系統。挙動・exit codeは揃えてある)。生成・更新対象はすべて `.agents/workflow/` 配下。

### dispatch-prompt-gen — dispatchプロンプトの機械生成

tasks.md・config.json・依存タスクの完了報告(直接依存のみ)から、子エージェントに渡す
プロンプトを機械的に組み立てて `runs/<タスクID>-<試行回数>/prompt.md` に書き出す。
定型文(実装ルール・テスト検証指示・完了報告フォーマット)は `dispatch-prompt-template.md`
から展開する。

```powershell
# PowerShell(初回 = Attempt省略で1、リトライは -Attempt <n>)
.agents/workflow/scripts/dispatch-prompt-gen.ps1 -TaskId T3
.agents/workflow/scripts/dispatch-prompt-gen.ps1 -TaskId T3 -Attempt 2
```
```bash
# POSIX
.agents/workflow/scripts/dispatch-prompt-gen.sh T3
.agents/workflow/scripts/dispatch-prompt-gen.sh T3 2
```

**exit code 規約**:

| exit | 意味 | 生成物 |
|------|------|--------|
| `0` | 生成成功 | `runs/<タスクID>-<試行回数>/prompt.md` を書き出す |
| `1` | 使い方・tasks.md/state.json 不備(タスクID未検出、tasks.md/state.json が無い 等) | 書き出さない |
| `2` | 引き継ぎガード失敗(依存タスクが `done` でない、または依存タスクの `report.md` が見つからない) | 書き出さない(既存の古い prompt.md があれば削除する) |
| `3` | リトライ(`-Attempt 2` 以上)なのに `fix-notes.md` が見つからない | 書き出さない |

exit 0 以外は dispatch を行わず、stderr の内容(exit 2 なら欠落内容の列挙)をそのまま
ユーザーに報告する。exit 0 の場合も生成されたプロンプト全文は会話に読み込まない
(読み込むと機械生成によるトークン節約が無意味になる)。

### dispatch-run — 子エージェントCLIのデタッチ実行

`runs/<タスクID>-<試行回数>/prompt.md` を読み込み、子エージェントCLI(config.json の
`child_agent.command_template`)を stdin を閉じて実行する。stdout/stderr を
`runs/<タスクID>-<試行回数>/output.log` に、終了後に exit code と終了時刻を
`runs/<タスクID>-<試行回数>/done`(`EXIT:` / `END:` の2行)に書き出す。
親プロセスのタイムアウト・終了に巻き込まれないよう `Start-Process` / `nohup` 等で
デタッチ起動する。

```powershell
Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/scripts/dispatch-run.ps1 -TaskId T1 -Attempt 1"
```
```bash
nohup .agents/workflow/scripts/dispatch-run.sh T1 1 > /dev/null 2>&1 &
```

### state-sync — state.json の機械生成・追記同期

tasks.md の `## T<n>:` 見出しを走査し、state.json を機械的に生成・更新する。LLMが
JSONを直接書くことはない。

- **初期生成**(`agent-task-plan` の§3で使用):
  ```powershell
  .agents/workflow/scripts/state-sync.ps1 -Init -Source "<計画ソース>"
  ```
  ```bash
  .agents/workflow/scripts/state-sync.sh --init --source "<計画ソース>"
  ```
  state.json が既に存在する場合はエラー(exit 1)。branch は git から自動取得する。
- **追記同期**(タスクの途中追加時。既存タスクの `status`/`retries`/`commit` には触れない):
  ```powershell
  .agents/workflow/scripts/state-sync.ps1
  ```
  ```bash
  .agents/workflow/scripts/state-sync.sh
  ```
  tasks.md に無いIDが state.json 側にある場合は警告のみ(削除は手動判断)。

exit code: `0`=成功、`1`=使い方不備(tasks.md/state.json 不在、`--init` 時の `--source` 欠落や
state.json 既存 等)。

### workflow-archive — 一巡後のサイクル退避

`tasks.md` / `state.json` / `runs/` / `comprehension/` を
`archive/<YYYYMMDD-HHmm>-<スラッグ>/` へ移動する(`config.json` と `scripts/` は残す)。

```powershell
.agents/workflow/scripts/workflow-archive.ps1 <スラッグ>
```
```bash
.agents/workflow/scripts/workflow-archive.sh <スラッグ>
```

exit code: `0`=成功、`1`=使い方不備(スラッグ未指定・パス区切りや `..` を含む・
workflow ディレクトリ不在・移動対象なし)。
