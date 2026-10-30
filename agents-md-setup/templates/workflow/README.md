# workflow ディレクトリ

マルチエージェント実装ワークフローの状態・設定の正本。

## レイアウト

```
.agents/workflow/
├── config.json / tasks.md / state.json / README.md   ← 正本(人が直接読むファイルのみ)
├── scripts/                      ← 配布物(セットアップ時にコピー、既存は上書きしない。更新は workflow-sync-scripts)
│   ├── dispatch-start.ps1 / .sh  事前チェック〜デタッチ起動
│   ├── dispatch-run.ps1 / .sh
│   ├── dispatch-wait.ps1 / .sh  子の完了待ち(done 検知後に dispatch-check)
│   ├── dispatch-check.ps1 / .sh
│   ├── git-state.ps1 / .sh  git 状態(HEAD・ブランチ・参照・config)の4行出力(dispatch-run/dispatch-check が使用)
│   ├── dispatch-prompt-gen.ps1 / .sh
│   ├── dispatch-prompt-template.md
│   ├── dispatch-pr-prompt-template.md   PR作成の単発依頼用(dispatch-prompt-gen --pr)
│   ├── state-sync.ps1 / .sh
│   ├── req-status.ps1 / .sh  要件ごとの充足状況の一覧(グループ・サイクル完了時の充足確認に使う)
│   ├── next-task.ps1 / .sh
│   ├── group-advance.ps1 / .sh  グループ完了後の PR 状態判定と次グループのブランチ切替
│   ├── branch-check.ps1 / .sh  今のブランチが作業に使ってよいかの判定(main 上・PR マージ済み・state.json との不一致)
│   ├── quality-gate.ps1 / .sh  品質ゲート(quality_gate.steps の実行と判定)
│   ├── task-state.ps1 / .sh
│   ├── task-commit.ps1 / .sh  レビュー合格後のコミットと状態更新
│   ├── tasklib.ps1 / tasklib.py  tasks.md 解析・依存欄検証の共通部品
│   ├── upstream-issue.ps1 / .sh
│   ├── upstream-issue-template.md  upstream への Issue 本文テンプレート
│   ├── workflow-setup.ps1 / .sh  セットアップ(テンプレート側から実行)
│   ├── workflow-update.ps1 / .sh  `npx skills update` 後の確認(テンプレート側から実行)
│   ├── workflow-sync-scripts.ps1 / .sh
│   ├── workflow-logs.ps1 / .sh  複数の run のログを1つの画面に流す
│   └── workflow-archive.ps1 / .sh
├── runs/<タスクID>-<試行回数>/   ← 実行単位の生成物(.gitignore対象。PR作成の単発依頼は pr-<N>-1/)
│   ├── prompt.md        生成プロンプト
│   ├── fix-notes.md     リトライ時のレビュー指摘(親が作成)
│   ├── guard.sha256     起動時の管理ファイルの SHA-256(dispatch-run が作成、dispatch-check が改ざん検知に使う)
│   ├── git-state.txt    起動時の git 状態の4行(git-state の出力。dispatch-run が作成、dispatch-check が改ざん検知に使う)
│   ├── worktree/        max_parallel が 2 以上のとき、その run の子が作業する git worktree(collect で消える)
│   ├── worktree.txt     worktree の path / branch / base の3行(dispatch-worktree create が作成、dispatch-run・dispatch-check が読む)
│   ├── changes.patch    collect が worktree の変更から作る差分(本体へ git apply する)
│   ├── tmp/             子エージェントの一時ディレクトリ(TMPDIR・TEMP・TMP がここを指す。GIT_CEILING_DIRECTORIES はその親の runs/<タスクID>-<試行回数>/ を指す)
│   ├── output.log       子エージェントの出力
│   ├── done             完了マーカー(EXIT/END の2行)
│   ├── exit-signal      シグナル番号の一時ファイル(POSIX版のみ。done 書き出し時に削除)
│   └── report.md        完了報告(dispatch-check が ok / no-changes のとき自動で保存)
├── comprehension/                ← 理解確認(タスク単位)
├── archive/<日時-スラッグ>/      ← 一巡した過去サイクルの退避先(.gitignore対象)
└── .config/                      ← 子エージェントCLIのXDG退避先(isolate_xdg: true のときのみ使用)
```

- `runs/` はタスク×試行ごとにディレクトリが分かれるため、リトライ時に過去の
  プロンプト・ログ・報告が上書きされず残る(事後調査に使える)
- 一巡(全タスク `done`)した後は `workflow-archive` で `tasks.md` / `state.json` /
  `runs/` / `comprehension/` を `archive/` へ退避し、新サイクルは空の状態から始める
  (config.json と scripts/ は退避対象外)。作業ブランチの PR がマージされるまではアーカイブしない
  (未マージなら PR のレビューの残課題は追加モードで今のサイクルに足す)

## config.json

| キー | 説明 | デフォルト |
|------|------|-----------|
| `child_agent.command_template` | 子エージェントCLIのコマンドテンプレート。`{prompt}` はプロンプト本文、`{prompt_file}` は prompt.md の絶対パス(`/` 区切り)に展開される。どちらも無ければプロンプトを stdin で渡す | `opencode run "{prompt}"` |
| `child_agent.profile` | 子CLIのプロファイル名。出力の変換方法とログからの検知パターンを決める。未指定・空は `auto`(「子CLIのプロファイル」を参照) | `""` |
| `child_agent.timeout_seconds` | 子エージェント実行のタイムアウト(秒)。`dispatch-wait` が判定する | `1800` |
| `child_agent.isolate_xdg` | `true` なら `dispatch-run` が子CLIの `XDG_CONFIG_HOME` / `XDG_DATA_HOME` を `.agents/workflow/.config` に切り替える(sandbox で `~/.config` 等に書けない環境向け)。切り替えると `~/.local/share/<CLI>/auth.json` 等の認証情報が見えなくなる。未指定は `false` | `false` |
| `child_agent.healthcheck_command` | `dispatch-start` が起動前に実行する疎通確認のコマンド。空なら省略 | `""` |
| `child_agent.warmup_command` | サイクルの最初の dispatch の前に1回だけ実行するコマンド(例: ビルドツールのデーモン起動・依存の取得など)。空なら省略 | `""` |
| `child_agent.idle_timeout_seconds` | 子のログ(`output.log`)が更新されない時間の上限(秒)。超えると `dispatch-run` が子を止め、`done` に `EXIT:idle-timeout` を記録する(`dispatch-check` は exit 4)。未指定・0 以下は無効。POSIX 版は python3 経路のみ対応 | `600` |
| `child_agent.cli_log` | 子CLI自身のログファイルのパス(先頭の `~/` はホームディレクトリ。例: opencode は `~/.local/share/opencode/log/opencode.log`)。`dispatch-check` がエラー行を出す | 未指定 |
| `test_command` | 子エージェントに実行させるテストコマンド。空ならタスクごとに親が指定。`quality_gate.steps` の test ステップと同じコマンドに揃える | `""` |
| `branch_per_group` | tasks.md にグループ区切り(`<!-- グループ <名前> -->`)がある場合に、グループ単位の PR 作成・ブランチ切替(next-task の exit 6 と `group-advance`)を必須手順にする。`false` ならグループを解釈せず全タスクを1つのまとまりとして扱う。config.json が無い・読めない場合の既定値も `true` | `true` |
| `verify_before_commit` | コミット直前に親がテストコマンドを1回実行する最終ゲート | `false` |
| `max_fix_retries` | レビュー不合格時の子エージェントへの再依頼上限。超過で親のサブエージェントにフォールバック | `2` |
| `max_parallel` | 同時に実行するタスク数の上限。2 以上にすると next-task が、依存がすべて完了していて変更対象のファイルが互いに(実行中のタスクとも)重ならないタスクを同時に選び(重なりはディレクトリを含めて判定する。`src/` と `src/app.py` は重なり、`src/a` と `src/ab` は重ならない)、各 run を worktree で実行する。provider の利用上限に当たりやすくなるので、2 から試す | `1` |
| `parallel_exclusive_files` | 単独で実行するファイルの配列(ルート相対のパスで完全一致)。変更対象(参照ファイル欄で `(変更対象` が付いたパス)にこれらのファイルを1つでも含むタスクは、ほかのタスクが実行中のときは選ばれず、選ばれたときはほかのタスクと一緒に選ばれない。変更対象が1つも無いタスクも同じく単独になる。テンプレートの config.json には書かれていないので、変えたいときに足す | `["AGENTS.md", "README.md"]` |
| `comprehension_check.enabled` | タスク合格時に理解確認質問を生成するか | `false` |
| `comprehension_check.questions_per_task` | タスクあたりの質問数 | `3` |
| `task_sizing.max_acceptance_criteria` | 受け入れ基準のチェックボックス数のしきい値。`dispatch-prompt-gen` が、これを超えると WARN を出す。1以上の整数。値が無ければ既定値、不正値は WARN を出して既定値 | `5` |
| `task_sizing.max_changed_files` | 参照ファイル欄で `(変更対象` と書いた項目数のしきい値。`dispatch-prompt-gen` が、これを超えると WARN を出す。1以上の整数。値が無ければ既定値、不正値は WARN を出して既定値 | `3` |
| `task_sizing.max_reference_files` | 参照ファイル欄の項目数のしきい値。`dispatch-prompt-gen` が、これを超えると WARN を出す。1以上の整数。値が無ければ既定値、不正値は WARN を出して既定値 | `5` |
| `task_sizing.design_detail` | 計画時にどこまで設計を書くか。`skeleton`: 実装方法が複数ありうる箇所を計画時に決め、必要ならコードの骨格を目的欄に書く。`outline`: 方針と制約だけを書き、実装方法の選択を子に任せる(性能の高い子向け)。スクリプトは読まず、agent-task-plan が計画を書くときに使う。他の値は `skeleton` 扱い | `skeleton` |
| `quality_gate.steps` | 品質ゲートのステップ定義。各要素は `name`(表示名)・`command`(実行コマンド)・`blocking`(真なら不合格時に進行停止)を持つ。`command` は bash と pwsh の両方で動く書き方にする(quality-gate の節を参照) | `[{name:typecheck,...},{name:test,...},{name:lint,...}]` |
| `quality_gate.child_dispatch_command` | 子エージェントへの検証指示に使う統合コマンド。空文字列でなければ blocking ステップの個別列挙に代えてこの1コマンドを子に指示する。Gradle 等のデーモンの多重コールドスタート回避に有効。子にも同じ判定をさせる場合は `bash .agents/workflow/scripts/quality-gate.sh`(Windows の子は `pwsh -NoProfile -File .agents/workflow/scripts/quality-gate.ps1`)を指定できる | `""` |
| `upstream.url` | upstream(配布元)リポジトリの URL。`upstream-issue` が起票先に使う | `https://github.com/Musasaby/multi-ai-agents-workflow.git` |
| `base_branch` | 利用先の基準ブランチ(PR のマージ先)。`branch-check` が `main` に加えてこの名前のブランチもコミット禁止にし、`workflow-archive` が PR 未作成のブランチの比較先に使う。`dispatch-prompt-gen --pr` が PR の向き先と比較範囲(`origin/<base_branch>..HEAD`)に使い、`group-advance` が MERGED 後に切り替えて次のブランチを切る元に使う。値が無い・空なら `main` | `main` |
| `branch_prefixes` | `group-advance --branch` と `state-sync --set-branch` が受け付けるブランチ名の接頭辞の配列。無い・空の配列・不正な値なら既定。`develop` ブランチがあると git の仕様で `develop/...` を作れないため、既定に `develop-` を含む | `["develop/", "develop-"]` |
| `text_refine.skill` | 推敲に使う yomiyasu を呼ぶ名前(入れ方ごとに違う。プラグインなら `yomiyasu:yomiyasu`、skill 単体なら `yomiyasu` など)。`null`・空なら推敲しない。名前は推測せず、`text-refine` の `Found:` 行を見て利用者が決める | `null` |
| `text_refine.targets` | 推敲する場面。`summary`(完了サマリー報告)・`confirm`(ユーザーへの確認依頼)・`commit`(コミットメッセージの説明の1行)・`pr_body`(PR説明)・`task_done`(タスク1件の完了報告)・`tasks`(agent-task-plan で書く tasks.md)から選ぶ配列。既存の利用先は `"tasks"` を足すと有効になる | 6つすべて |
| `text_refine.reader` | 推敲後の文章の読み手。`expert`(同じ分野の専門家)・`informed`(分野は違うが技術に詳しい人)・`general`(専門知識のない人)。他の値は `informed` 扱い | `informed` |

