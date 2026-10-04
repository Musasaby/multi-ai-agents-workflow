---
name: workflow-update
description: 利用先で .agents/skills/ の upstream 更新を1コマンドで取り込む。作業ツリーのクリーン確認、config.json の upstream 設定読み取り、git subtree pull の実行、コンフリクト時の対応を行う。
---

# ワークフロー skill の upstream 更新

利用先リポジトリの `.agents/skills/` ディレクトリを `git subtree` で upstream から更新する。

## 前提

- `agents-md-setup` 済みであること(`.agents/skills/` が subtree として取り込まれている)
- `git subtree` が利用可能であること

## 手順

### 1. 作業ツリーのクリーン確認

未コミットの変更がないことを確認する:

```powershell
git status --porcelain
```

出力が空でない場合は中断し、ユーザーにコミットまたは退避を指示する。

### 2. upstream 設定の読み取り

`.agents/workflow/config.json` の `upstream` セクションを読む:

- `upstream.url` — upstream リポジトリの URL
- `upstream.branch` — 追従するブランチ名

未設定または空の場合は以下のデフォルトを使用する:

- URL: `https://github.com/Musasaby/multi-ai-agents-workflow.git`
- branch: `main`

### 3. git subtree pull の実行

取得した URL と branch を使って subtree pull を実行する:

```powershell
git subtree pull --prefix=.agents/skills <URL> <branch> --squash
```

### 4. コンフリクト対応

`git subtree pull` の結果にコンフリクトが発生した場合:

- 衝突ファイル一覧を `git status --porcelain` または `git diff --name-only --diff-filter=U` で取得する
- 取得した一覧をユーザーに提示し、対処を仰ぐ
- **勝手に解決しない**。解決はユーザーまたは別途依頼されたエージェントが行う
- コンフリクト解決後、ユーザーに `git commit` を指示する

### 5. 配置済みスクリプト・README の更新

`.agents/workflow/scripts/` と `.agents/workflow/README.md` は、セットアップ時に
`_templates/workflow/` からコピーされた**複製**のため、手順3で `.agents/skills/` を更新しても
自動では更新されない。`workflow-sync-scripts` を**テンプレート側のコピー**
(`.agents/skills/_templates/workflow/scripts/`)から実行し、差分を反映する
(配置先側の古いスクリプトを実行しないこと)。

1. **差分の一覧**:
   ```powershell
   .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.ps1
   ```
   ```bash
   bash .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh
   ```
   exit 0 なら差分なし(この手順は終了)。exit 3 なら `missing`(未配置)/ `differs`
   (内容が異なる)のファイルが一覧表示される。改行コードだけの違いは差分とみなさない
2. **未配置ファイルのコピー**(`missing` がある場合。新しく追加されたスクリプト等なので、
   確認なしでコピーしてよい):
   ```powershell
   .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.ps1 -CopyMissing
   ```
   ```bash
   bash .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh --copy-missing
   ```
3. **差分のあるファイルの上書き**(`differs` がある場合): 利用先でカスタマイズされている
   可能性があるため、**ユーザーの承認なしに上書きしない**。`-Diff <名前>` / `--diff <名前>` で
   差分(配置先 → テンプレート)を確認し、ファイルごとの差分の要約(カスタマイズの痕跡が
   あるか等)をユーザーに提示する。承認されたファイルだけを上書きする
   ```powershell
   .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.ps1 -Diff scripts/dispatch-run.ps1
   .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.ps1 -Overwrite scripts/dispatch-run.ps1,README.md
   ```
   ```bash
   bash .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh --diff scripts/dispatch-run.sh
   bash .agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh --overwrite scripts/dispatch-run.sh,README.md
   ```

`.agents/workflow/scripts/` 等がコミット対象の利用先では、反映後の変更をユーザーに
コミットしてもらう(この skill ではコミットしない)。

**XDG 切り替えの既定変更に伴う移行**: `dispatch-run` は `child_agent.isolate_xdg` が `true` のときだけ
子CLIの XDG をプロジェクト内(`.agents/workflow/.config`)に切り替える(以前は常に切り替えていた)。
キーが無い既存の config.json では切り替えなくなる。sandbox 環境で切り替えが必要な利用先には、
`config.json` の `child_agent` に `"isolate_xdg": true` を追加するよう提案する

**子へのプロンプトからのプロジェクト固有指示の削除に伴う移行**: `dispatch-prompt-template.md` から
Kotlin/Gradle 固有の指示(`-Pkotlin.incremental=false` での切り分け、Gradle 引数の引用符)を削除した。
これらに依存していた利用先には、利用先の `AGENTS.md` の「テスト・検証の注意(子エージェント向け)」節
(雛形は `_templates/AGENTS.md`)に同じ内容を書くよう提案する

**依存欄の検証強化に伴う移行**: `state-sync` / `next-task` は全タスクの依存欄を厳密に検証する
(依存行の欠落・注記付きの値・存在しないID・循環をエラーにする)。進行中のサイクルの
tasks.md が旧形式(例: `- **依存**: T30(完了済み)`、依存行の無いタスク)の場合、スクリプトを
更新すると `state-sync` / `next-task` が exit 1 で止まる。更新後に `next-task` を1回実行し、
exit 1 になった場合は stderr に列挙されたタスクの依存欄を `なし` / `T1, T2` 形式に直す
(注記は目的欄へ移す)ようユーザーに提案する

### 6. 旧レイアウトの検出

`.agents/skills/` の更新後、`.agents/workflow/` に本計画(dispatchプロンプトの機械生成)
以前のレイアウトが残っていないか確認する。以下のいずれかを検出したら、
`agents-md-setup` skillの再実行(新レイアウトの `scripts/` 配下一式のコピー)を
**ユーザーに提案する**(勝手に削除・上書きはしない):

- `.agents/workflow/.dispatch-run.ps1` または `.agents/workflow/.dispatch-run.sh`(ルート直下に残る旧スクリプト。新レイアウトでは `scripts/dispatch-run.ps1/.sh`)
- `.agents/workflow/logs/` または `.agents/workflow/reports/`(新レイアウトでは `runs/<タスクID>-<試行回数>/` に統合)
- `.agents/workflow/.dispatch-prompt-*.md`(旧・タスク単位のプロンプトファイル。新レイアウトでは `runs/<タスクID>-<試行回数>/prompt.md`)

`.agents/workflow/` 配下の実運用ファイル(tasks.md / state.json / config.json 等)は
この skill では変更しない。

### 7. .gitignore の確認

`.gitignore` に以下3項目が記載されているか確認する。欠けている場合は `agents-md-setup`
skillの再実行(手順4の `.gitignore` 整備)を**ユーザーに提案する**(この skill 自身では
`.gitignore` を編集しない):

- `.agents/workflow/runs/`
- `.agents/workflow/.config/`
- `.agents/scheduled_tasks.lock`(Claude Code 本体のランタイムファイルでありコミット対象外)

### 8. 完了報告

正常終了時またはコンフリクト発生時に以下を報告する:

- 実行したコマンド
- 更新結果(成功/コンフリクト/エラー)
- コンフリクト時は衝突ファイル一覧
- スクリプト・README の同期結果(コピーした未配置ファイル、上書きしたファイル、
  ユーザー判断で上書きしなかった差分のあるファイル)
- 旧レイアウト検出の有無、検出した場合はユーザーへの提案内容
- `.gitignore` の3項目の記載有無、欠けている場合は `agents-md-setup` 再実行の提案
- 次のアクション(コミット確認、テスト実行など)
