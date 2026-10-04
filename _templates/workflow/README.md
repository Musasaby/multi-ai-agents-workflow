# workflow ディレクトリ

マルチエージェント実装ワークフローの状態・設定の正本。

## レイアウト

```
.agents/workflow/
├── config.json / tasks.md / state.json / README.md   ← 正本(人が直接読むファイルのみ)
├── scripts/                      ← 配布物(セットアップ時にコピー、既存は上書きしない)
│   ├── dispatch-run.ps1 / .sh
│   ├── dispatch-check.ps1 / .sh
│   ├── dispatch-prompt-gen.ps1 / .sh
│   ├── dispatch-prompt-template.md
│   ├── dispatch-pr-prompt-template.md   PR作成の単発依頼用(dispatch-prompt-gen --pr)
│   ├── state-sync.ps1 / .sh
│   ├── next-task.ps1 / .sh
│   ├── tasklib.ps1 / tasklib.py  tasks.md 解析・依存欄検証の共通部品
│   ├── upstream-issue.ps1 / .sh
│   ├── upstream-issue-template.md  upstream への Issue 本文テンプレート
│   └── workflow-archive.ps1 / .sh
├── runs/<タスクID>-<試行回数>/   ← 実行単位の生成物(.gitignore対象。PR作成の単発依頼は pr-<N>-1/)
│   ├── prompt.md        生成プロンプト
│   ├── fix-notes.md     リトライ時のレビュー指摘(親が作成)
│   ├── output.log       子エージェントの出力
│   ├── done             完了マーカー(EXIT/END の2行)
│   ├── exit-signal      シグナル番号の一時ファイル(POSIX版のみ。done 書き出し時に削除)
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

Claude Code を子エージェントとして使う場合は `stream-json` 出力を指定する:

```json
"child_agent": {
  "command_template": "claude -p \"{prompt}\" --output-format stream-json --verbose"
}
```

`command_template` に `stream-json` という文字列が含まれる場合、`dispatch-run` は機械的に
整形モードへ分岐する。子CLIのstdoutを1行ずつ読み、生のJSON行はそのまま
`runs/<タスクID>-<試行回数>/output.jsonl` に追記し、パースできた行は人が読めるテキスト
(assistantのテキスト・使用ツール名と入力要約・`result` の要旨等)に変換して
`output.log` へ逐次書き出す(パース不能行はそのまま `output.log` に通す)。
`output.log` は実行中に随時更新されるため `tail -f` / `Get-Content -Wait` で閲覧できる。

**注意**: `--output-format text`(デフォルト)は子CLI側の出力がバッファリングされ、
プロセス終了までの実行中の逐次閲覧ができない。実行中の途中経過を見たい場合は
`stream-json` 形式を指定すること。`stream-json` を含まないテンプレート(OpenCode等)は
従来どおり `output.log` への直接リダイレクトのみで、`output.jsonl` は生成されない。

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

`- **依存**:` 行は `state-sync` / `next-task` / `dispatch-prompt-gen` が機械的にパースする
機械可読フォーマットである。`なし` またはカンマ区切りのタスクID列(`T1, T2`)以外は書かない。
依存欄に挙げたタスクは dispatch 時に完了報告が自動結合される対象になるため、真に前提となる
タスクのみ記載する。

- 依存行はすべてのタスクに必須(依存が無ければ `なし`)
- 注記(例: `T30(Prometheus 基盤。完了済み)`)は書かない。前提タスクに関する補足は**目的欄**に
  書く。完了状態は state.json で機械的に判定するため書かない
- 形式違反・存在しないタスクID・自分自身への依存は `state-sync` / `next-task` /
  `dispatch-prompt-gen` がエラー(exit 1)にし、不正な値を stderr に出す(黙って捨てない)。
  循環依存は `state-sync` と `next-task` が検出する
- タスクの実行順は記述順・ID順ではなく依存関係で決まる(`next-task` が選ぶ)

## state.json(/agent-task-plan が `scripts/state-sync --init` で機械生成、各skillが更新)

機械可読な進捗状態。中断後の再開はこのファイルを起点にする。LLMは直接生成・編集しない。

`branch` は「現在の作業ブランチ」を表す。初期生成時(`state-sync --init`)は git から
自動取得されるが、機能グループ単位でブランチを分割する運用(`agent-workflow` skill の
「ブランチ分割の推奨」)を取る場合、グループ境界でのブランチ切替後にこのフィールドを
現在のブランチ名へ更新し、次のグループの進捗状態コミット(`chore: ...`)に含める。

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
| `1` | 使い方・tasks.md/state.json 不備(タスクID未検出、tasks.md/state.json が無い、依存欄の形式違反・存在しないID・自己依存 等) | 書き出さない |
| `2` | 引き継ぎガード失敗(依存タスクが `done` でない、または依存タスクの `report.md` が見つからない) | 書き出さない(既存の古い prompt.md があれば削除する) |
| `3` | リトライ(`-Attempt 2` 以上)なのに `fix-notes.md` が見つからない | 書き出さない |

exit 0 以外は dispatch を行わず、stderr の内容(exit 2 なら欠落内容の列挙)をそのまま
ユーザーに報告する。

**PR モード**(`-Pr` / `--pr`): PR 作成を子に単発で依頼するプロンプトを
`dispatch-pr-prompt-template.md` から生成し、`runs/pr-<N>-1/prompt.md` に書き出す
(`<N>` は既存の `pr-*` の次の連番)。PR に含めるタスクは、state.json で `done` かつ
`commit` が `git log main..HEAD` に含まれるものを自動で選ぶ。stdout に `RunId: pr-<N>` を
出力するので、`dispatch-run` に `pr-<N>` と `1` を渡して起動する。作業ブランチではなく
`main` 上で実行した場合や、対象タスクが無い場合は exit 1。

```powershell
.agents/workflow/scripts/dispatch-prompt-gen.ps1 -Pr
```
```bash
.agents/workflow/scripts/dispatch-prompt-gen.sh --pr
```exit 0 の場合も生成されたプロンプト全文は会話に読み込まない
(読み込むと機械生成によるトークン節約が無意味になる)。

### dispatch-run — 子エージェントCLIのデタッチ実行

`runs/<タスクID>-<試行回数>/prompt.md` を読み込み、子エージェントCLI(config.json の
`child_agent.command_template`)を stdin を閉じて実行する。stdout/stderr を
`runs/<タスクID>-<試行回数>/output.log` に、終了後に exit code と終了時刻を
`runs/<タスクID>-<試行回数>/done`(`EXIT:` / `END:` の2行)に書き出す。

`EXIT:` の値は、数値(子CLIの exit code)・`signal:<番号>`(子がシグナルで強制終了された。
POSIX 版のみ)・`crashed:<メッセージ>`(ラッパー自体の異常終了。PowerShell 版)のいずれか。
POSIX 版は、Python 経由の起動では子の負の returncode を、bash で直接起動するフォールバック
経路では 128 より大きい終了コードをシグナル終了とみなし、`signal:15` のように記録する
(従来は SIGTERM が `EXIT:241` と記録され、通常の終了と区別できなかった)。
Windows にはシグナルの仕組みが無いため、PowerShell 版での強制終了は通常の非0終了として記録される。
親プロセスのタイムアウト・終了に巻き込まれないよう `Start-Process` / `nohup` 等で
デタッチ起動する。

```powershell
Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/scripts/dispatch-run.ps1 -TaskId T1 -Attempt 1"
```
```bash
nohup .agents/workflow/scripts/dispatch-run.sh T1 1 > /dev/null 2>&1 &
```

### dispatch-check — 完了検知後の終了状態・成果物の判定

`done` マーカーを検知したら毎回実行する。終了状態の区分(`ok` / `nonzero` / `signal` /
`crashed`)、完了報告(`output.log` 内の `## 完了報告`)の有無、`git status --porcelain`、
`git diff --stat`、`output.log` の末尾30行をまとめて出力する。

