# AGENTS.md

このファイルはすべてのAIエージェント(Claude Code、OpenCode等)向け指示の**正本**です。
`CLAUDE.md` はこのファイルをimportする1行ラッパーであり、内容はここにのみ記載します。

## プロジェクト概要

<!-- このセクションをプロジェクトに合わせて書き換えてください -->

- プロジェクト名: 
- 技術スタック: 
- 主要ディレクトリ:
  - `src/` または `Source/` — ソースコード
  - `docs/` — ドキュメント
  - その他プロジェクト固有のディレクトリ

## エージェント共通ルール

- 回答・コミットメッセージ・ドキュメントは日本語で記述する(コード識別子は除く)
- コミットは conventional commits 形式: `<type>: <description>`(type: feat, fix, refactor, docs, test, chore, perf, ci)
- `main` ブランチへの直接コミットは禁止。作業は `develop/<作業名>` ブランチで行う
- 実装後は関連テストを実行し、結果を報告する

## マルチエージェントワークフロー

複数エージェント協調の実装ワークフローは `.agents/skills/` の各skillで定義されている。

- 状態・設定の正本: `.agents/workflow/`(`config.json`, `tasks.md`, `state.json`)
- 子エージェントとして実装を依頼された場合は、タスク定義(`.agents/workflow/tasks.md`)の受け入れ基準を満たし、テストを実行してから完了報告すること
- 理解確認(任意): `comprehension_check.enabled` が true の場合、各タスク完了後に質問ファイルが生成されます。回答を記入して `/agent-comprehension-check` を実行すると判定・解説が得られます(別セッションでも可)
- 問題発生時の対応順序: 1) `multi-ai-agents-workflow` 由来の問題かを切り分け 2) スクリプトによる自動化などAIの性能に依存しない機械的改善を最優先で検討 3) 2 が難しい場合のみ skills/AGENTS.md 等ドキュメントの改善で対処 4) ワークフロー由来、または解決困難な場合はユーザーに報告して中断(詳細は `agent-workflow` skillの「問題発生時の対応順序」を参照)

## セットアップ(clone直後)

リンク類(`.claude` ジャンクション等)はリポジトリにコミットされない。clone後に
`/agents-md-setup` skillを実行するか、`.agents/skills/agents-md-setup/SKILL.md` の手順でリンクを再作成すること。

`.agents/skills/` は `git subtree` で取り込んだ配布物です。更新が必要な場合は `workflow-update` skill を実行するか、`git subtree pull` で取り込んでください。配布元の skill は直接編集せず、利用先固有の変更が必要な場合は別名ディレクトリで追加してください。
