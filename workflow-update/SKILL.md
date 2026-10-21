---
name: workflow-update
description: 利用先で .agents/skills/ の配布元 skill を npx skills update で更新し、workflow-update スクリプトで配置済みスクリプトとの差分を確かめる。未配置ファイルのコピー・差分のあるファイルの上書きと、workflow-setup --check による配置状態の確認を行う。
---

# ワークフロー skill の更新

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.sh` を `.ps1` にし、`--copy-missing` `--diff` `--overwrite` `--check` のようなオプションを `-CopyMissing` `-Diff` `-Overwrite` `-Check` の形の名前付き引数に読み替える。

利用先リポジトリの `.agents/skills/` にある配布元の skill を `npx skills update` で更新し、
配置済みスクリプトとの差分を `workflow-update` スクリプトで確かめる。

## 前提

- `npx skills add` で導入済みであること(リポジトリのルートに `skills-lock.json` がある)
- Node.js 22.20 以上であること

## 手順

### 1. skill の更新

```bash
npx skills update -p -y
```

配布元の skill は上書きされ、手元の編集は消える(配布元の skill は直接編集しない方針)。
失敗したら出力をユーザーに提示して判断を仰ぐ。

### 2. workflow-update の実行

**テンプレート側のコピー**から実行する(配置先側の古いスクリプトを実行しないこと):

```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh
```

出力の `Next:` 行に従う:

- `continue` — 差分なし。手順4へ
- `confirm` — `.agents/workflow/` への配置物に差分がある。手順3へ
- `escalate reason=not-npx` — git subtree で導入した利用先。
  [references/migrations.md](references/migrations.md) の「git subtree から npx skills への移行」の手順をユーザーに示し、承認を得てから行う
- `escalate reason=sync-failed` — stderr に `_templates/workflow/scripts/workflow-sync-scripts.sh` が無いと出ていれば、
  `not-npx` と同じく [references/migrations.md](references/migrations.md) の移行の節を示す。それ以外は出力(stderr を含む)をユーザーに提示して判断を仰ぐ

### 3. 配置済みスクリプト・README の更新(`confirm` の場合)

`.agents/workflow/scripts/` と `.agents/workflow/README.md` は、セットアップ時に
`.agents/skills/agents-md-setup/templates/workflow/` からコピーされた**複製**のため、
`.agents/skills/` の更新だけでは自動では更新されない。`workflow-sync-scripts` を**テンプレート側のコピー**
(`.agents/skills/agents-md-setup/templates/workflow/scripts/`)から実行し、差分を反映する。
手順2の `workflow-update` の出力にある `missing` / `differs` の行を使う(改行コードだけの違いは差分とみなされない)。

1. **未配置ファイルのコピー**(`missing` がある場合。新しく追加されたスクリプト等なので、
   確認なしでコピーしてよい):
   ```bash
   bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --copy-missing
   ```
2. **差分のあるファイルの上書き**(`differs` がある場合): 利用先でカスタマイズされている
   可能性があるため、**ユーザーの承認なしに上書きしない**。`-Diff <名前>` / `--diff <名前>` で
   差分(配置先 → テンプレート)を確認し、ファイルごとの差分の要約(カスタマイズの痕跡が
   あるか等)をユーザーに提示する。承認されたファイルだけを上書きする
   ```bash
   bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --diff scripts/dispatch-run.sh
   bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --overwrite scripts/dispatch-run.sh,README.md
   ```

`.agents/workflow/scripts/` 等がコミット対象の利用先では、反映後の変更をユーザーに
コミットしてもらう(この skill ではコミットしない)。

更新後、`.agents/workflow/state.json` があれば `.agents/workflow/scripts/next-task.sh` を1回実行する。
exit 1 になったとき(依存欄の旧形式の可能性)と、sandbox 環境で使っていて `config.json` の
`child_agent` に `isolate_xdg` が無いときは、[references/migrations.md](references/migrations.md) を読んで対処する。

### 4. 配置状態の確認(旧レイアウト・.gitignore・.gitattributes)

`workflow-setup --check` を**テンプレート側のコピー**から実行する(何も変更しない):

```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-setup.sh --check
```

`MISSING` / `DECIDE` 行があれば、`agents-md-setup` skill の再実行を**ユーザーに提案する**
(旧レイアウトの残骸、`.gitignore` / `.gitattributes` の欠落などが対象。この skill 自身では
勝手に削除・上書き・編集しない)。`.agents/workflow/` 配下の実運用ファイル
(tasks.md / state.json / config.json 等)もこの skill では変更しない。

### 5. 完了報告

以下を報告する:

- 実行したコマンドと `Next:` 行の内容
- 更新結果(成功/エラー)
- スクリプト・README の同期結果(コピーした未配置ファイル、上書きしたファイル、
  ユーザー判断で上書きしなかった差分のあるファイル)
- `workflow-setup --check` の結果(`MISSING` / `DECIDE` の有無)、あれば `agents-md-setup` 再実行の提案
- `.agents/skills/` と `skills-lock.json` の変更をユーザーにコミットしてもらう旨
- 次のアクション(テスト実行など)
