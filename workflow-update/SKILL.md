---
name: workflow-update
description: 利用先で .agents/skills/ の upstream 更新を1コマンドで取り込む。workflow-update スクリプトで subtree pull とコンフリクト検出を行い、未配置ファイルのコピー・差分のあるファイルの上書きと、workflow-setup --check による配置状態の確認を行う。
---

# ワークフロー skill の upstream 更新

利用先リポジトリの `.agents/skills/` ディレクトリを `git subtree` で upstream から更新する。
クリーン確認・upstream 設定の読み取り・subtree pull・コンフリクト検出は `workflow-update` スクリプトが行う。

## 前提

- `workflow-setup`(`agents-md-setup` 経由)済みであること(`.agents/skills/` が subtree として取り込まれている)
- `git subtree` が利用可能であること

## 手順

### 1. workflow-update の実行

**テンプレート側のコピー**から実行する(配置先側の古いスクリプトを実行しないこと):

```powershell
.agents/skills/_templates/workflow/scripts/workflow-update.ps1
```
```bash
bash .agents/skills/_templates/workflow/scripts/workflow-update.sh
```

出力の `Next:` 行に従う:

- `continue` — 更新完了(差分なし)。手順3へ
- `confirm` — `.agents/workflow/` への配置物に差分がある。手順2へ
- `escalate reason=conflict` — `CONFLICT` 行の衝突ファイル一覧をユーザーに提示し、対処を仰ぐ。
  **勝手に解決しない**。解決はユーザーまたは別途依頼されたエージェントが行い、解決後はユーザーに `git commit` を指示する
- `escalate reason=dirty-tree` — 未コミットの変更がある。ユーザーにコミットまたは退避を依頼する
- その他の `escalate`(`subtree-failed` 等) — 出力をユーザーに提示して判断を仰ぐ

### 2. 配置済みスクリプト・README の更新(`confirm` の場合)

`.agents/workflow/scripts/` と `.agents/workflow/README.md` は、セットアップ時に
`_templates/workflow/` からコピーされた**複製**のため、`.agents/skills/` の更新だけでは
自動では更新されない。`workflow-sync-scripts` を**テンプレート側のコピー**
(`.agents/skills/_templates/workflow/scripts/`)から実行し、差分を反映する。

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

### 3. 配置状態の確認(旧レイアウト・.gitignore・.gitattributes)

`workflow-setup --check` を**テンプレート側のコピー**から実行する(何も変更しない):

```powershell
.agents/skills/_templates/workflow/scripts/workflow-setup.ps1 -Check
```
```bash
bash .agents/skills/_templates/workflow/scripts/workflow-setup.sh --check
```

`MISSING` / `DECIDE` 行があれば、`agents-md-setup` skill の再実行を**ユーザーに提案する**
(旧レイアウトの残骸、`.gitignore` / `.gitattributes` の欠落などが対象。この skill 自身では
勝手に削除・上書き・編集しない)。`.agents/workflow/` 配下の実運用ファイル
(tasks.md / state.json / config.json 等)もこの skill では変更しない。

### 4. 完了報告

正常終了時またはコンフリクト発生時に以下を報告する:

- 実行したコマンドと `Next:` 行の内容
- 更新結果(成功/コンフリクト/dirty-tree/エラー)
- コンフリクト時は `CONFLICT` 行の衝突ファイル一覧
- スクリプト・README の同期結果(コピーした未配置ファイル、上書きしたファイル、
  ユーザー判断で上書きしなかった差分のあるファイル)
- `workflow-setup --check` の結果(`MISSING` / `DECIDE` の有無)、あれば `agents-md-setup` 再実行の提案
- 次のアクション(コミット確認、テスト実行など)
