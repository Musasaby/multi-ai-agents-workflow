# Codex検証で判明した問題の修正計画

## 背景

Codex上で `agent-workflow` skill の実運用検証を行った結果、skill自体の認識・読込は
成功したが、以下3点の問題が判明した(2026-06-12)。

1. `.claude` が `.agents` へのリンクではなく実体ディレクトリで、`agents-md-setup`
   の検証条件と不一致(本リポジトリは開発元のため、`.claude/skills/*` がルート直下の
   開発用skillディレクトリへのシンボリックリンクという独自構成だった)
2. 子エージェントCLI `opencode run` が Codex 環境では
   `EEXIST: file already exists, mkdir 'C:\Users\0127K\.config\opencode'` で失敗。
   ローカル(Claude Code)環境では `opencode --version` は正常に 1.17.3 を返すため、
   サンドボックスによるホームディレクトリ書込制限が原因の可能性が高い
3. `claude -p ... --max-turns 1` によるskill認識検証が60秒でタイムアウト。
   `claude -p` の初回コールドスタートは60秒を超えることが普通にあり、検証手順側の問題

## 決定事項(ユーザー承認済み)

- `.claude` は標準形(`.agents` へのジャンクション)に揃える。これにより本リポジトリでの
  skill開発時に「ルートで編集 → subtree反映までClaude Codeに反映されない」不便が
  生じるが、**許容する**(配布形態そのものを常にテストできる利点を優先)
- `claude -p` 検証のタイムアウト目安は **3分** とする

## 修正1: `.claude` 構成を標準形(ジャンクション)に揃える

1. 現在の `.claude` 実体ディレクトリの中身を確認:
   - `.claude/settings.local.json` 固有の許可エントリ(`"Bash(opencode --version)"`)を
     `.agents/settings.local.json` にマージ
   - `.claude/skills/*` のシンボリックリンク群は破棄してよい(subtree側に同内容がある)
2. `.claude` を削除し、`New-Item -ItemType Junction -Path .claude -Target .agents`
   でジャンクションを作成(シンボリックリンク優先・権限エラー時ジャンクションの
   既存フォールバック手順に従う)
3. 副作用への手当て: 開発時にルートのskill編集を即時反映したい場合の手順
   (subtree同期 or 一時的な手動コピー)を `docs/` の開発者向けメモに1節追記

## 修正2: 子エージェントCLIのプリフライトとサンドボックス対策

1. `agent-dispatch/SKILL.md` にプリフライト手順を追加:
   - dispatch前に子エージェントCLIの疎通確認(例: `opencode --version`)を実行
   - 失敗時はエラー内容を添えて中断・ユーザーへ報告(無言で全タスク失敗するのを防ぐ)
2. EEXIST系エラー時の対処を記載:
   - `~/.config/opencode` の権限・サンドボックス書込制限の確認
   - 回避策: `XDG_CONFIG_HOME` をプロジェクト内(例: `.agents/workflow/.config`)に
     向けて起動する方法
3. Codex等サンドボックス環境での実行注意点(ホームディレクトリへの書込許可が必要)を
   `docs/` または README に追記

## 修正3: agents-md-setup の検証手順の堅牢化

1. `agents-md-setup/SKILL.md` の検証手順を「ファイルベース(必須)→ CLI実行(任意)」の
   2段構成に変更:
   - ファイルベース検証: `.claude/skills/**/SKILL.md` がリンク経由で解決でき、
     frontmatter の `name` が列挙できればskill認識相当とみなす
   - CLI検証(任意・時間がある場合): `claude -p` による実認識確認
2. `claude -p` 検証にタイムアウト目安 **3分** を明記(初回コールドスタートは60秒を
   超えうる。60秒で打ち切らないこと)

## 作業順序と完了条件

1. 修正1(ローカル構成の修復)
2. 修正3(`agents-md-setup/SKILL.md` 改善)
3. 修正2(`agent-dispatch/SKILL.md` 改善 + docs追記)
4. ルートで編集したskillをsubtree側(`.agents/skills/`)へ反映(既存のsquash mergeフロー)
5. 改善後の agents-md-setup 検証手順(ファイルベース必須+CLI任意)で自己検証して完了

## 制約・注意

- ルート直下の `agents-md-setup/`, `agent-dispatch/` 等が編集の正本。
  `.agents/skills/` はsubtreeなので直接編集しない(手順4で反映する)
- `.claude` の削除を伴う操作は修正1のみ。`.gitignore` により `.claude` は未追跡のため
  git履歴への影響はない
- 子エージェントが `.claude` ジャンクション操作を行うとWindowsの権限・サンドボックス
  制約で失敗しやすい点に留意(必要なら親が直接実行する)