**Windows での `command_template`**: `bash ./x.sh "{prompt}"` のように `bash` だけで書くと、`dispatch-run` が子を起動するときの
Windows のコマンド検索順で System32 の `bash.exe`(WSL)が Git Bash より先に選ばれ、Windows のパスが見えずに失敗することがある。
Git Bash を使うなら `"C:/Program Files/Git/usr/bin/bash.exe" ./x.sh "{prompt}"` のようにフルパスで書く。

### 子CLIのプロファイル

`child_agent.profile` は子CLIの種類を表すプロファイル名で、(1) `dispatch-run` が子の出力をどう扱うか
(`output_format`)と、(2) ログから何を検知するか(各 `*_pattern`)を決める。未指定・空は `auto`。

| プロファイル | 説明 |
|--------------|------|
| `auto` | 既定。`command_template` に `stream-json` を含めば `claude-stream-json` と同じ出力変換を行い、含まなければ `text`。検知は `opencode` と `claude-stream-json` の両方のパターンを使う(従来の挙動) |
| `opencode` | `opencode run`。テキスト出力のまま `output.log` に書く。ツール実行の ANSI 色付きマーカー行・`permission requested ... auto-rejecting` 等を検知する |
| `claude-stream-json` | Claude Code(`claude -p ... --output-format stream-json --verbose`)。JSON 行を `[tool_use]` / `[tool_result]` 等の行に変換する。`AGENTS.md` の `@` 参照(import)を子が解決できる |
| `plain` | 出力形式が不明な CLI。出力をそのまま書き、ログに依存する検知はすべて無効 |

**定義ファイル**: 組み込みは `.agents/workflow/scripts/child-profiles.json`。利用先で追加・上書きするときは
`.agents/workflow/child-profiles.json` を置く(組み込みと同じ形式のオブジェクト)。同名のプロファイルは
組み込みを項目単位でなく**丸ごと置き換える**(書かなかったキーは空・`false` になる)。未定義の名前を
`profile` に指定すると `dispatch-run` はエラー(`Unknown child profile`)で終了する。

**キー**:

| キー | 意味 |
|------|------|
| `output_format` | `text`(出力をそのまま `output.log` へ)・`claude-stream-json`(JSON 行を変換し、生の行を `output.jsonl` に残す)・`auto`(`command_template` に `stream-json` を含めば `claude-stream-json`、含まなければ `text`) |
| `tool_activity_pattern` | ツール実行の記録の行。**ANSI を除く前の生の行**に当てる。`dispatch-check` の完了報告の判定に使い、最後の `## 完了報告` の後にツール実行の記録が続けば報告を無効とし、最後のツール実行の後に出力が無ければその旨を理由に書く。空にすると「ツール実行の記録は無いもの」として扱う(`Disabled checks:` では `tool-activity`) |
| `tool_call_pattern` | ツール呼び出しの記録行。**生の行**に当てる。プロジェクト外アクセスの検出(`/tmp`・ホームディレクトリ等への参照)の対象行を、この記録行に絞るために使う(`Disabled checks:` では `outside-access`) |
| `permission_denied_pattern` | 権限拒否の行。**ANSI を除いた行**に当てる(`Disabled checks:` では `permission-denied`) |
| `provider_error_pattern` | プロバイダ側のエラー(利用上限・429 等)。`cli_log` の ERROR 行を**小文字にした行**に当てる(`Disabled checks:` では `provider-error`) |
| `agents_md_imports` | `true` なら、子が `AGENTS.md` の `@` 参照を解決できるとみなす(`false` では `AGENTS.md` が `@` 参照だけの場合に `dispatch-prompt-gen` が警告する)。`true`(真偽値)のみ有効 |

各 `*_pattern` に空文字列を指定するとその検査を無効にする。無効になった検査は `dispatch-check` が
`Disabled checks:` に列挙する。パターンは POSIX ERE と .NET の両方で同じ意味になる書き方
(`|`・`[...]`・`^`・`$`・`.`・`*`・`+`・`?`・`(...)` 程度。`\d` や先読みは避ける)にし、大文字小文字は区別する。
1行に収める(改行を含むとエラー)。

**利用先で新しい CLI を足す例**: `.agents/workflow/child-profiles.json` に定義し、`config.json` で指定する。

```json
{
  "mycli": {
    "description": "mycli(テキスト出力)",
    "output_format": "text",
    "tool_activity_pattern": "^\\[tool\\]",
    "tool_call_pattern": "^\\[tool\\]",
    "permission_denied_pattern": "",
    "provider_error_pattern": "rate limit|quota",
    "agents_md_imports": false
  }
}
```

```json
"child_agent": {
  "command_template": "mycli run \"{prompt}\"",
  "profile": "mycli"
}
```

**プロンプトの渡し方**: `command_template` の `{prompt}` はプロンプト本文に、`{prompt_file}` は
`prompt.md` の絶対パス(`/` 区切り)に展開される。どちらも無ければプロンプトを stdin で渡す
(それ以外は stdin を閉じる)。

**CLI ごとの `command_template` の例**:

- opencode: `opencode run "{prompt}"`(`profile` は `opencode` または未指定)
- Claude Code: `claude -p "{prompt}" --output-format stream-json --verbose` と `"profile": "claude-stream-json"`
- プロンプトが長い場合: `{prompt}` の代わりに `{prompt_file}` を使い、本文ではなくファイルの読み込みを指示する
  (例: `mycli run "Read {prompt_file} and follow it"`)。Windows ではコマンドライン長の上限(約32K文字)を
  超えうるため

