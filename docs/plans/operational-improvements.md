# 計画: 運用フィードバックに基づくワークフロー改善(2026-07)

## 背景・目的

利用先プロジェクト(Linux / Windows)での実運用で以下の問題が確認された。
本計画はこれらを解消し、あわせて再発防止の運用方針を明文化する。

1. 子エージェントが `claude`(`claude -p`)のとき、実行中のログが逐次確認できない
2. 親エージェントの出力が極端に少なくなる・英語になることがある
3. コミット対象があいまい(`.agents/scheduled_tasks.lock` の扱い、state.json/tasks.md のコミットタイミング)
4. ブランチ運用があいまい(同一タスクファイル内での作業単位ブランチ分割が未定義)

### 方針(ユーザー確認済み)

- ログ問題は **stream-json 化+ラッパースクリプトでの整形** で対処する
- ブランチ分割は **親の裁量(ドキュメントで推奨を明文化するのみ)** とし、state.json の設計変更はしない

### 改善の優先順位ポリシー(本計画自体にも適用)

タスク実行中に再発しうる問題が発生した場合の対応順序:

1. multi-ai-agents-workflow 由来の問題かを切り分ける
2. スクリプトによる自動化など、**AIの性能に影響されない機械的な改善**を最優先で検討する
3. 2 が難しい場合のみ skills / AGENTS.md / その他ドキュメントの改善で対処する
4. 1 が yes(本ワークフロー由来)または解決困難な場合は、ユーザーに報告して中断する

このポリシー自体もワークフローに明文化する(T2)。

## 問題分析

### 1. claude -p のログが逐次確認できない

`claude -p` はデフォルト(`--output-format text`)では**最終結果のみを終了時に出力する**
バッファリング動作のため、`output.log` を `tail -f` / `Get-Content -Wait` しても
実行中は何も見えない。OS は無関係(Linux でも Windows でも同じ)。

`--output-format stream-json --verbose` を付けると、ターンごとの JSON 行
(JSON Lines)が逐次 stdout に流れる。ただし生の JSON 行は人が読みにくい。

→ **対処**: コマンドテンプレートに stream-json を推奨し、ラッパースクリプト
(`dispatch-run.ps1` / `.sh`)側で JSON 行を人が読めるテキストに整形して
`output.log` に書き出す。生 JSON も別ファイルに残す(事後調査用)。

### 2. 親エージェントの出力減少・英語化

再現ログでは、AGENTS.md に「回答は日本語で記述する」があるにもかかわらず
コミット操作の合間の説明が英語になった。原因はモデル切り替えやコンテキスト圧縮で
AGENTS.md の指示の効きが弱まったことと推定され、**機械的な強制は不可能**
(LLM の出力言語はスクリプトで制御できない)。

→ 優先順位ポリシーのレベル3(ドキュメント改善)で対処: skill 本文は
呼び出しのたびにコンテキストへ読み込まれ AGENTS.md より効きが強いため、
各 skill の「ユーザーへの報告」に日本語指定と最低限の報告項目を明記する。

### 3. コミット対象があいまい

- `.agents/scheduled_tasks.lock` は中身が `{"sessionId":..., "pid":..., "acquiredAt":...}` の
  **Claude Code 本体(ハーネス)のランタイムロックファイル**。本ワークフローの
  生成物ではなく、コミット対象外。利用先では `.agents/` がコミット対象のため
  untracked として残り続け、混乱の原因になっている
- state.json / tasks.md はタスク完了で毎回変化するが、コミットタイミングが
  どの skill にも書かれていない。実運用では放置され「コミットして」と
  ユーザーが都度指示する状態だった

→ **対処**: 利用先 `.gitignore` にロックファイルを追加する手順を
`agents-md-setup` に組み込む。state.json 等は**タスク終了時(done 更新直後)に
chore コミット**するよう `agent-review-commit` に明記する。

### 4. ブランチ運用があいまい

