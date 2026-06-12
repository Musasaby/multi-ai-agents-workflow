# 計画: git subtree による配布・更新方式への再編

## 背景・目的

このリポジトリは現在「ファイルを手作業でコピー」して他リポジトリへ導入するテンプレートだが、
導入後に本リポジトリ側の更新(skill改善等)を利用先へ取り込む手段がない。
git subtree(`--squash`)を配布手段とし、導入1コマンド・更新1コマンドを実現する。

親エージェントを Claude Code に限定しない(OpenCode 等でも動作する)ため、
Claude Code プラグイン方式ではなく subtree 方式を採用する。

## 設計の要点

- **このリポジトリのルート構成 = 利用先の `.agents/skills/` に取り込まれる中身そのもの**に再編する
  (subtree はリモートのサブディレクトリだけを取り込めないため)
- **状態・設定(利用先の `.agents/workflow/` 配下、`AGENTS.md`)は subtree の prefix 外**に置き、更新で上書きされない
- 利用先が独自 skill を `.agents/skills/` に追加しても subtree merge はローカル固有ファイルを保持するため共存可能
- 導入コマンド: `git subtree add --prefix=.agents/skills <URL> main --squash`
- 更新コマンド: `git subtree pull --prefix=.agents/skills <URL> main --squash`(`/workflow-update` skill でラップ)

## 目標構造(このリポジトリのルート)

```
agent-workflow/SKILL.md
agent-task-plan/SKILL.md
agent-dispatch/SKILL.md
agent-review-commit/SKILL.md
agents-md-setup/SKILL.md
workflow-update/SKILL.md      # 新規
_templates/
  AGENTS.md                   # 利用先用テンプレート(現ルートの AGENTS.md を移動・調整)
  CLAUDE.md                   # @AGENTS.md ラッパー
  workflow/config.json        # 現 .agents/workflow/config.json を移動
  workflow/README.md          # 現 .agents/workflow/README.md を移動
README.md                     # 導入・更新手順に全面更新
.gitignore
```

## 実装フェーズ

### Phase 1: リポジトリ構造の再編

- `.agents/skills/*` の5 skill ディレクトリをルート直下へ `git mv`
- ルートの `AGENTS.md` / `CLAUDE.md` を `_templates/` へ移動
- `.agents/workflow/config.json` / `README.md` を `_templates/workflow/` へ移動
- skill 本文中の `.agents/workflow/` 参照は利用先リポジトリ上のパスなので変更しない
- 本リポジトリ自身の開発でも skill を使えるよう、必要なら `.claude` 等の扱いを README に注記

### Phase 2: `agents-md-setup` の拡張(初期化の一本化)

既存の役割(CLAUDE.md ラッパー、`.claude` リンク、.gitignore、検証)に加え、
同 skill ディレクトリから見た `_templates/`(`../_templates/`)からのスキャフォールドを追加:

- `AGENTS.md`: なければテンプレートから作成。既存があれば「マルチエージェントワークフロー」節の追記のみ提案
- `.agents/workflow/config.json` / `README.md`: **既存があれば上書きしない**
- `.gitignore` エントリは現行どおり

### Phase 3: `workflow-update` skill の新設

- `git subtree pull --prefix=.agents/skills <URL> main --squash` を実行する skill
- リモートURLのデフォルトを skill 内に記載し、`.agents/workflow/config.json` の `upstream` キーで上書き可能にする
- 実行前に作業ツリーがクリーンであることを確認(subtree pull の前提)
- コンフリクト時はローカル改変との衝突箇所を提示してユーザーに対処を仰ぐ

### Phase 4: ドキュメント整備

- `README.md` 全面更新: 導入手順(subtree add → `/agents-md-setup`)、更新手順(`/workflow-update`)、
  コピー方式からの移行手順、vendored skill を直接編集しない運用ルール、submodule 代替の注意点、git バージョン要件
- `_templates/AGENTS.md` の「セットアップ」節に subtree 由来であることと更新方法を追記

### Phase 5: 検証

- テスト用の一時リポジトリで: `git subtree add`(ローカルパスをURLとして使用)→ `agents-md-setup` 手順 → skill 認識確認
- 本リポジトリ側で skill を1行変更 → テストリポジトリで subtree pull → 変更が取り込まれ、
  `.agents/workflow/` 配下の状態ファイルが無傷であることを確認

## リスク

- 利用先が vendored skill を直接編集すると pull 時にコンフリクト → README で運用ルールを明記
- `--squash` でも更新ごとに merge コミットが増える(許容)
- 旧コピー方式の導入先はローカル改変の差分確認が必要(移行手順に記載)

## 受け入れ条件(全体)

- 新規リポジトリに subtree add + setup だけでワークフローが動作する(skill が認識される)
- 本リポジトリの更新が subtree pull で利用先に反映され、利用先の状態・設定が保持される