**stream-json の逐次変換**: 出力形式が `claude-stream-json` のとき、`dispatch-run` は子CLIのstdoutを1行ずつ読み、
生のJSON行はそのまま `runs/<タスクID>-<試行回数>/output.jsonl` に追記し、パースできた行は人が読めるテキスト
(assistantのテキスト・使用ツール名と入力要約・`result` の要旨等)に変換して `output.log` へ逐次書き出す
(パース不能行はそのまま `output.log` に通す)。`output.log` は実行中に随時更新されるため
`tail -f` / `Get-Content -Wait` で閲覧できる。
`[tool_use]` 行の入力の要約は 300 文字で切り詰める。ツールが `Edit`・`Write`・`MultiEdit`・`NotebookEdit` のときは、
本文(`old_string`・`new_string`・`content`・`edits`・`new_source`)を外して `file_path` 等だけを載せる
(本文に書かれたパスの文字列をプロジェクト外アクセスと誤検知しないため。#87)。本文を含む全文は `output.jsonl` に残る。

**注意**: `--output-format text`(デフォルト)は子CLI側の出力がバッファリングされ、
プロセス終了までの実行中の逐次閲覧ができない。実行中の途中経過を見たい場合は
`stream-json` 形式を指定すること。出力形式が `text` の場合は従来どおり `output.log` への
直接リダイレクトのみで、`output.jsonl` は生成されない。

## tasks.md(/agent-task-plan が生成)

タスク定義の正本。子エージェントもこのファイルを参照する。フォーマット:

```markdown
# タスク一覧: <計画ソース(Issue #N またはドキュメントパス)>

## 要件                              ← 省略可(後方互換。書くと要件とタスクの対応を検査する)
- R1: <計画ソースから抜き出した要望>
- R2: <要望>

## 前提・解釈                         ← 省略可(親が置いた前提と解釈。機械的には読まない)
- <前提や解釈>

## 対象外                             ← 省略可(意図的に外したもの。機械的には読まない)
- <R2 など、外した要望とその理由>

<!-- グループ <名前>: <説明> -->        ← 省略可(グループ境界。`: <説明>` も省略可)

## T1: <タスクタイトル>
- **目的**: 何を達成するか
- **対象**: 変更が想定されるファイル・モジュール
- **グループ**: <名前>            ← 任意(所属を位置でなく名前で指定する)
- **要件**: R1, R3                ← `## 要件` 節があるとき必須(対応する要件が無ければ `なし`)
- **参照ファイル**:               ← 子が最初に読むファイル(`task_sizing.max_reference_files` 件以内。読ませるものが無ければ `なし`)
  - `path/to/file`(理由)
  - `path/to/other:10-40`(行範囲を付けられる)
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
- 参照ファイル欄のうち実際に変更するファイルは、理由を `(変更対象。…)` で始める
  (変更対象が多いと `dispatch-prompt-gen` が作業量の `WARN:` を出す判定に使う)
- 注記(例: `T30(Prometheus 基盤。完了済み)`)は書かない。前提タスクに関する補足は**目的欄**に
  書く。完了状態は state.json で機械的に判定するため書かない
- 形式違反・存在しないタスクID・自分自身への依存は `state-sync` / `next-task` /
  `dispatch-prompt-gen` がエラー(exit 1)にし、不正な値を stderr に出す(黙って捨てない)。
  循環依存は `state-sync` と `next-task` が検出する
- タスクの実行順は記述順・ID順ではなく依存関係で決まる(`next-task` が選ぶ)

**要件の節と要件欄**: 計画ソースの要望が、タスクのどれにも落ちずに漏れるのを防ぐ仕組み。

- `## 要件`: 計画ソースから抜き出した番号付きの要望。機械的に読むのはこの節だけで、
  `- R<n>: <本文>` の形式で書く
- `## 前提・解釈`: 親が置いた前提と解釈。`## 対象外`: 意図的に外したもの。この2節は人が読むための
  記録で、機械的には読まない
- `- **要件**:` 欄は `なし` かカンマ区切りの要件ID(`R1, R3`)。`## 要件` 節があれば全タスクに必須で、
  節が無ければ検査しない(後方互換)。節が無いのに欄を書くとエラーになる
- 検査される違反(`state-sync` がエラー(exit 1)にして stderr に内容を出す):
  - 要件行の形式違反
  - 重複した要件ID
  - 要件が0件の `## 要件` 節
  - 要件欄の欠落
  - `## 要件` 節に無い要件ID(形式違反の ID も含む)
  - どのタスクにも対応しない要件(意図的に外すなら `## 対象外` に移す)

グループ区切り行は `state-sync` / `next-task` / `dispatch-prompt-gen` / `group-advance` が
機械的にパースする。`<名前>` は空白と `:` を含まない文字列(大文字小文字を区別)。
区切りが無い領域のタスクは既定グループ(空の名前)に属する。既定グループは名前で参照
できないため `- **グループ**:` 欄での指定(空欄)は不可。

- 違反は `state-sync` / `next-task` がエラー(exit 1)にして stderr に内容を出す:
  空のグループ名・宣言されていないグループ名・**後のグループのタスクへの依存**
  (依存先は同じグループまたは前のグループのみ。これは各グループの PR が正常に閉じる
  ための前提になる)
- `- **グループ**:` 欄(任意)は所属グループを記述位置でなく名前で指定する(欄の名前が
  tasks.md の区切りで宣言済みの場合のみ位置より優先)。追加モードでの使い方は
  `agent-task-plan` skill を参照
- グループ境界(next-task の exit 6)は `agent-workflow` skill の
  「グループ単位の PR とブランチ切替」で PR 作成・ブランチ切替の機械的な単位として使われる
  (`config.json` の `branch_per_group` が `false` の場合はグループ解釈をしない)

## state.json(/agent-task-plan が `scripts/state-sync --init` で機械生成、各skillが更新)

機械可読な進捗状態。中断後の再開はこのファイルを起点にする。LLMは直接生成・編集しない。

`branch` は「現在の作業ブランチ」、`group` は「現在の作業グループ」を表す(tasks.md に
グループ区切りがある場合。区切りが無いサイクルでは既定グループの空文字列。config の
`branch_per_group: false` では `next-task` がこのフィールドを参照しない)。初期生成時(`state-sync --init`)では `branch` が git から、`group` が tasks.md の
グループ区切りから自動設定される(`branch` は workflow 開始時点の作業ブランチ、
`group` は未完了タスクを含む最初のグループ)。
グループ境界でのブランチ切替(`agent-workflow` skill の「グループ単位の PR とブランチ切替」)
では `group-advance` がこの2つのフィールドを更新するため、親が手で書き換える必要はない。
ワークフロー外の作業でブランチを手で切った場合は、`state-sync --set-branch` で `branch` を記録する。
既存の state.json に `group` キーが無い場合、`state-sync` の追記同期は後方互換のため
キーを追加せず、`next-task` は未完了タスクを含む最初のグループを作業グループとみなす。

```json
{
  "source": "Issue #12 | docs/plan.md",
  "branch": "develop/xxx",
  "group": "G1",
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
回復不能な失敗は `failed`(ユーザーへエスカレーション)。遷移はすべて `scripts/task-state` で行う(次節)。

## scripts/ 配下のスクリプト

いずれも `.agents/workflow/scripts/` にコピーして実行する(PowerShell版 `.ps1` / POSIX版 `.sh` の
2系統。挙動・exit codeは揃えてある)。生成・更新対象はすべて `.agents/workflow/` 配下。
PowerShell 版はすべて `exit` で終わるため、`pwsh -File` で起動しても、PowerShell セッション内で
`& .agents/workflow/scripts/<名前>.ps1` と直接呼んでも、`$LASTEXITCODE` で exit code を判定できる。

### Next: 行 — 次の行動の機械可読な指示

判定系スクリプト(`next-task`・`branch-check`・`group-advance`・`dispatch-start`・`dispatch-wait`・`dispatch-check`・`workflow-status`)は、stdout の
最後の行に `Next: <行動> [<タスクID>] [reason=<理由>]` を出す。親は exit code の表ではなく
この行に従う。`Next:` 行が無い(exit 1 等の使い方不備・入力不備)ときは `escalate reason=error`
として stderr をユーザーに報告する。

| 行動 | 意味 | 出すスクリプト |
|------|------|----------------|
| `dispatch <ID>` | そのタスクを dispatch する | next-task(exit 0) |
| `dispatch <ID> <ID>...` | 同時に実行できる複数のタスクを dispatch する(`max_parallel` が 2 以上のとき) | next-task(exit 0) |
| `wait <ID>...` | 実行中のタスクの完了を待つ(同時に始められるタスクが無い) | next-task(exit 5) |
| `collect <ID>` | worktree の run の変更を本体へ取り込む(`dispatch-worktree collect`)。その後 review する | dispatch-check(exit 0、worktree の run) |
| `review <ID>` | そのタスクをレビューする | next-task(exit 0、`in_review`)・dispatch-check(exit 0。PR 作成の run を除く) |
| `wait` | 子がまだ実行中。完了を待つ | dispatch-start(exit 0)・dispatch-wait(exit 2)・dispatch-check(exit 2)・workflow-status(実行中の run があるとき) |
| `finish` | 全タスク完了。サマリー報告へ | next-task(exit 3)・workflow-status |
| `group-advance` | グループ境界。group-advance を実行する | next-task(exit 6)・workflow-status |
| `create-pr` | PR を作成する | group-advance(exit 7)・workflow-status(PR が無いとき) |
| `wait-merge` | PR のマージを待つ(報告して停止) | group-advance(exit 8)・dispatch-check(exit 0、PR 作成の run `pr-*`。PR を検証してから報告する)・workflow-status(PR が `OPEN` のとき) |
| `update-pr` | 既存の PR に未 push のコミットを push し、本文を作り直す(PR作成の単発依頼を再実行する) | group-advance(exit 10) |
| `continue` | そのまま作業を続ける | branch-check(exit 0)・group-advance(exit 0)・task-commit(exit 0)・quality-gate(exit 0)・text-refine(推敲しないとき)・text-refine --check(exit 0) |
| `refine` | `Request:` の依頼文で yomiyasu に推敲させ、`Output:` のファイルを使う | text-refine(推敲するとき) |
| `decide-candidates` | 候補ごとの判断を `Decisions:` のファイルに書いてから `--check` を実行し直す | text-refine --check(exit 2) |
| `confirm` | `DECIDE` 行や差分をユーザーに確認する | workflow-setup(exit 3)・workflow-update(exit 3) |
| `switch-branch` | 専用ブランチを作る(`reason=main` / `merged`) | branch-check(exit 2 / 3) |
| `escalate` | ユーザーに理由を説明し判断を仰ぐ(text-refine --check の exit 3・4 を含む) | 下の reason 一覧 |

`escalate` の reason 一覧:

- `dirty-tree` / `task-status` / `healthcheck` / `warmup` / `prompt-gen` / `task-state` / `launch` — dispatch-start の失敗(exit 20 / 21 / 30 / 31 / 41〜43 / 50 / 60)
- `timeout` — dispatch-wait の exit 3(経過が `child_agent.timeout_seconds` を超えた)
- `blocked` — next-task の exit 4(実行可能なタスクが無い)
- `gh-unavailable` — branch-check の exit 4(gh で PR 状態を判定できない)
- `state-branch-mismatch` — branch-check の exit 5(state.json の `branch` と現在のブランチが不一致)
- `pr-closed` — group-advance の exit 9(PR が未マージのまま閉鎖)・workflow-status(PR が `CLOSED`)
- `tampered` — dispatch-check の exit 8(管理ファイルの改ざん・git 状態の変化)
- `provider-error` / `idle-timeout` / `abnormal-exit` — dispatch-check の exit 4(この順で判定)
- `permission-denied` / `outside-access` — dispatch-check の exit 6
- `token-limit` / `no-report` — dispatch-check の exit 5
- `no-changes` — dispatch-check の exit 7(変更が無いのが正しいタスクなら review に進んでよい)・task-commit の exit 20(コミットする変更が無い)
- `quality-gate` — quality-gate の exit 2(blocking のステップが失敗)
- `refine-unchecked` — text-refine --check の exit 3(推敲済みファイルか yomiyasu の記録が無く、確かめられない)
- `refine-structure-changed` — text-refine --check の exit 4(`tasks` の推敲前後で見出し・依存・要件ID 等の構造が変わった)
- `no-steps` — quality-gate の exit 3(実行するステップが0件)
- `not-npx` / `sync-failed` — workflow-update の exit 2 / 22(`npx skills` で導入されていない / 配置済みスクリプトとの差分確認の失敗)

### dispatch-prompt-gen — dispatchプロンプトの機械生成

tasks.md・config.json・依存タスクの完了報告(直接依存のみ)から、子エージェントに渡す
プロンプトを機械的に組み立てて `runs/<タスクID>-<試行回数>/prompt.md` に書き出す。
定型文(実装ルール・テスト検証指示・完了報告フォーマット)は `dispatch-prompt-template.md`
から展開する。

「テスト・検証」節には、常に「タスクの受け入れ基準に書かれた確認手順・テストコマンド」を
入れ、加えて config の検証コマンド(`quality_gate.child_dispatch_command`、または `command` が
空でない blocking ステップ、および `test_command`)を列挙する。`command` が空のステップは載せない。
同じコマンド(`test_command` と `child_dispatch_command` が同じ値など)は1回だけ載せる。
テンプレートはプロジェクトに依存しない内容だけを持つ。ビルドツール固有の注意などは、利用先の
`AGENTS.md` の「テスト・検証の注意(子エージェント向け)」節に書く(子への指示は AGENTS.md に従うよう求める)。

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
| `1` | 使い方・tasks.md/state.json 不備(タスクID未検出、tasks.md/state.json が無い、依存欄の形式違反・存在しないID・自己依存、参照ファイル欄のパスが存在しない・項目が無い 等) | 書き出さない |
| `2` | 引き継ぎガード失敗(依存タスクが `done` でない、または依存タスクの `report.md` が見つからない) | 書き出さない(既存の古い prompt.md があれば削除する) |
| `3` | リトライ(`-Attempt 2` 以上)なのに `fix-notes.md` が見つからない | 書き出さない |

exit 0 以外は dispatch を行わず、stderr の内容(exit 2 なら欠落内容の列挙)をそのまま
ユーザーに報告する。

exit 0 でも、次の場合は stderr に `WARN:` を出す(生成は続ける)。親は内容を確かめ、必要なら
tasks.md や AGENTS.md を直してから dispatch する:

- タスクに `- **参照ファイル**:` 欄が無い、または `task_sizing.max_reference_files`(既定 5)件を超えている
  (子が実装前に多くのファイルを読む原因になる)
- 受け入れ基準のチェックボックス(`- [ ]`)が `task_sizing.max_acceptance_criteria`(既定 5)件を超えている
  (子の1応答の処理量を超えて、推論だけで出力トークン上限に達する原因になる)
- 参照ファイル欄で `(変更対象` と書いた項目が `task_sizing.max_changed_files`(既定 3)件を超えている(同上)
- `task_sizing` のキーの値が1以上の整数でない(その旨と既定値を使うことを示す。生成は既定値で続ける)
- ルートの `AGENTS.md` が `@` 参照の行だけでできている(プロファイルの `agents_md_imports` が `false` の
  子CLI(opencode 等)は `@` を展開しないため、子にルールが届かない。`AGENTS.md` に実体を書き、
  `CLAUDE.md` 側を `@AGENTS.md` にする)。プロファイルの `agents_md_imports` が `true`
  (`claude-stream-json` 等)なら警告しない。警告文にはプロファイル名(`profile: <name>`)を含む

**PR モード**(`-Pr` / `--pr`): PR 作成を子に単発で依頼するプロンプトを
`dispatch-pr-prompt-template.md` から生成し、`runs/pr-<N>-1/prompt.md` に書き出す
(`<N>` は既存の `pr-*` の次の連番)。PR に含めるタスクは、state.json で `done` かつ
`commit` が `git log origin/<base_branch>..HEAD`(config.json の `base_branch`。無ければ `main`)に
含まれるものを自動で選ぶ(`origin` の `<base_branch>` を fetch してから比べるため、ローカルの
基準ブランチが古くても、マージ済みの無関係なコミットは混ざらない。
origin が無い・fetch に失敗した場合は exit 1)。stdout に `RunId: pr-<N>` を
出力するので、`dispatch-run` に `pr-<N>` と `1` を渡して起動する。作業ブランチではなく
`main` か `base_branch` の上で実行した場合や、対象タスクが無い場合は exit 1。
PR が既にある場合は、子が未 push のコミットを push し、PR の全コミットをもとに作り直した本文で
`gh api -X PATCH repos/{owner}/{repo}/pulls/<N> -F body=@<file>` により更新する
(`gh pr edit` は旧 Projects 廃止のエラーで失敗するため使わない)。
プロンプトには要件の一覧も入る。tasks.md の要件のうち、この PR のタスクを含むものだけを
`- R1: <本文>(この PR: T1 / 他の PR: T3)` の形で並べる。対応する要件が無い場合(要件の節が無い場合を含む)は
`- なし(...)` の1行になる。子はこの一覧を PR 本文に「要件と対応タスク」として載せる。

```powershell
.agents/workflow/scripts/dispatch-prompt-gen.ps1 -Pr
```
```bash
.agents/workflow/scripts/dispatch-prompt-gen.sh --pr
```
exit 0 の場合も生成されたプロンプト全文は会話に読み込まない
(読み込むと機械生成によるトークン節約が無意味になる)。

### dispatch-start — 事前チェックからデタッチ起動まで

子エージェントの起動までの事前チェックを順に行い、`dispatch-run` をデタッチ起動する。
失敗した段階で止める(止めたときは state.json を変えず、子も起動しない)。手順:

1. `branch-check --state`(非0なら stdout の `Next:` 行をそのまま流して止める)
2. 作業ツリーがクリーンか(試行回数 2 以上で `runs/<ID>-<N>/fix-notes.md` がある修正依頼では
   確認しない。前の試行の変更を引き継ぐため)
3. タスクの状態が `pending` / `in_progress` か
4. 疎通確認(`child_agent.healthcheck_command`。空なら省略)
5. ウォームアップ(`child_agent.warmup_command`。空なら省略。`guard.sha256` が1つも無い = サイクルの最初の dispatch のときだけ)
6. `dispatch-prompt-gen`
7. `task-state <ID> start`(状態を `in_progress` にする)
8. `dispatch-run` のデタッチ起動(`guard.sha256` が現れるまで最大30秒待つ。環境変数
   `DISPATCH_START_LAUNCH_TIMEOUT` で変更可)

`isolate_xdg` が true のとき、疎通確認・ウォームアップも `XDG_CONFIG_HOME` / `XDG_DATA_HOME` を
`.agents/workflow/.config` にして実行する。

```powershell
.agents/workflow/scripts/dispatch-start.ps1 -TaskId T1 [-Attempt 1]
.agents/workflow/scripts/dispatch-start.ps1 -Pr
```
```bash
.agents/workflow/scripts/dispatch-start.sh T1 [1]
.agents/workflow/scripts/dispatch-start.sh --pr
```

**並列実行(`max_parallel` が 2 以上、`--pr` でないとき)**: 手順2(作業ツリーの確認)は行わない。
手順3の後に `dispatch-worktree create` で worktree の run にする(手順4以降はその WT を使う run になる)。
成功時の stdout には `Carried:` 行(前の試行の変更の持ち越し結果)と `Worktree: <パス>` 行を、
`Next: wait` の前に出す。
worktree を作った後、子の起動前の手順(疎通確認・ウォームアップ・prompt 生成・`task-state`)で失敗したときは、
`dispatch-worktree abort` で worktree・ブランチを消し、持ち越しで取り除いた前の試行の変更を本体に戻してから止める。
`dispatch-run` の起動を確認できない exit 60 では abort しない(子が動いている可能性があるため)。

`--pr` / `-Pr` は PR 作成の run(`pr-<N>-1`)を起動する。手順3・5・7は行わず、手順6は
`dispatch-prompt-gen --pr` になる(stdout の `RunId` で起動する)。

**exit code 規約**:

| exit | 意味 |
|------|------|
| `0` | 起動した |
| `1` | 使い方不備 |
| `11`〜`15` | `branch-check --state` の exit 1〜5(stdout の `Next:` 行はそのまま流す) |
| `20` | 作業ツリーが汚れている(リトライで fix-notes.md がある場合を除く。`reason=dirty-tree`) |
| `21` | タスクの状態が不正(`pending` / `in_progress` 以外、タスク無しを含む。`reason=task-status`) |
| `30` / `31` | 疎通確認 / ウォームアップの失敗(`reason=healthcheck` / `warmup`。出力の末尾20行を stderr に出す) |
| `41`〜`43` | `dispatch-prompt-gen` の exit 1〜3(`reason=prompt-gen`。依存未完了・report.md の欠落は 42。`--pr` で RunId が取れない場合は 41) |
| `22` | `max_parallel` が 2 以上で、worktree の作成が dirty-tree(`dispatch-worktree` の exit 20。`reason=dirty-tree`) |
| `50` | `task-state` の失敗(`reason=task-state`) |
| `61` | `max_parallel` が 2 以上で、worktree の作成に失敗(`dispatch-worktree` の exit 20 以外。`reason=worktree`) |
| `60` | `dispatch-run` の起動を確認できない(`reason=launch`。state.json は `in_progress` のまま) |

`healthcheck_command` / `warmup_command` は sh 版では `bash -c`、ps1 版では `pwsh -Command` で実行する。

stdout は成功時に `Run: <ID>-<N>`・`Log: <output.log のパス>`・`Watch:`(sh 版は `tail -f <パス>`、
ps1 版は `Get-Content <パス> -Wait -Tail 20`)・`Watch all:`(全 run のログをまとめて流す `workflow-logs` のコマンド。
sh 版は `bash .agents/workflow/scripts/workflow-logs.sh`、ps1 版は `pwsh -NoProfile -File .agents/workflow/scripts/workflow-logs.ps1`)・`Next: wait` を出す。失敗時は最後の行に `Next: escalate reason=<理由>` を出す(使い方不備の exit 1 を除く)。

### dispatch-run — 子エージェントCLIのデタッチ実行

`runs/<タスクID>-<試行回数>/prompt.md` を読み込み、子エージェントCLI(config.json の
`child_agent.command_template`)を実行する。stdout/stderr を
`runs/<タスクID>-<試行回数>/output.log` に、終了後に exit code と終了時刻を
`runs/<タスクID>-<試行回数>/done`(`EXIT:` / `END:` の2行)に書き出す。

**プロンプトの渡し方**: テンプレートに `{prompt}` があれば prompt.md の本文に、`{prompt_file}` があれば
prompt.md の絶対パス(`/` 区切り)に置き換える。どちらも無いときだけ、プロンプトを stdin で
渡す(UTF-8 のバイト列。改行は変換しない)。どちらかがあるときは stdin を閉じて実行する。

**出力の変換**: 子CLIの出力形式は、プロファイル(`child_agent.profile`、`.agents/workflow/child-profiles.json`
での上書きを含む)の `output_format` で決まる。`claude-stream-json` なら JSON 行を変換し、`text` なら
そのまま `output.log` に書く。プロファイルを解決できない(未知の名前・`child-profiles.json` の不正等)ときは、
子を起動せず `output.log` に `Child profile error: <メッセージ>` を書き、`done` の `EXIT:` を `1` にして終える。

`EXIT:` の値は、数値(子CLIの exit code)・`signal:<番号>`(子がシグナルで強制終了された。
POSIX 版のみ)・`crashed:<メッセージ>`(ラッパー自体の異常終了。PowerShell 版)のいずれか。
POSIX 版は、Python 経由の起動では子の負の returncode を、bash で直接起動するフォールバック
経路では 128 より大きい終了コードをシグナル終了とみなし、`signal:15` のように記録する
(従来は SIGTERM が `EXIT:241` と記録され、通常の終了と区別できなかった)。
Windows にはシグナルの仕組みが無いため、PowerShell 版での強制終了は通常の非0終了として記録される。
親プロセスのタイムアウト・終了に巻き込まれないよう `Start-Process` / `nohup` 等で
デタッチ起動する。

子の無応答タイムアウトもある。config.json の `child_agent.idle_timeout_seconds`(秒)を設定すると、
`dispatch-run` は1秒ごとに `output.log` の最終更新時刻を見て、指定時間更新されなければ
`runs/<タスクID>-<試行回数>/idle-timeout`(中身は秒数)を書き出し、子をプロセスツリーごと止める。
このとき `done` の `EXIT` は `idle-timeout` になる(シグナル死の記録より優先)。

子の一時ファイルの置き場所も `dispatch-run` が設定する: 子プロセスには `TMPDIR`・`TEMP`・`TMP`
を `runs/<タスクID>-<試行回数>/tmp/`(起動時に作成する)に設定するため、子が `mktemp` 等で作る
一時ファイルはプロジェクト内の `tmp/` に置かれる。`GIT_CEILING_DIRECTORIES` には `tmp/` の親である
`runs/<タスクID>-<試行回数>/` を設定する(`tmp/` そのものではない)。git は ceiling と同じ
ディレクトリが cwd のときも探索を止めないため、その下の `tmp/` で実行された `git` が本物の
リポジトリを探索でたどり着かないようにする。PowerShell 版は
呼び出し元の `TEMP` 系環境変数の元の値を保存しておき、ラッパーの終了時(finally)に元に戻す。

**worktree の run**: `runs/<ID>-<N>/worktree.txt` があるとき、子は本体ではなく WT(`path` の行)を作業
ディレクトリにして実行する。`TMPDIR`・`TEMP`・`TMP` は WT の中の
`.agents/workflow/runs/<ID>-<N>/tmp/`(`dispatch-worktree create` が作る)に設定し、`GIT_CEILING_DIRECTORIES` も
WT 側にする。`guard.sha256` の対象のうち `state.json`・`tasks.md` は、子が触れる WT 側のコピー
(`runs/<ID>-<N>/worktree/.agents/workflow/` の下)にする(`prompt.md`・`config.json`・`child-profiles.json` は本体のまま)。
`git-state.txt` は WT の中で `git-state --run <branch> --parent <親の作業ブランチ>` を実行した値を記録する。`output.log`・`done` などの
記録は本体の `runs/<ID>-<N>/` に書く。

起動時の git 状態(HEAD・ブランチ・参照・config の SHA-256。「git-state」節の4行)を
`runs/<タスクID>-<試行回数>/git-state.txt` に記録する(失敗しても起動は止めない)。
dispatch-check が実行後の状態と比べるため、子がコミットや設定変更でリポジトリのどこを変えたかを
機械的に特定できる。

```powershell
Start-Process pwsh -ArgumentList "-NoProfile -File .agents/workflow/scripts/dispatch-run.ps1 -TaskId T1 -Attempt 1"
```
```bash
nohup .agents/workflow/scripts/dispatch-run.sh T1 1 > /dev/null 2>&1 &
```

### dispatch-check — 完了検知後の終了状態・成果物の判定

`done` マーカーを検知したら毎回実行する。終了状態の区分(`ok` / `nonzero` / `idle-timeout` /
`signal` / `crashed`)、使ったプロファイル名(`Profile:`)、パターンが空で無効な検査(`Disabled checks:`。
無ければ `none`)、管理ファイルの改ざん検知(`Guard:`)、権限拒否の有無(`Permission denied:`)、
プロジェクト外アクセスの検出(`Outside access:`)、子CLI自身のログのエラー(`CLI log:` と
`Provider error:`)、完了報告の判定(`Completion report:`)、変更件数(`Changes:`)、
`git status --porcelain`、`git diff --stat`、`output.log` の末尾30行をまとめて出力する。

- **改ざん検知**: `dispatch-run` は起動時に `prompt.md`・`state.json`・`tasks.md`・`config.json`・
  `.agents/workflow/child-profiles.json` の
  SHA-256 を `runs/<タスクID>-<試行回数>/guard.sha256` に記録する。`dispatch-check` はこれと
  現在の内容を比べ、変更・削除を検知する。`guard.sha256`・`output.log`・`git-state.txt` が無い場合や、
  `output.log` に NUL バイトがある(実行中に空にされた)場合も改ざんとみなす。
  `git-state.txt not found` は、この版より前の `dispatch-run`(起動時に `git-state.txt` を記録しない版)
  で起動した run を更新後の `dispatch-check` で判定した場合にも記録される。その場合は run を
  やり直す(再 dispatch)
- **git 状態の比較**: `dispatch-check` は `git-state.txt`(dispatch-run が起動時に記録)と現在の
  `git-state` の出力を比べ、`head`・`branch`・`refs`・`config` のいずれかが変わっていれば
  `git changed: <名前>` を改ざん検知の問題に加える(例: 子が `git commit` や `git config` で
  リポジトリの git 状態を変えた場合)。PR 作成の run(`pr-*`)だけは `config` を比べない
  (子が `git push -u` で `.git/config` を正当に変えるため)
- **プロファイルのパターンによる判定**: 検知はプロファイル(`Profile:` に出る名前)のパターンで行う。
  プロジェクト外アクセスは `tool_call_pattern`、完了報告の無効判定(ツール実行の記録)は
  `tool_activity_pattern`、権限拒否は `permission_denied_pattern`、プロバイダーエラーは
  `provider_error_pattern`。パターンが空の検査は行わず、出力は `disabled (profile: <name>)` になる
  (`Permission denied:`・`Outside access:`・`Provider error:`)。無効な検査は検出なしとして扱い、
  Verdict・exit code は変わらない(`Disabled checks:` に検査名 `permission-denied`・`outside-access`・
  `tool-activity`・`provider-error` を出す)。プロファイルを解決できない(未知の名前・
  `child-profiles.json` の不正等)ときは、原因を stderr に出して exit 1 で終わる(`Next:` 行は出さない)。
  以下の opencode のマーカー行や stream-json の行は、`auto` / `opencode` / `claude-stream-json` の
  組み込みパターンの例である
- **プロジェクト外アクセス**: `Outside access: yes` と一致した行を出す。対象はツール実行の記録行
  (`tool_call_pattern` に一致する行。組み込みの例: opencode の色付きマーカー行 `$` / `→` / `←` / `✱` / `✗` / `⚙`
  で始まるものと stream-json の `[tool_use]` 行。`!` で始まる権限拒否の行は除く)
  だけで、ツールの出力(色なしの行・`[tool_result]` 行)や完了報告の本文には反応しない。
  ANSI エスケープを除いた行に対して判定する。検出条件は次の3つ:
  1) `/tmp`・`/var/tmp` の参照、2) ホームディレクトリの参照(`~/`・`$HOME`・`${HOME}`・
  `$env:HOME`・`$env:USERPROFILE`・`%USERPROFILE%`)、3) Windows のユーザー一時ディレクトリの参照
  (`AppData\Local\Temp`・`AppData/Local/Temp`)。2 と 3 は大文字小文字を区別しない。`$env:TEMP`・`%TEMP%`・
  `$TMPDIR` は `dispatch-run` がプロジェクト内の `tmp/` を指させるため検出しない。
  stream-json の `[tool_use]` 行には Edit・Write 等の本文が載らないため、ファイル本文中の `~/` 等には反応しない
  (上記「stream-json の逐次変換」を参照)
- **完了報告の保存**: ok(exit 0)と no-changes(exit 7)のとき、最後の完了報告のブロックを
  `runs/<ID>-<N>/report.md` に保存する(既存は上書きしない)。出力の `Report:` 行にパスを出す
- **完了報告**: `output.log` で**最後に出現する** `## 完了報告` 行だけを対象にする。
  その後にツール実行の記録(`tool_activity_pattern` に一致する行。組み込みの例: opencode が色付きで出す
  マーカー行 = ANSI エスケープに挟まれた `$ ` / `→ ` / `← ` / `✱ ` / `✗ ` / `⚙ ` / `! `、stream-json の
  `[tool_use]` / `[tool_result]` 行)が
  続く場合は無効(報告本文の色なしの `→ 要確認` や `$ npm test` はツール実行とみなさない)。必須項目は通常のタスクが
  `- 変更ファイル:` と `- テスト結果:`、PR 作成の run(`pr-*`)が `- PR URL:`。項目名の後の区切りは
  半角 `:` と全角 `：` のどちらでもよい(#55)。値が空・
  `<...>` のまま(テンプレート)の場合も無効。報告が無い場合は `missing` で、最後のツール実行の
  記録より後に子が何も出力せず終わった場合は
  `missing (no output after the last tool call; the model may have hit the output token limit)` になる
  (#50: 推論だけで出力トークン上限に達した打ち切り。opencode はエラーにせず exit 0 で終わるため、
  区分は `ok` でも完了報告は欠けている)
- **子CLI自身のログのエラー**: config.json の `child_agent.cli_log`(子CLI自身のログファイルのパス。
  先頭の `~/` はホームディレクトリで展開する)を読む。`CLI log:` には設定したパスを出し、
  未設定なら `(not configured)`、パスのファイルが無ければ `<パス> (not found)`。次にそのログの
  末尾200行のうち `ERROR` を含む行の最後の5行を字下げして出す。`Provider error:` はプロバイダー起因の
  失敗かどうか(`yes` / `no` / `unknown`)で、5行のいずれかが `provider_error_pattern` に一致すれば `yes`、
  一致しなければ `no`、`cli_log` が未設定・ファイルが無ければ `unknown`。`provider_error_pattern` が空なら
  `cli_log` の有無にかかわらず `disabled (profile: <name>)`(組み込みの例: `usage limit`・`rate limit`・
  `endpoint is unavailable`・429(前後に英数字を続けない。`.429Z` のようなタイムスタンプ等に
  一致させないため))。
  利用上限・レート制限・エンドポイント障害の切り分け用の参考情報で、Verdict・exit code には影響しない
- **権限拒否**: `permission_denied_pattern` に一致する行があれば権限拒否とみなす
  (組み込みの例: opencode の拒否の記録 = 行頭が `! permission requested:` で `auto-rejecting` を含む行。
  子が表示したソース中の同じ文字列には反応しない)
- Windows PowerShell 5.1 が UTF-16LE で書いた `output.log` も BOM を見て読む(PowerShell 版)

```powershell
.agents/workflow/scripts/dispatch-check.ps1 -TaskId T1 -Attempt 1
```
```bash
.agents/workflow/scripts/dispatch-check.sh T1 1
```

exit code(複数に当たる場合は上の行を優先する):

| exit | Verdict | 意味 |
|------|---------|------|
| `8` | `tampered` | 管理ファイルの改ざん・git 状態の変化(上記の `Guard:`。`git changed: <名前>` を含む) |
| `4` | `abnormal-exit` | 異常終了(非0・`idle-timeout`(子が `child_agent.idle_timeout_seconds` の間無応答で `dispatch-run` が止めた。上述の通りシグナル死の記録より優先される)・`signal:*`・`crashed:*`) |
| `6` | `permission-denied` / `outside-access` | 権限拒否で中断(`Permission denied: yes`)、またはプロジェクト外アクセスの検出(`Outside access: yes`) |
| `5` | `no-report` | 完了報告が無い・無効 |
| `7` | `no-changes` | 完了報告はあるが作業ツリーに変更が無い(`pr-*` の run では判定しない) |
| `0` | `ok` | 正常終了かつ完了報告あり |
| `2` | — | done マーカーが無い(まだ実行中) |
| `1` | — | 使い方不備、またはプロファイルを解決できない(stderr に原因を出す) |

この版から、done マーカーが無いときは exit 1 ではなく exit 2 を返す(#69)。

**worktree の run**: run のディレクトリに `worktree.txt` があるとき、次が変わる。
- `git-state` の比較は、`worktree.txt` の `path` の WT の中で `git-state --run <branch> --parent <親の作業ブランチ>` を
  実行した値と `git-state.txt` を比べる(ほかの run のブランチと親の作業ブランチの変化は検知しない。
  共有の参照のタグ等を子が作れば検知する)
- `Changes:`・`git status --porcelain`・`git diff --stat` は WT の中で取る
- WT のディレクトリが無いときは `Guard:` に `worktree not found: <path>` を加え(Verdict は `tampered`)、
  git 状態の比較は行わず、`Changes:` は本体で取る
- `Guard:` の管理ファイルの検知は、`state.json`・`tasks.md` を WT 側のコピーに加えて本体の `tasks.md` でも行う。
  本体の `state.json` は親が並列中に更新するため丸ごとは比べず、`dispatch-run` が起動時に
  `state-entry.txt` に記録した自分のタスクの欄だけを比べる(`state-entry.txt` が無いのも改ざんとみなす)
- Verdict が `ok` のときの `Next:` は `collect <ID>`(`dispatch-worktree collect` で本体へ集める)

`0` 以外の場合はレビューに進まず、出力された内容をユーザーに報告する(`7` は、変更が無いのが
正しいタスクに限り検証に進んでよい。詳細は `agent-dispatch` skill §2)。

### dispatch-wait — 子の完了待ち

run の完了をポーリングで待つ。1回の呼び出しで `--max-wait` 秒まで待ち、`done` マーカーが
あれば `dispatch-check` に判定を任せてその結果をそのまま返す。

```powershell
.agents/workflow/scripts/dispatch-wait.ps1 -TaskId T1 [-Attempt 1] [-MaxWait 480] [-Interval 15]
```
```bash
.agents/workflow/scripts/dispatch-wait.sh T1 [1] [--max-wait 480] [--interval 15]
```

- `--max-wait`: 1回の呼び出しで待つ上限(秒、既定 480。親ツールのコマンド実行上限に合わせる)
- `--interval`: ポーリング間隔(秒、既定 15)
- 経過秒数の開始時刻は、`dispatch-run` が起動時に作る `guard.sha256` の更新時刻。
  `guard.sha256` が無い(dispatch-run で起動されていない)run は待てず exit 1
- exit 2 / 3 のとき、stdout に状況行(`Run:`・`Status: running`・`Elapsed:`・`Log idle:`・`Log:`)を出す

| exit | 意味 |
|------|------|
| `0` / `4`〜`8` | `done` があった。`dispatch-check` の結果のまま(上の表) |
| `1` | 使い方不備、または run が起動されていない |
| `2` | まだ実行中(この呼び出しの待ちが `--max-wait` に達した)。最後の行は `Next: wait`。再度呼んで待ちを続ける |
| `3` | 経過が `child_agent.timeout_seconds` を超えた。最後の行は `Next: escalate reason=timeout` |

### dispatch-worktree — 子エージェントの run 用 git worktree の作成・回収・削除

`max_parallel` が 2 以上のとき、`dispatch-start` が呼ぶ。run ごとに git worktree を作り、
子はその中で作業する。`RUN=.agents/workflow/runs/<ID>-<N>`、`WT=$RUN/worktree`、
ブランチは `agents-run/<ID>-<N>`。

```powershell
.agents/workflow/scripts/dispatch-worktree.ps1 -Action <create|collect|remove|abort> -TaskId T1 -Attempt 1
```
```bash
.agents/workflow/scripts/dispatch-worktree.sh <create|collect|remove|abort> T1 1
```

- `create`: WT を HEAD から作る。試行回数が 2 以上で、前の試行に `collected`(collect が成功した印)があれば、
  前の試行の変更(`changes.patch`)を本体から取り除き(取り除いたら `$RUN/reverted` に前のパッチのパスを書く)、
  新しい WT に 3way で持ち越す。`collected` が無い前の試行(collect が衝突・失敗して取り込まれなかった)の変更は
  本体に無いので持ち越さない。stdout に `Carried: <パッチ>` / `Carried: none` /
  `Carried: none (not collected: <前のパッチのパス>)` のどれかと、`Worktree: <パス>`、`Branch: <名前>` を出す。
  持ち越しが衝突したら exit 40 で、WT・ブランチを残さず、取り除いた変更を本体に戻す
- `collect`: WT の変更(未追跡・WT でコミットした変更を含む。`.agents/workflow` は除く)の、`worktree.txt` の
  `base` との差分を `$RUN/changes.patch` にして本体へ `git apply` し、空の `$RUN/collected` を作って
  WT・ブランチ・`worktree.txt` を消す(`base` の行が無ければ `HEAD` との差分)。tasks.md の `changed` に無い
  ファイルは `Undeclared: <path>`(無ければ `Undeclared: none`)で出す。成功時は `Applied: <N> files`・
  `Patch: <パス>`・`Next: review <ID>`。WT の中の git(`git add` 等)が失敗したときは exit 30 で、
  WT・ブランチ・`worktree.txt` を残す(原因を直して collect し直せる)
- `remove`: WT・ブランチ・`worktree.txt` を消す(無くてもエラーにしない)
- `abort`: `remove` と同じく消したうえで、`$RUN/reverted` があれば、そこに書かれた前のパッチを本体に
  `git apply` で当て直して `reverted` を消す(`create` で取り除いた前の試行の変更を戻す)。
  当て直せなければ stderr にパッチのパスを出して exit 20。`dispatch-start` が起動前の失敗で呼ぶ

**Windows でのパスの長さ**: WT は `.agents/workflow/runs/<ID>-<N>/worktree/` に作るので、WT 内のパスは
本体より約35文字長くなる。`dispatch-worktree` は WT に対する git の操作に `core.longpaths` を付けて作るが、
子の CLI やツールが長いパスを扱えないことがある。プロジェクトは短いパスに置く(例: `C:\work\proj`)。

`worktree.txt` は `$RUN/` に書く3行(`dispatch-run` と `dispatch-check` が読む):

```
path <WT の絶対パス>
branch refs/heads/agents-run/<ID>-<N>
base <作成時の HEAD>
```

| exit | 意味 |
|------|------|
| `0` | 成功 |
| `1` | 使い方不備 |
| `20` | `reason=dirty-tree`。`create` では前の試行の変更を本体から取り除けない、`collect` では本体の作業ツリーが clean でない、`abort` では `reverted` のパッチを本体に当て直せない |
| `30` | `reason=worktree`。WT が既にある・作成に失敗した。`collect` では `worktree.txt` または WT のディレクトリが無い、WT の中の git が失敗した(WT は残る) |
| `40` | `reason=conflict`。`collect` で `changes.patch` を本体に当てられない、`create` で前の試行の持ち越しが衝突した |

使い方不備の exit 1 を除き、stdout の最後の行に `Next:`(`continue` / `review <ID>` /
`escalate reason=<理由>`)を出す。

### workflow-logs — 複数の run のログを1つの画面に流す

`tail -f` の複数 run 版。実行中の子エージェント run の `output.log` を1つの画面にまとめて流す。
何も書き換えない。sh 版は python3 が必要(ps1 版は不要)。

```powershell
.agents/workflow/scripts/workflow-logs.ps1 [-Run <ID>-<N>[,...]] [-Tail 20] [-Interval 1] [-Duration <秒>] [-Once]
```
```bash
.agents/workflow/scripts/workflow-logs.sh [--run <ID>-<N>]... [--tail 20] [--interval 1] [--duration <秒>] [--once]
```

- `--run`: 指定した名前の run だけを追う(複数指定可。ps1 版は `-Run` にカンマ区切りで渡す。形式は `^[A-Za-z0-9_-]+-[0-9]+$`)。
  ディレクトリがまだ無ければ現れるまで待つ
- `--tail`: run を初めて見つけたとき、`output.log` の末尾から出す行数(既定 20)
- `--interval`: run の探し直しとログ確認の間隔(秒、既定 1。0 より大きい数だけ。0・0.0 は使い方の誤りで exit 1)
- `--duration`: 指定した秒数で終了する
- `--once`: 対象の run の末尾を出して終了する
- 対象の run: `--run` があればその名前の run。無ければ `.agents/workflow/runs/*/` のうち
  `guard.sha256` があり `done` が無いもの(`--interval` ごとに探し直し、新しい run を加える)。
  1回起動すれば、以後に dispatch した run のログもまとめて流れる。
  `output.log`(無ければ `guard.sha256`)の最終更新が `child_agent.timeout_seconds` 秒
  (`.agents/workflow/config.json`。読めない・正の整数でなければ 1800)より前の run は、
  止まった run(kill・クラッシュで `done` が無い)として新たには追わない。追跡中の run と `--run` 指定の run には当てない
- 文字コード: `output.log` の先頭が BOM `FF FE` なら UTF-16LE(Windows PowerShell 5.1 の `*>`)として、
  `EF BB BF` なら UTF-8 の BOM を除いて読む。それ以外は UTF-8。2バイト単位に満たない端数は次の読み込みに回す。
  出力は BOM なしの UTF-8。`.ps1` 版は、出力が端末のときだけ出力コードページ(`[Console]::OutputEncoding`)を
  UTF-8 に切り替えて終了時に戻す(日本語環境の 932 での文字化けを防ぐ)。リダイレクトされているときは切り替えない
- 出力: 各行の先頭に `[<run>] ` を付ける。出力が端末へ向いていて環境変数 `NO_COLOR` が空か未設定なら、
  接頭辞に run ごとに違う色(ANSI 31〜36)を付ける(`NO_COLOR` は値が空でないときだけ色を止める)。
  初回は末尾の `--tail` 行、以後は追記された完成した行だけ。
  `output.log` が短くなったら先頭から読み直し `[<run>] --- log truncated` を出す。
  `done` が現れたら残りの行(末尾の改行の無い行を含む)と `[<run>] --- finished (<EXIT の値>)` を出し、
  その run の追跡をやめる(`EXIT:` 行がまだ無ければ 0.1 秒おきに最大 10 回読み直す)。開始時に stderr へ `Watching: ...` を出す
- 終わり方: `--once` は末尾を出して終了 / `--duration` は指定秒数で終了 /
  `--run` 指定時は指定した run がすべて終わったら終了 / それ以外は Ctrl+C まで続ける。
  どちらの版も Ctrl+C は exit 0 で終わる(sh 版は traceback を出さない。ps1 版は入力がリダイレクトされていなければ
  Ctrl+C を自分で受け取り、待ちの間に見つけて終わる)

| exit | 意味 |
|------|------|
| `0` | 正常に終わった(Ctrl+C を含む) |
| `1` | 使い方不備(未知の引数・値の無いオプション・形式不正・数値でない値・0 以下の `--interval`)、または python3 が無い(sh 版) |

### git-state — git 状態の4行出力

カレントディレクトリのリポジトリの git 状態を、この順に4行で出力する(何も書き換えない)。
項目の取得に失敗した値は `-` にする。git リポジトリの中でなければ stderr に
`not a git repository` を出して exit 1:

```
head <HEAD コミットの SHA-1(git rev-parse --verify -q HEAD)>
branch <HEAD の参照名(git symbolic-ref -q HEAD。例: refs/heads/main)>
refs <参照一覧の SHA-256(16進小文字): git for-each-ref の refs/heads・refs/tags・refs/stash の出力>
config <git config ファイルの SHA-256(16進小文字)>
```

`refs` は push で正当に変わる `refs/remotes` を含めない。

`--ref <refname>`(ps1 は `-Ref <refname>`)を付けると、`refs` 行はその参照だけの
`git for-each-ref` の出力の SHA-256 になる(参照が無ければ空の出力のハッシュ)。worktree の run が
自分のブランチだけを見て、並列の他の run が作るブランチや参照の変化を改ざんと誤検知しないために使う。
`--run <refname> --parent <refname>`(ps1 は `-Run`・`-Parent`)を付けると、`refs` 行は既定の参照一覧から
次の行を除いたものの SHA-256 になる: 参照名が `refs/heads/agents-run/` で始まり `--run` の値と一致しない行
(ほかの run のブランチ)、`--parent` の値と一致する行(親の作業ブランチ。`-` か空なら除かない)。
worktree の run が、並列の他の run や親のコミットを改ざんと誤検知せず、タグなど共有の参照の変化は検知するために使う。
`--run` と `--parent` は両方そろって使い、`--ref` とは併用できない。
未知の引数・値の無いオプション・上の組み合わせの誤りは stderr に
`Usage: git-state.sh [--ref <refname> | --run <refname> --parent <refname>]` を出して exit 1。
`dispatch-run` が子の起動時にこの出力を `git-state.txt` に記録し、`dispatch-check` が実行後の
出力と比べて、子がリポジトリのどこを変えたか(HEAD・ブランチ・参照・設定)を特定する。

```powershell
.agents/workflow/scripts/git-state.ps1
```
```bash
.agents/workflow/scripts/git-state.sh
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
- **追記同期**(タスクの途中追加時。既存タスクの `status`/`retries`/`commit` には触れない。
  既存タスクの見出し(タイトル)を修正した場合は、tasks.md に合わせて state.json の `title`
  も更新し、変更があったタスクごとに `Updated title: <ID>` を stdout に出力する):
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
- **ブランチの記録**(`--set-branch [<名前>]` / `-SetBranch [-Branch <名前>]`。ワークフロー外の作業で
  新しいブランチに移ったときに使う。tasks.md は読まず、state.json の `branch` と `updated_at` だけを更新する):
  ```powershell
  .agents/workflow/scripts/state-sync.ps1 -SetBranch
  ```
  ```bash
  .agents/workflow/scripts/state-sync.sh --set-branch
  ```
  名前を省略すると現在のブランチを記録する。config.json の `branch_prefixes`(既定 `develop/`・`develop-`)のどれでも始まらない名前と、
  名前を省略した detached HEAD は拒否する(exit 1)。すでに同じ値なら `Branch unchanged: <名前>` を出して何もしない。

どのモードでも、state.json を書く前に全タスクの依存欄を検証する(形式違反・存在しないID・
自己依存・循環依存・依存行の欠落)。あわせて要件の節と要件欄も検証する(検査内容は
「tasks.md」節の「要件の節と要件欄」を参照。`## 要件` 節が無ければ検査しない)。
不正があれば何も書き込まずに exit 1 で終了する。

要件の検査が通り `## 要件` 節があるときは、state.json を書いた後に、要件とタスクの対応表を
stdout に出す(承認時の対応表に使う)。要件の記述順に `Requirement R1: T1, T3` の行を出し、
要件欄が `なし` のタスクがあれば最後に `Requirement なし: T5` の行を出す。節も欄も無い
tasks.md では出さない。

exit code: `0`=成功、`1`=使い方不備・検証エラー(tasks.md/state.json 不在、`--init` 時の
`--source` 欠落や state.json 既存、依存欄の不正、挿入先が `pending` でない 等)。

### req-status — 要件ごとの充足状況の一覧

tasks.md の要件とタスクの対応を state.json の状態と突き合わせ、要件ごとの充足状況を一覧する
(読み取り専用。tasks.md・state.json は変更しない)。グループ・サイクルの完了時に、要件が
満たされたかを親が確認するために使う。引数は取らない。

```powershell
.agents/workflow/scripts/req-status.ps1
```
```bash
.agents/workflow/scripts/req-status.sh
```

出力形式:

```
Requirement R1 [<状態>]: T1(done abc1234), T2(pending) | <要件の本文>
Requirement なし: T5(done def5678)
Summary: done=<n> partial=<n> pending=<n>
```

- 要件の記述順に `Requirement R1 [<状態>]: ... | <本文>` の行を出す。要件欄が `なし` のタスクがあれば
  `Requirement なし: ...` の行を続け、最後に `Summary:` の行を出す
- `Requirement なし` の行は要件の状態に含めない。`Summary` の件数にも数えない
- `## 要件` 節も要件欄も無い tasks.md では `No requirements section` の1行だけを出す
- 状態の決め方: 対応タスクがすべて `done` なら `done`、1件以上 `done` なら `partial`、0件なら `pending`
- タスクの表記: `done` は `T1(done abc1234)`(commit の先頭7文字。commit が無ければ `T1(done)`)、
  それ以外は `T2(pending)` のように status をそのまま出す。state.json に無いタスクは `T3(missing)`

exit code: `0`=成功、`1`=使い方不備(引数あり)・tasks.md/state.json 不在・要件の検査エラー
(「tasks.md」節の「要件の節と要件欄」の検査と同じ)。

充足したかどうかの判断は親が行う。このスクリプトは状態を機械的に並べるだけで、PR 作成や
グループの進行を止めない。

### workflow-status — 進捗と次の操作の一覧

進捗と次の操作を短く一覧する(読み取り専用。tasks.md・state.json は変更しない)。中断後の再開時や
完了時のサマリー報告に使う。引数は取らない(`--summary` / `-Summary` だけ指定できる)。

```powershell
.agents/workflow/scripts/workflow-status.ps1
.agents/workflow/scripts/workflow-status.ps1 -Summary
```
```bash
.agents/workflow/scripts/workflow-status.sh
.agents/workflow/scripts/workflow-status.sh --summary
```

通常モードの出力(上から順。条件付きの行は条件を満たすときだけ出す):

```
Progress: <done>/<全タスク> done
Group: <名前> <done>/<数>
Current: <ID> <status> | <title>
Run: <ID>-<N> running elapsed=<秒>s log_idle=<秒>s
Failed: T3, T5
PR: <state> <url>
Comprehension: unanswered=<n> <ファイル名> ...
Next: <行動> [reason=<理由>]
```

- `Progress:` — 常に出す
- `Group:` — グループ区切りが2つ以上あるときだけ。`state.json` の `group`(無効なら最初の未完了タスクのグループ)の進捗
- `Current:` — `in_progress` / `in_review` のタスクがあればその行、無ければ `Current: none`
- `Run:` — `Current` が `in_progress` で、そのタスクの最新の run に `guard.sha256` があるときだけ。
  `done` ファイルがあれば `finished`、無ければ `running`(`elapsed` は guard からの経過、`log_idle` は `output.log` の無更新秒数。ログが無ければ `-`)
- `Failed:` — `failed` のタスクがあるときだけ
- `PR:` — `next-task` の判定が `finish` / `group-advance` のときだけ(下記)
- `Comprehension:` — 常に出す。`comprehension/` の質問ファイルのうち、回答が未記入のものの件数とファイル名
- `Next:` — 最後に1行。実行中の run があれば `wait`、PR が `none` なら `create-pr`、`OPEN` なら `wait-merge`、
  `CLOSED` なら `escalate reason=pr-closed`、それ以外は `next-task` の `Next:` 行をそのまま出す

PR の状態は、`next-task` の判定が `finish` / `group-advance` のときだけ `gh pr view <state.json の branch>` で調べる。
PR が無ければ `PR: none`、gh が無い・`branch` が空・gh の失敗(PR 無し以外)・出力を読めないときは `PR: unknown`
(`Next:` は `next-task` の行のまま)。

`--summary`(`-Summary`)では、完了時のサマリー報告用に行を足す:

```
Task <ID> <status> <commit 先頭7文字 | -> retries=<n> | <title>
Requirement R1 [<状態>]: ...
Summary: done=<n> partial=<n> pending=<n>
Worktree: clean | dirty <n>
```

- `Task` — 全タスクを `state.json` の並び順で、先頭(`Progress` の前)に出す。`retries` が無ければ `0`
- `Requirement` / `Summary` — `req-status` と同じ行(`Task` の直後)
- `Worktree:` — `git status --porcelain` の行数。`Comprehension` の次(`Next` の直前)に出す。`--summary` のときだけ git を呼ぶ。git の失敗は `clean` として扱う

exit code: `0`=出力あり、`1`=使い方不備・tasks.md/state.json 不在・`next-task` の失敗(exit 1)・
`--summary` 時の要件の検査エラー。

### text-refine — yomiyasu への推敲の依頼文

`config.json` の `text_refine` から、yomiyasu(日本語の推敲 skill)への依頼文を機械的に作る。
推敲そのものは親が行い、このスクリプトは文章を書き換えない(入力ファイルは変更しない)。
サマリー報告・確認依頼・コミットメッセージ・PR説明・タスク完了報告・tasks.md を、利用者に見せる前に整えるために使う。

```powershell
.agents/workflow/scripts/text-refine.ps1 <summary|confirm|commit|pr_body|task_done|tasks> <入力ファイル> [-Check]
```
```bash
.agents/workflow/scripts/text-refine.sh <summary|confirm|commit|pr_body|task_done|tasks> <入力ファイル> [--check]
```

- 第1引数は推敲する場面(`text_refine.targets` と同じ6つの値)、第2引数は推敲前の文章のファイル
- `tasks` は agent-task-plan が書く tasks.md の推敲。依頼文では、見出し・グループの区切り行・依存・要件・グループ・
  参照ファイルの行と箇条・要件ID(`R1:` 等)・コードブロックの中身・識別子を変えないよう指示する

推敲しないとき(`text_refine.skill` が `null`・空、または場面が `targets` に無い):

```
Refine: off
Found: <場所>
Hint: yomiyasu is installed but text_refine.skill is not set
Next: continue
```

- `Found:` と `Hint:` は `skill` が未設定のときだけ。yomiyasu が見つかった場所ごとに `Found:` を出し、
  1件以上あれば `Hint:` を出す(入力ファイルの存在は確かめない)

推敲するとき:

```
Refine: <skill>
Output: <出力パス>
Request: <依頼文>
Next: refine
```

- 親は `Request:` の依頼文で yomiyasu に推敲させ、`Output:` のファイルを使う
- 出力パスは入力ファイルの拡張子の前に `.refined` を足したもの(`report.md` → `report.refined.md`)。
  同名のファイルが既にあれば先に削除する(`.decisions` のファイルも削除する)
- 依頼文には、場面ごとの文章の種類、読み手(`text_refine.reader`)、変えてはいけないもの
  (コマンド・パス・タスクID・コミットハッシュ・URL・括弧書きの補足、場面によって構成や改行)を入れる

推敲の後のチェック(`--check`。ps1 は `-Check`):

```
Refine: <skill>
Output: <出力パス>
Record: <記録>
Candidates: <件数>
Candidate: <キー> <抜粋>
Decisions: <判断のファイル>
Next: continue
Text:
<推敲済みの本文>
```

判断が足りないときは、`Undecided:` を出して `Next: decide-candidates` で終わる(`Text:` は出ない):

```
Decisions: <判断のファイル>
Undecided: <キー>
Next: decide-candidates
```

- 対象は `text_refine.skill` が `yomiyasu` / `yomiyasu:yomiyasu` のときだけ。推敲しないときは `Refine: off`、
  それ以外の skill は `Refine: <skill>` と `Check: skipped` を出し、どちらも `Next: continue`
- 推敲済みファイル(`Output:`)の SHA-256 を計算し、状態ディレクトリ(`YOMIYASU_STATE_DIR`、無ければ `.yomiyasu`)の
  記録のうち、最終稿の SHA-256 が一致する最新のものを使う。`Record:` は状態ディレクトリからの相対パス
- 候補は yomiyasu の lint の指摘と diff の `meaning_risks` から作る。キーは lint が `L<行> <rule>`、
  meaning_risks が `L<行> meaning_risk:<subkind>`(行が無ければ `-`)。`Candidate:` の抜粋は40字まで
- 判断のファイルは入力ファイルの拡張子の前に `.decisions` を足したもの(`report.md` → `report.decisions.md`)。
  各候補のキーが含まれていれば判断済みとみなす。判断が無い候補は `Undecided:` で出し、`Next: decide-candidates`
- 確かめられないとき(推敲済みファイル・記録・lint の報告が無い等)は `Unchecked: <理由>` と
  `Next: escalate reason=refine-unchecked`
- `tasks` の `--check` は、yomiyasu の記録を確かめる前に、推敲前後の構造を比べる。構造は見出し(`#` 始まり)・
  コメント行(`<!--` 始まり)・`依存`・`要件`・`グループ`・`参照ファイル` の行と参照ファイルの箇条・要件ID(`- R1:` 等)・
  コードブロックの中身で、行末の空白は無視する。この比較は yomiyasu 以外の skill でも行う
  - 同じなら `Structure: same` を出して続ける。yomiyasu なら記録を確かめ、`Next: continue` で終わる(`tasks` では `Text:` を出さない。
    推敲済みのファイル `Output:` をそのまま tasks.md に使う)
  - 違えば、最初に違った箇所を `Changed: L<行> <抜粋>`(推敲前)・`Refined: L<行> <抜粋>`(推敲後)で出し、
    `Next: escalate reason=refine-structure-changed` で終わる(exit 4)
  - 入力ファイルが無いときは `Unchecked: input not found`(exit 3)
- `Candidates: 0` または全候補が判断済みなら `Next: continue` の後に `Text:` を出す。
  `Text:` の次の行から出力の終わりまでが推敲済みの本文

検出する範囲(`Found:` の元。エージェントを問わず `*/skills/yomiyasu/SKILL.md` で、frontmatter の `name` が `yomiyasu` のもの):

- プロジェクト: ルート直下と、ルート直下の各ディレクトリ(`.git`・`node_modules` を除く)の直下。
  ドットで始まるディレクトリ(`.claude`・`.agents` 等)はもう1段下まで
- ホーム: ドットで始まる各ディレクトリ(`~/.claude` 等)の下を3段まで
- Claude Code のプラグイン: `~/.claude/plugins/installed_plugins.json` に `yomiyasu@...` があれば検出

skill の名前は入れ方(プラグイン・skill 単体・エージェントごとの配置)で変わるため、スクリプトは推測しない。
検出して `Hint:` を出すだけで、`text_refine.skill` は利用者が設定する。

exit code: `0`=出力あり、`1`=使い方不備(引数の数・場面の値・`--check` 以外のオプション)・推敲するときに入力ファイルが無い、
`2`=判断が無い候補がある(`--check`)、`3`=推敲済みファイルか記録が無い(`--check`)、
`4`=`tasks` の推敲前後で構造が変わった(`--check`)。

### task-state — タスクの状態遷移

state.json のタスクの状態を、許された遷移だけで更新する。LLM が state.json を手で編集しない
ためのスクリプト。拒否した場合は state.json を変更しない。`updated_at` も更新する。

| 動作 | 遷移 | 用途 |
|------|------|------|
| `start` | `pending` / `in_progress` → `in_progress` | dispatch(中断後の再 dispatch も可) |
| `review` | `in_progress` → `in_review` | 子の完了報告を検証した後 |
| `done` | `in_review` → `done` | レビュー合格・コミット後。`--commit <hash>`(PowerShell は `-Commit`)必須 |
| `retry` | `in_review` → `in_progress`、`retries` + 1 | 修正の再依頼。`retries` が `max_fix_retries` 以上なら拒否(exit 4) |
| `fail` | `pending` 以外 → `failed` | 回復不能(ユーザーへエスカレーション) |
| `reset` | `failed` → `pending`(`retries` を 0、`commit` を null) | ユーザー判断でやり直す場合 |

```powershell
.agents/workflow/scripts/task-state.ps1 T1 start
.agents/workflow/scripts/task-state.ps1 T1 done -Commit abc1234
```
```bash
.agents/workflow/scripts/task-state.sh T1 start
.agents/workflow/scripts/task-state.sh T1 done --commit abc1234
```

exit code: `0`=更新した、`1`=使い方不備・許されない遷移・タスク未検出、`4`=`retry` の上限超過。

### task-commit — レビュー合格後のコミットと状態更新

`in_review` のタスクの本体コミット、state.json の `done` 更新、状態ファイルのコミットを1コマンドで行う。

```powershell
.agents/workflow/scripts/task-commit.ps1 T1 feat "<説明>"
```
```bash
.agents/workflow/scripts/task-commit.sh T1 feat "<説明>"
```

引数は `<TaskId> <type> <説明>`。type は `feat|fix|refactor|docs|test|chore|perf|ci`。

1. 検証: TaskId の形式、type、説明(空でなく改行を含まない)、state.json の対象タスクが `in_review`
2. `branch-check` が非0なら、その出力をそのまま流して exit 10 + その code(11〜15)
3. `.agents/workflow` 配下を除く変更をステージする。ステージが空なら exit 20
4. `<type>: <説明>` + 空行 + `Task: <TaskId> (<state.json の source>)` で本体をコミットする
5. `task-state <TaskId> done --commit <本体のハッシュ>` で状態を更新する
6. state.json・tasks.md・comprehension のうち git に無視されていないものだけを
   `chore: <TaskId> の進捗状態を更新` でコミットする(追跡しないリポジトリでは何もしない)
7. stdout に結果を出し、最後の行に `Next:` 行を出す

exit code: `0`=コミットした、`1`=使い方不備・検証失敗、`11`〜`15`=`branch-check` の exit 1〜5、
`20`=コミットする変更が無い、`30`=`git commit` の失敗、`31`=`task-state` の `done` の失敗。
`Next:` 行は exit 0 が `continue`、exit 20 が `escalate reason=no-changes`。それ以外の失敗には出さない
(11〜15 は `branch-check` の出力をそのまま流す)。

### next-task — 次に処理するタスクの選択

state.json の状態と tasks.md の依存関係から、次に処理するタスクを機械的に選ぶ。
state.json の並び順ではなく依存関係を見るため、挿入したタスクも正しい順で選ばれる。

1. `in_progress` / `in_review` のタスク(中断からの再開対象)があれば、その最初のもの
2. なければ、依存タスクがすべて `done` の最初の `pending` タスク

`max_parallel` が 2 以上のとき(config.json。整数で 1 以上のとき以外は 1 として扱う)は、
`in_review` のタスクを先に返し、全 `done`(exit 3)・グループ完了(exit 6)の判定を通ったあと、
依存がすべて `done` の `pending` タスクから、実行中のタスク(`in_progress`)とも互いにも
変更対象のファイルが重ならないものを `max_parallel` から実行中の数を引いた数まで選ぶ。
`parallel_exclusive_files`(文字列の配列。既定 `["AGENTS.md", "README.md"]`、空配列も有効)に
挙げたファイルを変更対象に持つタスク(変更対象が1つも無いタスクも同じ)は単独で実行し、
他のタスクが実行中のときは選ばず、選ぶときも他のタスクと一緒には選ばない。
選べたら `Next: dispatch <ID> <ID>...`(exit 0)、選べず実行中のタスクがあれば
`Next: wait <ID>...`(exit 5)、どちらも無ければ blocked(exit 4)になる。
`max_parallel` が 1 のときは従来どおり。

```powershell
.agents/workflow/scripts/next-task.ps1
```
```bash
.agents/workflow/scripts/next-task.sh
```

stdout に `<タスクID> <status>`(例: `T8 pending`)を出力する。config の `branch_per_group`
が有効で tasks.md にグループ区切りがある場合、候補は state.json の `group`(現在の作業
グループ。キーが無い・未知の名前なら「未完了タスクを含む最初のグループ」)のタスクに限定される。
作業グループが全タスク `done` で他のグループに未完了の残がある場合は、グループ境界を
知らせるため stdout に作業グループ名を出力して exit 6 を返す(既定グループの場合は
空文字列が出力される)。

exit code: `0`=該当タスクあり、`1`=tasks.md/state.json 不在・依存欄の不正(形式違反・
存在しないID・自己依存・循環依存)、`3`=全タスク `done`、
`4`=実行可能なタスクが無い(`failed` や未完了の依存で止まっている。原因を stderr に列挙)、
`5`=実行中のタスクの完了待ち(`max_parallel` が 2 以上のとき。`Next: wait <ID>...`)、
`6`=作業グループ完了(他グループに未完了あり。`group-advance` で分岐する)。

stdout の最後の行には `Next:` 行を出す(「Next: 行」の節を参照)。

### group-advance — グループ完了後の PR 判定と次グループへのブランチ切替

`next-task` が exit 6(作業グループ完了)を返したグループ境界で実行する。PR の状態を
`gh pr view <state.json の branch> --json state,url` で機械的に判定し、MERGED なら
次のグループのブランチへ切り替える。前提チェック(満たさなければ何も書き換えず exit 1):
作業グループが完了していること(next-task と同じ判定)、`git status --porcelain` が空であること。

```powershell
.agents/workflow/scripts/group-advance.ps1 -Branch "develop/<作業名>-<グループ名>"
```
```bash
.agents/workflow/scripts/group-advance.sh --branch "develop/<作業名>-<グループ名>"
```

PR が MERGED だった場合のみ `--branch` / `-Branch`(次のグループ用の新ブランチ名。
`branch_prefixes` のどれかで始まる名前が必須)を使い、`git switch <base_branch>`
(config.json の `base_branch`。無ければ `main`) → `git pull --ff-only` →
`git switch -c <新ブランチ>` で切替し、state.json の `branch` を新ブランチ名、
`group` を次のグループ(未完了タスクを含む最初のグループ)に更新する。stdout に
`ADVANCED <新ブランチ名> <新グループ名>` を出力する。state.json を書き換えるのは
この MERGED の場合だけで、exit 7 / 8 / 9 / 10 / 1 では何も書き換えない(状況が変わったら
同じコマンドを再実行すればよい)。切替後に state.json が git に無視されていなければ
`git add` して `chore: <新グループ名> グループの作業を開始`(新グループ名が空なら
`chore: 既定グループの作業を開始`)でコミットし、stdout の `ADVANCED` 行の後に
`State commit: <ハッシュ7桁>`(ステージに変更が無ければ `State commit: none`)を出す。
追跡しないリポジトリではコミットしない。コミットに失敗したら stderr に出して exit 1。

exit code: `0`=切替完了、`1`=使い方・前提不備(グループ未完了・作業ツリー未クリーン・
`--branch` 未指定や `branch_prefixes` に合わない名前 等)、`7`=PR 未作成(stdout `NO_PR`)、
`8`=PR が OPEN(マージ待ち。stdout `OPEN <PR URL>`)、`9`=PR が未マージのまま閉鎖
(エスカレーション)、`10`=PR が OPEN だが `origin/<branch>` に未 push のコミットがある、または
`origin/<branch>` が無い(stdout `OPEN <PR URL>`、`Next: update-pr`。fetch はせず、ローカルの
リモート追跡ブランチと比べて判定する)。git / gh の失敗時は何も書き換えずその exit code を返す
(gh の失敗はメッセージが「no pull requests found」の場合のみ exit 7 の「PR なし」扱い)。

exit 0・7・8・9・10 では stdout の最後の行に `Next:` 行を出す(「Next: 行」の節を参照)。

使い方と分岐後の進め方は `agent-workflow` skill の「グループ単位の PR とブランチ切替」を参照。

### branch-check — 今のブランチが作業に使ってよいかの判定

マージ済みの作業ブランチや `main` の上で作業・コミットしてしまうのを防ぐため、今のブランチが
作業に使ってよいかを機械的に判定する。何も書き換えない(読み取り専用)。PR の状態は
`gh pr list --head <現在のブランチ> --state merged --json url --limit 1` で調べる(squash マージでは
`git merge-base --is-ancestor` が成り立たず、main から切った直後の新ブランチでは逆に成り立って
しまうため、祖先判定は使わない)。

```powershell
.agents/workflow/scripts/branch-check.ps1           # tasks.md 以外の作業を始める前
.agents/workflow/scripts/branch-check.ps1 -State    # dispatch・コミットの前(state.json の branch とも照合)
```
```bash
.agents/workflow/scripts/branch-check.sh
.agents/workflow/scripts/branch-check.sh --state
```

判定は次の順に行い、最初に当たったもので終える(gh を呼ばずに済む判定を先に行う):

1. 使い方不備・git の失敗(detached HEAD を含む)→ exit `1`
2. 現在のブランチが `main`(config.json の `base_branch` があればその名前も)→ exit `2`
3. `--state` / `-State` 指定時、state.json の `branch` と現在のブランチが異なる → exit `5`
   (stderr に両方の名前を出す。state.json が無い・`branch` が空の場合はこの判定を飛ばす)
4. gh が無い・認証切れ等で PR 状態を取得できない → exit `4`
5. 現在のブランチの PR がマージ済み → stdout `MERGED <PR URL>`、exit `3`
6. いずれにも当たらない → stdout `OK <ブランチ名>`、exit `0`

一致する PR が無い場合、gh は `[]` を出力して exit 0 で終わる(この場合は 6 の `OK`)。
OPEN の PR しか無いブランチも `OK` になる。古い gh が「no pull requests found」のメッセージで
失敗した場合も、PR なしとして `OK` 扱いにする。

exit code: `0`=使ってよい、`1`=使い方不備・git 失敗、`2`=`main` 上、`3`=PR マージ済み
(stdout `MERGED <PR URL>`)、`4`=gh で判定できない、`5`=state.json の `branch` と不一致。

exit 1 以外では stdout の最後の行に `Next:` 行を出す(「Next: 行」の節を参照)。

### quality-gate — 品質ゲートの実行と判定

`config.json` の `quality_gate.steps` を定義順に実行し、合否を判定する。blocking のステップが
失敗しても後続のステップは実行する(全ステップの結果を一度に報告するため)。各ステップは stdin を
閉じて、sh 版は `bash -c`、ps1 版は `pwsh -Command` で実行する。同じ config.json を両方の版が
読むため、`command` / `fix_command` は両方のシェルで動く書き方にする(例: `npm run test`・`./gradlew test`。
`CI=1 npm test` のような環境変数の前置きは pwsh で動かない)。

```powershell
.agents/workflow/scripts/quality-gate.ps1 [-OutDir <ディレクトリ>] [-Steps typecheck,test] [-Fix]
```
```bash
.agents/workflow/scripts/quality-gate.sh [--out-dir <ディレクトリ>] [--steps typecheck,test] [--fix]
```

ステップの解決順:

1. `quality_gate.steps` の各要素。`command` が空のステップは、`package.json` の `scripts` に同名の
   キーがあれば `npm run <name>`、無ければ SKIP(実行しない)
2. `config.json` に `quality_gate` が無ければ、`package.json` の `scripts` から `typecheck`・`lint`・`test` の
   順に検出する(typecheck・test は blocking、lint は non-blocking)

オプション:

- `--steps` / `-Steps`: 名前をカンマ区切りで指定すると、解決後のステップをその名前だけに絞る
- `--fix` / `-Fix`: `fix_command` を持つステップは、`command` の前に `fix_command` を実行する。出力は
  `<name>.fix.log` に書き、判定には含めない
- `--out-dir` / `-OutDir`: ログの置き場所。省略時は `.agents/workflow/runs/quality-gate-<YYYYMMDD-HHMMSS>/` を作る

各ステップの stdout / stderr は `<out-dir>/<name>.log` に書く。

stdout は次の行を出す:

- ステップごとに `PASS|FAIL|SKIP <name> (blocking|non-blocking): <command>`
- 失敗したステップごとに `--- <name> (last 20 lines)` とログの末尾20行
- `Logs: <out-dir>`
- `Result: PASS|FAIL|NO-STEPS` と、最後の行の `Next:` 行(「Next: 行」の節を参照)

exit code: `0`=PASS(`Next: continue`)、`1`=使い方不備・config が読めない、
`2`=FAIL(blocking のステップが失敗。`Next: escalate reason=quality-gate`)、
`3`=実行するステップが0件(`Next: escalate reason=no-steps`)。non-blocking のステップだけが
失敗した場合は FAIL 行を出すが、exit は `0`。

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

### workflow-setup — セットアップと検証

利用先に `.agents/workflow/` 一式と関連設定を揃える。すべて冪等で、既存のファイルは上書きしない。
**必ずテンプレート側のコピー(`.agents/skills/agents-md-setup/templates/workflow/scripts/`)から実行する**
(`.agents/workflow/scripts/` 側から実行すると exit 1)。

```powershell
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-setup.ps1           # 不足しているものを作る・足す
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-setup.ps1 -Check    # 何も変えず不足を出力
```
```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-setup.sh
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-setup.sh --check
```

行う処理:

1. `.agents/workflow/runs/` を作る。`child_agent.isolate_xdg` が `true` のときだけ `.agents/workflow/.config/` も作る
2. `config.json`・`README.md` を `.agents/workflow/` にコピーする(無ければ)
3. `scripts/` の未配置分を `workflow-sync-scripts --copy-missing` でコピーする(`.sh` に実行権限を付ける)
4. `AGENTS.md` をテンプレートからコピーする(無ければ)
5. `CLAUDE.md` を `@AGENTS.md` の1行で作る(無ければ。独自の内容があれば `DECIDE claude-md`)
6. `.claude` を `.agents` へのリンクにする(Windows はジャンクション、それ以外はシンボリックリンク。壊れている・別の場所を指す・実ディレクトリなら `DECIDE claude-link` / `claude-dir`)
7. `.gitignore` に `.claude`・`.agents/settings.local.json`・`.agents/workflow/.config/`・`.agents/workflow/runs/`・`.agents/workflow/archive/`・`.agents/scheduled_tasks.lock` を足す
8. `.gitattributes` に `.agents/workflow/scripts/*.sh`・`*.py` の `text eol=lf` を足す
9. 旧レイアウト(`.dispatch-run.*`・`logs`・`reports`・`.dispatch-prompt-*.md`)が残っていれば `DECIDE old-layout`

出力の行:

| 行 | 意味 |
|----|------|
| `CREATED <パス>` | 作成した |
| `APPENDED <ファイル>: <行>` | 既存ファイルに行を足した |
| `MISSING <パス>` | `--check` のとき、不足しているもの(何も変えない) |
| `DECIDE <種別>: <内容>` | 利用者の判断が要る事項(自動では直さない) |

最後の行は `DECIDE` があれば `Next: confirm`、無ければ `Next: continue`。

exit code: `0`=変更済み(`--check` では不足なし)かつ `DECIDE` なし、`1`=使い方不備・git の外・テンプレート側以外からの実行、
`3`=`DECIDE` あり(`--check` では `MISSING` あり)。

### workflow-update — npx skills update 後の確認

利用先で `npx skills update` のあとに実行し、`npx skills` で導入済みかと、配置済みスクリプトとの差分を確かめる。
**必ずテンプレート側のコピー(`.agents/skills/agents-md-setup/templates/workflow/scripts/`)から実行する**。

```powershell
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.ps1
```
```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh
```

手順:

1. ルートに `skills-lock.json` があるか確かめる(無ければ stderr にメッセージを出し、`Next: escalate reason=not-npx` で exit 2)
2. `workflow-sync-scripts` で配置済みスクリプトとの差分を調べる(差分があれば exit 3。失敗したら exit 22)

最後の行は `Next: continue`(exit 0)/ `Next: confirm`(exit 3。差分を確認し、承認を得て `workflow-sync-scripts --overwrite`)/
`Next: escalate reason=<not-npx|sync-failed>`。

exit code: `0`=配置済みスクリプトとの差分なし、`1`=使い方不備・git の外・テンプレート側以外からの実行、
`2`=`npx skills` で導入されていない(ルートに `skills-lock.json` が無い)、`3`=配置済みスクリプトに差分あり、
`22`=差分確認(workflow-sync-scripts)の失敗。

### workflow-sync-scripts — 配布テンプレートの更新を配置先に反映

`scripts/` と `README.md` はセットアップ時のコピーのため、`npx skills update` で `.agents/skills/` を更新しても
自動では更新されない。このスクリプトで配布テンプレートとの差分を検出・反映する
(`workflow-update` skill から使う)。**必ずテンプレート側のコピー
(`.agents/skills/agents-md-setup/templates/workflow/scripts/`)から実行する**。

```powershell
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.ps1                 # 一覧
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.ps1 -CopyMissing    # 未配置のみコピー
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.ps1 -Diff scripts/dispatch-run.ps1
.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.ps1 -Overwrite scripts/dispatch-run.ps1,README.md
```
```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --copy-missing
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --diff scripts/dispatch-run.sh
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --overwrite scripts/dispatch-run.sh,README.md
```

一覧は `missing`(未配置)/ `differs`(内容が異なる)とファイル名(`scripts/<名前>` / `README.md`)を
表示する。改行コード(CRLF/LF)・BOM だけの違いは差分とみなさない。`differs` のファイルは
利用先でカスタマイズされている可能性があるため、差分を確認してユーザーの承認を得てから
`--overwrite` する。

exit code: `0`=成功(一覧モードでは差分なし)、`1`=使い方不備・不明なファイル名、`3`=一覧モードで差分あり。

### workflow-archive — 一巡後のサイクル退避

`tasks.md` / `state.json` / `runs/` / `comprehension/` を
`archive/<YYYYMMDD-HHmm>-<スラッグ>/` へ移動する(`config.json` と `scripts/` は残す)。

```powershell
.agents/workflow/scripts/workflow-archive.ps1 <スラッグ>
```
```bash
.agents/workflow/scripts/workflow-archive.sh <スラッグ> [--force]
```

PowerShell 版は `-Force`、bash 版は `--force`(スラッグの前後どちらでも可)。
`--force` / `-Force` を付けると PR の状態を確かめずにアーカイブする。

```powershell
.agents/workflow/scripts/workflow-archive.ps1 <スラッグ> -Force
```
```bash
.agents/workflow/scripts/workflow-archive.sh <スラッグ> --force
```

アーカイブする前に、`state.json` の `branch` の PR の状態を `gh pr view` で確かめる。
`branch` が空・`main`・`config.json` の `base_branch` のときは確かめずに進む。
判定ごとの結果は次のとおり。

| 判定 | 結果 | stdout |
|------|------|--------|
| PR が `MERGED` | アーカイブする(exit 0) | `Archived: ...` |
| PR が `OPEN` | 止める(exit 2) | `OPEN <PR URL>` |
| PR が `CLOSED` | 止める(exit 3) | `CLOSED <PR URL>` |
| gh が無い・失敗・出力を解析できない | 止める(exit 4) | (`Next:` 行のみ) |
| PR 未作成で、ブランチに未マージのコミットがある(比較先が無い場合も含む) | 止める(exit 5) | `NO_PR` |
| PR 未作成で、未マージのコミットが無い・ローカルにブランチが無い | アーカイブする(exit 0) | `Archived: ...` |

未マージのコミットの比較先は `base_branch`(無ければ `main`)。
止めるとき(exit 2〜5)は何も移動せず、`archive/` も作らない。stdout の最後の行は次アクションを示す
`Next:` 行になる。

| exit | `Next:` 行 |
|------|-----------|
| 2 | `Next: escalate reason=pr-open` |
| 3 | `Next: escalate reason=pr-closed` |
| 4 | `Next: escalate reason=gh-unavailable` |
| 5 | `Next: escalate reason=pr-not-created` |

exit 0 の出力は `Archived: ...` の1行だけで、`Next:` 行は出さない。

exit code: `0`=アーカイブした、`1`=使い方不備(スラッグ未指定・パス区切りや `..` を含む・
workflow ディレクトリ不在・移動対象なし)、`2`=PR が OPEN、`3`=PR が CLOSED、
`4`=gh で判定不能、`5`=PR 未作成でブランチに未マージのコミットがある。
