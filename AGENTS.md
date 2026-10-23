# AGENTS.md(multi-ai-agents-workflow の開発用)

このファイルは、**このリポジトリ自体を開発する**AIエージェント(親・子とも)向けの指示です。
利用先プロジェクト向けのテンプレートは `agents-md-setup/templates/AGENTS.md` です(こちらとは別物)。
`CLAUDE.md`(git 管理外)は `@AGENTS.md` の1行でこのファイルを読み込みます。

## プロジェクト概要

- 複数エージェント協調の実装ワークフロー(skill 群とスクリプト)の配布元リポジトリ。
  利用先は `npx skills add` で各 skill(`SKILL.md` を持つディレクトリ)を `.agents/skills/` に取り込む。
  `tests/`・`docs/`・このファイルは配られない
- 主要ディレクトリ:
  - `agent-*/SKILL.md`・`agents-md-setup/`・`workflow-update/` — skill(正本)
  - `agents-md-setup/templates/` — 利用先用テンプレート(`AGENTS.md`・`CLAUDE.md`・`workflow/`)
  - `agents-md-setup/templates/workflow/scripts/` — 利用先に配布するスクリプト(`.sh` と `.ps1` を対で持つ)
  - `agents-md-setup/templates/workflow/README.md` — スクリプトと tasks.md / state.json の仕様
  - `tests/` — スクリプトのシナリオテスト(`test-*.sh` / `test-*.ps1`)と品質ゲート

## 共通ルール

- 回答・コミットメッセージ・ドキュメントは日本語で書く(コード識別子は除く)
- コミットは conventional commits 形式: `<type>: <description>`(type: feat, fix, refactor, docs, test, chore, perf, ci)
- `main` ブランチへの直接コミットは禁止。作業は `develop/<作業名>` ブランチで行う

## 編集対象(正本とミラー)

- **編集するのはリポジトリルートのファイルだけ**(`agents-md-setup/templates/...`、`agent-*/SKILL.md`、`tests/...`、
  `README.md` 等)。`.agents/` 配下は git 管理外のミラー(ローカル実行用のコピー)なので編集しない
- スクリプトは `.sh` と `.ps1` で同じ動作にし、テストも両方に書く
- skill のコマンド例は `.sh` 版だけを書き、冒頭に `.ps1` への読み替え規則の文を置く
- めったに起きない場面の手順は `references/*.md` に置き、本文からリンクする(サイズ上限は `tests/skill-size.ps1` が検査する)
- exit code の意味は `agents-md-setup/templates/workflow/README.md` に書き、skill には次の行動だけを書く

## テスト・検証の注意(子エージェント向け)

- 品質ゲート: `pwsh -NoProfile -File tests/syntax-check.ps1`(ルートの `agents-md-setup/templates/workflow/scripts/` と
  `tests/` の構文、全ファイルの改行コード・BOM を検査する)
- シナリオテスト: `bash tests/test-<名前>.sh` と `pwsh -NoProfile -File tests/test-<名前>.ps1`。
  一時ディレクトリにダミーの利用先プロジェクトを作って実行するため、このリポジトリの `.agents/` には
  影響しない。gh は PATH 先頭のスタブで差し替えており、実際の GitHub にはアクセスしない
- テスト一式(`tests/run-all.*`)は実行しない(タスクの受け入れ基準にも書かない)。sh 版と ps1 版のテストは
  1 つずつ別のコマンドで実行する(子の Bash は 10 分で打ち切られる)。
  詳しくは `CONTRIBUTING.md` の「どこで何を確かめるか」
- 改行コードは全ファイル LF、非 ASCII 文字を含む `.ps1` は BOM 付き UTF-8、それ以外(`.md` を含む)は BOM なし。
  `tests/syntax-check.ps1` が検査するので、既存ファイルの改行コードを調べる必要はない
  (違反があれば検査が失敗し、ファイル名を出す)
- 外部コマンドの挙動を確かめるためにプロジェクト外(`/tmp` 等)でリポジトリを作らない。
  テストのスタブ(`tests/test-group-advance.*` の gh スタブ等)を参考にする

## マルチエージェントワークフロー

- 状態・設定: `.agents/workflow/`(`config.json`・`tasks.md`・`state.json`。このリポジトリでは git 管理外)
- 子エージェントとして実装を依頼された場合は、タスクの受け入れ基準を満たし、テストを実行してから
  完了報告すること。一時ファイル・管理ファイルの扱いはプロンプトの「実装ルール」に従う
- 親エージェントは、ルートを編集したら `CONTRIBUTING.md` の「skill・スクリプトを編集した後の同期」の手順でミラーを更新する
