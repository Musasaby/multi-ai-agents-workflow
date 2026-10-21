---
name: agents-md-setup
description: AGENTS.md / .agents を正本としたエージェント共通設定のセットアップと検証。workflow-setup スクリプトによるスキャフォールド、CLAUDE.mdのimportラッパー作成、.claudeリンクの作成、動作検証を行う。clone直後やリンク破損時に実行する。
---

# AGENTS.md 正本化セットアップ

single source of truth として `AGENTS.md`(リポジトリルート)と `.agents/` を正本にし、
Claude Code 固有のパス(`CLAUDE.md`, `.claude/`)からはリンク経由で参照させる。
`CLAUDE.md`・`.claude/` は親が Claude Code の場合のためのもので、AGENTS.md を直接読む親(Codex 等)では使われない(作られても害はない)。
それ以外の親は[references/parent-child.md](references/parent-child.md) を参照する。
ファイル・ディレクトリの作成や `.gitignore` / `.gitattributes` の整備は `workflow-setup` スクリプトが行う
(処理の詳細と出力の仕様は `agents-md-setup/templates/workflow/README.md` の「workflow-setup」の節を参照)。

## 手順

### 1. workflow-setup の実行

`workflow-setup` を**テンプレート側のコピーから**実行する(配置先の `.agents/workflow/scripts/` にはまだ無い場合があるため):

前提・解釈: `workflow-setup` の実行例は `.sh` 版だけを示す。PowerShell では `.sh` を `.ps1` にし、`--check` を `-Check` の形の名前付き引数に読み替える(手順2・3の PowerShell の例はそのまま使う)。

```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-setup.sh
```

配布元リポジトリでは `agents-md-setup/templates/workflow/scripts/` 配下のものを使う。
変更せずに検証だけ行う場合は、`--check` を付ける。

出力末尾の `Next:` 行で次の動作を決める:

- `Next: continue` — 手順2へ進む
- `Next: confirm` — `DECIDE` 行ごとにユーザーに確認する。承認された作業だけを親が行い、
  `workflow-setup` を再実行して `Next: continue` になることを確かめる
  - `claude-md`: 実体のある `CLAUDE.md` の内容を `AGENTS.md` へ移してよいか
  - `claude-dir` / `claude-link`: `.claude` の中身を `.agents` に移し、リンクに置き換えてよいか
  - `old-layout`: 旧レイアウトのファイル・ディレクトリを削除してよいか(過去の実行履歴が必要な場合もあるため自動削除しない)

`AGENTS.md` が既存の場合は、テンプレート(`agents-md-setup/templates/AGENTS.md`)の「テスト・検証の注意(子エージェント向け)」節と
「マルチエージェントワークフロー」節を追記するかユーザーに提案する。**既存の内容を上書きしない**。

`.gitignore` / `.gitattributes` が変更されたらコミットする(未コミットだと `agent-dispatch` の事前チェック(作業ツリーがクリーン)で止まる)。

`.agents/workflow/config.json` の `child_agent.command_template` と `child_agent.profile` を、使う子CLIに合わせて設定する
(`.agents/workflow/README.md` の「子CLIのプロファイル」の例)。`.agents/workflow/.config/` は `child_agent.isolate_xdg` が
true のときだけ作られる。

### 2. ファイルベース検証(必須)

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

### 3. CLI検証(任意・時間がある場合)

ファイルベース検証が通っていればセットアップは成功であるが、時間に余裕がある場合は以下のCLI検証を行う(親が Claude Code の場合。`claude -p` を使う)。

**注意**: Claude Code の場合、`claude -p` の初回コールドスタートは環境構築のため60秒を超えうる。タイムアウト目安は3分とし、60秒で打ち切らないこと。

1. **skill認識**: ヘッドレス実行で project skill が認識されること
   ```powershell
   claude -p "利用可能なskillのうち agent-workflow 系の名前だけを列挙して" --max-turns 1
   ```
   出力に `.agents/skills/` 配下のskill名が含まれればOK
2. **import動作**: `claude -p "CLAUDE.mdから読み込まれたプロジェクト指示の見出しを列挙して" --max-turns 1` で AGENTS.md の内容(「マルチエージェントワークフロー」等の見出し)が返ること

CLI検証に失敗しても、ファイルベース検証が通っていればセットアップ自体は成功とみなす。失敗した場合は原因と対処をユーザーに報告し、勝手に構成を変えないこと。
