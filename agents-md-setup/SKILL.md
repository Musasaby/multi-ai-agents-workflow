---
name: agents-md-setup
description: AGENTS.md / .agents を正本としたエージェント共通設定のセットアップと検証。テンプレートからのスキャフォールド、CLAUDE.mdのimportラッパー作成、.claudeリンクの作成、動作検証を行う。clone直後やリンク破損時に実行する。
---

# AGENTS.md 正本化セットアップ

single source of truth として `AGENTS.md`(リポジトリルート)と `.agents/` を正本にし、
Claude Code 固有のパス(`CLAUDE.md`, `.claude/`)からはリンク経由で参照させる。

## 手順

### 1. 正本の確認・スキャフォールド

- `AGENTS.md` がルートに存在するか確認。なければ `_templates/AGENTS.md` から作成する(skill ディレクトリから見たパスは `../_templates/AGENTS.md`、利用先では `.agents/skills/_templates/AGENTS.md`)。このとき実体のある `CLAUDE.md`(import 1行でないもの)が存在すれば、その内容を `AGENTS.md` に移行する
- `AGENTS.md` が既存の場合は、テンプレートの「マルチエージェントワークフロー」節を追記するかユーザーに提案する。**既存の内容を上書きしない**
- `.agents/skills/`, `.agents/workflow/` ディレクトリの存在を確認
- `.agents/workflow/.config/opencode/log` ディレクトリを事前作成する(子エージェント CLI が sandbox 内から設定・ログディレクトリを作成できない環境への備え。`agent-dispatch` の `XDG_CONFIG_HOME` / `XDG_DATA_HOME` プリフライトが参照する):
  ```powershell
  New-Item -ItemType Directory -Force .agents/workflow/.config/opencode/log
  ```
- `.agents/workflow/config.json` または `.agents/workflow/README.md` が無い場合、それぞれ `_templates/workflow/config.json` / `_templates/workflow/README.md` からコピーする。**既存のファイルは上書きしない**

### 2. CLAUDE.md ラッパーの作成

`CLAUDE.md` を以下の1行だけのファイルにする(Claude Code の `@path` import機能で AGENTS.md を読み込む):

```
@AGENTS.md
```

シンボリックリンクではなく import 方式を使う理由: Windows のファイルシンボリックリンクは
管理者権限または開発者モードが必要であり、Git でのclone時にプレーンファイル化する問題もあるため。

### 3. .claude リンクの作成

`.claude` が存在しない、またはリンク切れの場合、OSに応じて作成する:

- **Windows**: まずシンボリックリンクを試し、権限エラーならジャンクションにフォールバック

```powershell
try { New-Item -ItemType SymbolicLink -Path .claude -Target .agents -ErrorAction Stop }
catch { New-Item -ItemType Junction -Path .claude -Target (Resolve-Path .agents).Path }
```

- **macOS/Linux**: `ln -s .agents .claude`

既に実体ディレクトリとして `.claude` が存在する場合は、中身を `.agents` にマージしてから
置き換える(**ユーザーに確認してから**削除すること)。

### 4. .gitignore の整備

以下が `.gitignore` に含まれていることを確認し、なければ追記する:

```
# Agent link (agents-md-setup skillで再作成する)
.claude
# 個人設定
.agents/settings.local.json
# CLI 設定・キャッシュ (コミットしない)
.agents/workflow/.config/
```

`.claude` はリンクのためコミットしない。clone後はこのskillを再実行して再作成する。

### 5. ファイルベース検証(必須)

以下をすべて確認し、結果を報告する:

1. **リンク解決**: `(Get-Item .claude).LinkType` が `Junction` または `SymbolicLink` であり、`Target` が `.agents` を指す
2. **ファイル参照**: `.claude/skills/` 配下に `.agents/skills/` と同じ SKILL.md が見えること。以下を実行して、リンク経由で各 SKILL.md の frontmatter `name` を列挙する
   ```powershell
   Get-ChildItem .claude/skills -Recurse -Filter SKILL.md | ForEach-Object {
       $name = (Select-String -Path $_.FullName -Pattern '^name: (.+)$' | Select-Object -First 1).Matches.Groups[1].Value
       [PSCustomObject]@{ Path = $_.FullName; Name = $name }
   }
   ```
   `.agents/skills/` 配下の SKILL.md と同一の `name` が列挙できればOK

ファイルベース検証がすべて通っていれば、セットアップ自体は成功とみなす。

### 6. CLI検証(任意・時間がある場合)

ファイルベース検証が通っていればセットアップは成功であるが、時間に余裕がある場合は以下のCLI検証を行う。

**注意**: `claude -p` の初回コールドスタートは環境構築のため60秒を超えうる。タイムアウト目安は3分とし、60秒で打ち切らないこと。

1. **skill認識**: ヘッドレス実行で project skill が認識されること
   ```powershell
   claude -p "利用可能なskillのうち agent-workflow 系の名前だけを列挙して" --max-turns 1
   ```
   出力に `.agents/skills/` 配下のskill名が含まれればOK
2. **import動作**: `claude -p "CLAUDE.mdから読み込まれたプロジェクト指示の見出しを列挙して" --max-turns 1` で AGENTS.md の内容(「マルチエージェントワークフロー」等の見出し)が返ること

CLI検証に失敗しても、ファイルベース検証が通っていればセットアップ自体は成功とみなす。失敗した場合は原因と対処をユーザーに報告し、勝手に構成を変えないこと。
