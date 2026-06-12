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

### 5. 完了報告

正常終了時またはコンフリクト発生時に以下を報告する:

- 実行したコマンド
- 更新結果(成功/コンフリクト/エラー)
- コンフリクト時は衝突ファイル一覧
- 次のアクション(コミット確認、テスト実行など)