```powershell
.agents/workflow/scripts/dispatch-check.ps1 -TaskId T1 -Attempt 1
```
```bash
.agents/workflow/scripts/dispatch-check.sh T1 1
```

exit code: `0`=正常終了かつ完了報告あり、`1`=done マーカーが無い・使い方不備、
`4`=異常終了(非0・`signal:*`・`crashed:*`)、`5`=EXIT:0 だが完了報告が無い。
`4` / `5` の場合はレビューに進まず、出力された成果物の有無をユーザーに報告する。

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
- **挿入**(既存タスクの間に新タスクを挟む。新タスクのセクションを tasks.md 末尾に追記してから実行):
  ```powershell
  .agents/workflow/scripts/state-sync.ps1 -Insert T8 -Before T4
  ```
  ```bash
  .agents/workflow/scripts/state-sync.sh --insert T8 --before T4
  ```
  `--before` に指定したタスク(カンマ区切りで複数可)の依存欄に新タスクIDを追加し、
  state.json に新タスクを `pending` で追加する。`--before` のタスクが `pending` でない場合や、
  循環依存になる場合は拒否し、tasks.md / state.json を変更しない。

どのモードでも、state.json を書く前に全タスクの依存欄を検証する(形式違反・存在しないID・
自己依存・循環依存・依存行の欠落)。不正があれば何も書き込まずに exit 1 で終了する。

