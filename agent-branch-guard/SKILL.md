---
name: agent-branch-guard
description: "マルチエージェント実装ワークフローで、tasks.md のタスク実行(/agent-workflow・/agent-dispatch・/agent-review-commit)以外の変更やコミットを伴う依頼を受けたときに、作業に着手する前に必ず使う。`.agents/workflow/state.json` があるリポジトリ前提。該当する依頼の例: タスクの追加・計画の変更・ワークフロー外のバグ修正・ドキュメントや設定の変更。branch-check スクリプトでブランチを判定し、main やマージ済みブランチ上での誤コミットを防ぐ。"
---

# ブランチガード(ワークフロー外の作業のブランチ判定)

tasks.md のタスク実行**以外**の依頼(タスクの追加・計画の変更・ワークフロー外の修正・
ドキュメントや設定の変更など、ファイルを変更してコミットしうる作業)を受けたとき、
作業に着手する**前に**現在のブランチが作業に使ってよいかを判定し、必要なら
専用ブランチの作成を提案する。`main` やマージ済みの作業ブランチ上でコミットして
しまうのを防ぐのが目的。

skill 名の指定がなくても発動するように、AGENTS.md の「マルチエージェントワークフロー」節に
同じ規則がある(description だけに頼らない2段構えで、AGENTS.md 側が常に読まれる)。

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.sh` を `.ps1` にし、`--set-branch` のようなオプションを `-SetBranch` の形の名前付き引数に読み替える。

## 手順

1. `branch-check`(`--state` **なし**。読み取り専用)を実行する。
   `.agents/workflow/scripts/` 配下に実体がある:
   ```bash
   .agents/workflow/scripts/branch-check.sh
   ```
   exit code と stdout の仕様は `agents-md-setup/templates/workflow/README.md` の `branch-check` の節を参照する。
   **この skill では `--state` を付けないため、`Next: escalate reason=state-branch-mismatch` は出ない**(これは
   state.json の `branch` との不一致判定で、タスク実行側の `agent-dispatch` が対象)。

2. 出力の最後の `Next:` 行で分岐する:

   - **`Next: continue`** → 判定に問題なし。そのまま依頼の作業に進む
   - **`Next: switch-branch reason=main`**(`main` 上)または
     **`Next: switch-branch reason=merged`**(PR がマージ済み。stdout に `MERGED <PR URL>`)→
     作業を始めず、利用者に提案する:
     - `git fetch origin` の後、最新の main(`origin/main`)から専用ブランチ
       `develop/<作業名>-plan` を切ることを提案する。config.json の `base_branch` が
       設定されている場合は `main` の代わりにその名前を使う
     - ブランチ名は config.json の `branch_prefixes`(既定 `develop/`・`develop-`)のどれかで
       始める。そうでないと `state-sync --set-branch` が exit 1 にする
     - `develop` という名前のブランチが既にあると、git の仕様で `develop/...` を作れない。
       その場合だけ `develop-<作業名>` を使う
     - **承認後に** `git switch -c develop/<作業名>-plan origin/main` で作成してから
       作業を始める(`base_branch` があれば `origin/<base_branch>` から切る。承認なく作らない)
     - 作業ツリーに未コミット変更(`git status --porcelain` が空でない)がある場合は、
       切替前にその扱い(残す・退避(stash)・破棄 等)を利用者に確認する
   - **`Next: escalate reason=gh-unavailable`**(gh が無い・認証切れ等で
     PR 状態を取得できない)→ 判定できない旨を利用者に伝え、このまま続行してよいか確認する。
     続行の承認があれば進む
   - **`Next:` 行なし**(使い方不備・git の失敗。detached HEAD を含む)→
     スクリプトの stderr の内容を添えて利用者に報告し、作業を中断する

3. 新ブランチに移った後の state.json の扱い:

   - 新ブランチに移った後(state.json があるとき)は、`.agents/workflow/scripts/state-sync.sh --set-branch`
     を実行して state.json の `branch` を現在の
     ブランチにする。state.json が追跡されている場合は、この変更を作業のコミットに含める

## 備考

- `branch-check` は読み取り専用で、何も書き換えない