実運用では `develop/remodel-M` → `develop/remodel-L` のように作業グループごとに
ブランチ+PR を切る運用が自然発生したが、skill 上は未定義のため、
state.json の `branch` と実ブランチの不一致(`remodel-M` のまま `remodel-L` で作業)や
コミット先の迷いが生じた。

→ **対処**: 親の裁量とし、「意味的まとまりごとにブランチを分けることを推奨」
「ブランチ切替時の手順(state.json の branch 更新+コミット)」をドキュメントに明文化する。

## 実装タスク

### T1: dispatch-run の stream-json 整形対応

- **目的**: `claude -p` 子エージェントのログを実行中に逐次閲覧可能にする
- **対象**:
  - `_templates/workflow/scripts/dispatch-run.ps1` / `dispatch-run.sh`
  - `_templates/workflow/config.json`(コメント不可のため README 側に記載)
  - `_templates/workflow/README.md`(command_template の claude 用設定例)
  - `agent-dispatch/SKILL.md`(§3 の閲覧コマンド提示、claude 利用時の注記)
- **設計**:
  - command_template に `stream-json` が含まれる場合のみ整形モードに分岐する(機械的判定)
  - 整形モード時: 子 CLI の stdout を1行ずつ読み、`output.jsonl`(生)へ追記しつつ、
    JSON をパースして人が読めるテキスト(assistant テキスト、ツール名+要約、result 等)を
    `output.log` へ逐次書き出す。パース不能行はそのまま `output.log` へ通す
  - 非 stream-json(OpenCode 等)は従来どおり `output.log` へ直書き(後方互換)
  - `.sh` 版の整形は `python3` で行う(既存の `state-sync.sh` と同じ依存)
  - claude 用テンプレート例: `claude -p "{prompt}" --output-format stream-json --verbose`
- **受け入れ基準**:
  - [ ] stream-json モードで `output.log` が実行中に逐次更新され、`tail -f` で閲覧できる
  - [ ] 生 JSON が `output.jsonl` に残る
  - [ ] OpenCode 等の従来テンプレートの動作が変わらない(リグレッションなし)
  - [ ] `done` マーカーの仕様(EXIT/END の2行)は不変
  - [ ] README に claude 用 command_template 例と注意点(text 出力はバッファリングされる)が記載される
- **依存**: なし

### T2: 改善優先順位ポリシーとトラブル対応の明文化

- **目的**: 問題発生時の対応順序(切り分け→機械的改善→ドキュメント改善→エスカレーション)を正本化する
- **対象**: `agent-workflow/SKILL.md`(エスカレーション基準の節の前後)、`_templates/AGENTS.md`
- **受け入れ基準**:
  - [ ] agent-workflow に「問題発生時の対応順序」節が追加され、上記4段階が記載される
  - [ ] ワークフロー由来かつ解決困難な場合は中断してユーザー報告、が明記される
- **依存**: なし

### T3: 親エージェントの報告フォーマット強化(日本語・最低報告項目)

- **目的**: 出力の極端な減少・英語化の再発を抑える
- **対象**: `agent-dispatch/SKILL.md`、`agent-review-commit/SKILL.md`、`agent-workflow/SKILL.md`
- **設計**: 各 skill に「ユーザーへの報告」節を設け、以下を明記する:
  - 報告・説明はすべて日本語(AGENTS.md の再掲。skill 本文は毎回読み込まれるため効きが強い)
  - フェーズ完了ごとに最低限報告する項目(例: dispatch 起動報告=タスクID・ログパス・閲覧コマンド、
    レビュー結果=合否・指摘件数・コミットハッシュ)
- **受け入れ基準**:
  - [ ] 3つの skill に日本語指定と最低報告項目が明記される
- **依存**: なし

### T4: コミット対象ポリシーの明確化