exit code: `0`=成功、`1`=使い方不備・検証エラー(tasks.md/state.json 不在、`--init` 時の
`--source` 欠落や state.json 既存、依存欄の不正、挿入先が `pending` でない 等)。

### next-task — 次に処理するタスクの選択

state.json の状態と tasks.md の依存関係から、次に処理するタスクを機械的に選ぶ。
state.json の並び順ではなく依存関係を見るため、挿入したタスクも正しい順で選ばれる。

1. `in_progress` / `in_review` のタスク(中断からの再開対象)があれば、その最初のもの
2. なければ、依存タスクがすべて `done` の最初の `pending` タスク

```powershell
.agents/workflow/scripts/next-task.ps1
```
```bash
.agents/workflow/scripts/next-task.sh
```

stdout に `<タスクID> <status>`(例: `T8 pending`)を出力する。

exit code: `0`=該当タスクあり、`1`=tasks.md/state.json 不在・依存欄の不正、`3`=全タスク `done`、
`4`=実行可能なタスクが無い(`failed` や未完了の依存で止まっている。原因を stderr に列挙)。

### upstream-issue — ワークフロー由来の問題を配布元に起票

起票先は `config.json` の `upstream.url`(https / ssh 形式の GitHub URL)から決める。
利用先リポジトリには起票しない。起票は外部への公開を伴うため、`--create` はユーザーの
承認を得てから実行する(手順は `agent-workflow` skill の「upstream への Issue 起票手順」)。

```powershell
.agents/workflow/scripts/upstream-issue.ps1 -Search "<キーワード>"            # 重複候補(open/closed)
.agents/workflow/scripts/upstream-issue.ps1 -Create -Title "<件名>" -BodyFile <パス> -DryRun
```
```bash
.agents/workflow/scripts/upstream-issue.sh --search "<キーワード>"
.agents/workflow/scripts/upstream-issue.sh --create --title "<件名>" --body-file <パス> --dry-run
```

`-DryRun` / `--dry-run` は起票先リポジトリと実行する gh コマンドを表示するだけで、gh を呼ばない。
本文は `upstream-issue-template.md` をもとに作る。ラベルは付けない。

exit code: `0`=成功、`1`=使い方不備・`upstream.url` 未設定・GitHub 以外の URL、その他=gh の exit code。

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
