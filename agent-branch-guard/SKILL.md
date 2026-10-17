---
name: agent-branch-guard
description: マルチエージェント実装ワークフローで、tasks.md のタスク実行(/agent-workflow・/agent-dispatch・/agent-review-commit)以外の変更やコミットを伴う依頼を受けたときに、作業に着手する前に必ず使う。`.agents/workflow/state.json` があるリポジトリ前提。該当する依頼の例: タスクの追加・計画の変更・ワークフロー外のバグ修正・ドキュメントや設定の変更。branch-check スクリプトでブランチを判定し、main やマージ済みブランチ上での誤コミットを防ぐ。
---

# ブランチガード(ワークフロー外の作業のブランチ判定)

tasks.md のタスク実行**以外**の依頼(タスクの追加・計画の変更・ワークフロー外の修正・
ドキュメントや設定の変更など、ファイルを変更してコミットしうる作業)を受けたとき、
作業に着手する**前に**現在のブランチが作業に使ってよいかを判定し、必要なら
専用ブランチの作成を提案する。`main` やマージ済みの作業ブランチ上でコミットして
しまうのを防ぐのが目的。

skill 名の指定がなくても発動するように、AGENTS.md の「マルチエージェントワークフロー」節に
同じ規則がある(description だけに頼らない2段構えで、AGENTS.md 側が常に読まれる)。

## 手順

1. `branch-check`(`--state` / `-State` **なし**。読み取り専用)を実行する。
   `.agents/workflow/scripts/` 配下に実体がある:
   ```powershell
   .agents/workflow/scripts/branch-check.ps1
   ```
   ```bash
   .agents/workflow/scripts/branch-check.sh
   ```
   exit code と対応は `_templates/workflow/README.md` の `branch-check` の節と一致する。
   **この skill では `--state` を付けないため、exit 5 は出ない**(exit 5 は
   state.json の `branch` との不一致判定で、タスク実行側の `agent-dispatch` が対象)。

2. exit code で分岐する:

   - **`Next: continue`**(exit 0。stdout `OK <ブランチ>`)→ 判定に問題なし。そのまま依頼の作業に進む
   - **`Next: switch-branch reason=main`**(exit 2。`main` 上)または
     **`Next: switch-branch reason=merged`**(exit 3。stdout `MERGED <PR URL>`。PR がマージ済み)→
     作業を始めず、利用者に提案する:
     - `git fetch origin` の後、最新の main(`origin/main`)から専用ブランチ
       `develop/<作業名>-plan` を切ることを提案する。config.json の `upstream.branch` が
       設定されている場合は `main` の代わりにその名前を使う
     - `develop` という名前のブランチが既にあると、git の仕様で `develop/...` を作れない。
       その場合だけ `develop-<作業名>` を使う
     - **承認後に** `git switch -c develop/<作業名>-plan origin/main` で作成してから
       作業を始める(承認なく作らない)
     - 作業ツリーに未コミット変更(`git status --porcelain` が空でない)がある場合は、
       切替前にその扱い(残す・退避(stash)・破棄 等)を利用者に確認する
   - **`Next: escalate reason=gh-unavailable`**(exit 4。gh が無い・認証切れ等で
     PR 状態を取得できない)→ 判定できない旨を利用者に伝え、このまま続行してよいか確認する。
     続行の承認があれば進む
   - **`Next:` 行なし**(exit 1。使い方不備・git の失敗。detached HEAD を含む)→
     スクリプトの stderr の内容を添えて利用者に報告し、作業を中断する

3. 新ブランチに移った後の state.json の扱い:

   - `agent-task-plan` の追加モードで tasks.md にタスクを追記した後 `state-sync`(追記同期、
     `--init` なし)を実行すると、**state.json の `branch` は git から更新されない**
     (既存の値を引き継ぐだけ。README の state-sync の記載とスクリプト実装の両方で確認済み)。
     新ブランチに切替後も state.json の `branch` が古いブランチのままになる
   - その結果、scripts の後続判定(`branch-check --state` → exit 5、`dispatch-prompt-gen` の
     PR モード 等)が古い branch を参照して不整合が起きうる。**対処**: ブランチを切った後に
     state.json を更新する手順がスクリプトに存在しない点(`group-advance` はグループ
     切替専用)をこの skill の利用者に明示し、利用者の承認を得て state.json の `branch` を
     新ブランチ名に直接編集するか、ワークフロー外の軽微な作業なら state.json を
     更新しない方針を明示して続行する(後続のタスク実行前に `state.json` の `branch` と
     実際のブランチを確認するのを推奨)

## 備考

- `branch-check` は読み取り専用で、何も書き換えない
- 判定順と stdout メッセージ: `OK <ブランチ>`(exit 0)、`MERGED <PR URL>`(exit 3)
- exit code の一覧: `0`=使ってよい、`1`=使い方不備・git 失敗、`2`=`main` 上、
  `3`=PR マージ済み、`4`=gh で判定できない、`5`=state.json の `branch` と不一致
  (この skill では `--state` を付けないため出ない)