- **目的**: `.agents/scheduled_tasks.lock` の扱いと state.json 等のコミットタイミングを定義する
- **対象**:
  - `agents-md-setup/SKILL.md`: セットアップ手順に利用先 `.gitignore` へ
    `.agents/scheduled_tasks.lock`(および既存の `runs/`・`.config/` の ignore 確認)を
    追記するステップを追加。既存利用先向けに workflow-update 後の案内にも記載
  - `agent-review-commit/SKILL.md` 手順5: タスクコミット後、state.json の done 更新・
    tasks.md・comprehension ファイル等の**ワークフロー状態変更をまとめて
    `chore: <タスクID> の進捗状態を更新` としてコミットする**ステップを追加
    (タスク終了時にまとめてコミットする方式。ユーザー合意済み)
  - `agent-workflow/SKILL.md` 完了サマリー: `git status` がクリーンであることの確認を追加
    (コミット漏れ・想定外の untracked があればユーザーに報告)
- **受け入れ基準**:
  - [ ] agents-md-setup に .gitignore 追記手順が入る(ロックファイルは「Claude Code 本体の
        ランタイムファイルでありコミット対象外」という説明つき)
  - [ ] review-commit にワークフロー状態の chore コミット手順が入る(コミットハッシュ記録の
        都合上、タスク本体コミットとは別コミットになる旨を明記)
  - [ ] agent-workflow の完了サマリーに git status クリーン確認が入る
- **依存**: なし

### T5: ブランチ運用の推奨明文化(親の裁量)

- **目的**: 同一タスクファイル内でも意味的まとまりごとのブランチ分割を推奨として定義する
- **対象**: `agent-workflow/SKILL.md`(前提・フローの節)、`agent-task-plan/SKILL.md`
- **設計**(機械的強制はしない。state.json のスキーマは変更しない):
  - task-plan 時: タスクを意味的まとまり(機能グループ)で並べ、グループ境界を
    tasks.md 上で意識できるようにする(依存関係の記述で十分な場合はそのまま)
  - ブランチ分割の推奨: グループの区切りで PR を作成しマージ後、次グループは
    最新 main から新しい `develop/*` ブランチを作成する
  - ブランチ切替手順: 切替前に未コミット変更がないこと(T4 の chore コミット済み)を確認し、
    切替後に state.json の `branch` を現在ブランチへ更新して chore コミットに含める
    (`branch` フィールドの意味を「現在の作業ブランチ」と README で明確化)
- **受け入れ基準**:
  - [ ] agent-workflow にブランチ分割の推奨と切替手順が記載される
  - [ ] `_templates/workflow/README.md` の state.json 説明で `branch` の意味が明確化される
- **依存**: T4(chore コミット手順を前提にするため)

### T6: 利用先への反映(workflow-update での取り込み確認)

- **目的**: 本改善を利用先プロジェクトへ配布し、実タスクで検証する
- **対象**: 利用先リポジトリ(subtree 取り込み+ラッパースクリプトの更新コピー)
- **注意**: ラッパースクリプトは「既存を上書きしない」方針のため、利用先で
  カスタマイズしていない場合は明示的に新テンプレートをコピーし直す必要がある。
  workflow-update 実行後の案内にこの点を含める(T1 の対象に含めてもよい)
- **受け入れ基準**:
  - [ ] 利用先で claude -p 子エージェントの1タスクを実行し、ログが逐次閲覧できる
  - [ ] タスク終了時に state.json 等が chore コミットされ、untracked が残らない
- **依存**: T1〜T5

## 検証方法

- 本リポジトリ上でのドライラン: ダミータスクで `dispatch-run` を
  stream-json テンプレート/従来テンプレートの両方で起動し、`output.log` の
  逐次更新と `done` マーカーを確認する(子 CLI はモックの echo スクリプトでも可)
- Linux 検証は `.sh` 版を WSL または利用先環境で実施する

## スコープ外

- state.json のスキーマ変更(グループ/ブランチのタスク紐付け)— 親の裁量方針のため不要
- 親エージェントの出力言語の機械的強制 — LLM 出力は制御不能(レベル3対応のみ)
- Claude Code ハーネス側の `scheduled_tasks.lock` の生成抑止 — 本ワークフローの管轄外
