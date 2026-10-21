# multi-ai-agents-workflow

AIエージェント(Claude Code、OpenCode 等)による複数エージェント協調の実装ワークフローを、任意のプロジェクトに `npx skills add` で導入できる配布物です。

## 概要

2種類のエージェントが役割を分けて実装を進めます。

- **親エージェント**(Claude Code・Codex 等): 利用者と対話します。計画のタスク分解、子への依頼、レビュー、コミット、PR 作成を行います
- **子エージェント**(opencode・`claude -p` 等の CLI): 親から1タスクずつ依頼を受けて実装し、テストを実行して完了報告を書きます

```
1. 計画参照・タスク分解   → 親: /agent-task-plan
2. 各タスクを順次実行:
   a. 実装dispatch        → 親が依頼し、子が実装・テスト実行・完了報告(/agent-dispatch)
   b. レビュー・コミット  → 親: /agent-review-commit
      - 合格時、verify_before_commit 有効なら最終ゲート → 親: /agent-quality-gate
        (FAIL(blocking) なら修正再依頼に戻る)
      - config有効時、合格時に質問ファイルを生成
3. 全タスク完了 → 親: サマリー報告(未回答の質問一覧含む)
```

理解確認(任意・デフォルト無効): 質問ファイルに回答後、`/agent-comprehension-check` で判定・解説を依頼できます(別セッション可)。

状態は `.agents/workflow/` の `tasks.md`(タスク定義)と `state.json`(進捗)に残ります。中断しても、`/agent-workflow` を引数なしで実行し直せば未完了のタスクから再開できます。

## 含まれる skill

| ディレクトリ | 説明 |
|---|---|
| `agent-workflow/` | 全体オーケストレーター(中断再開対応) |
| `agent-task-plan/` | 計画→タスク分解 |
| `agent-dispatch/` | 子エージェントへの実装指示・テスト実行 |
| `agent-quality-gate/` | 品質ゲート(typecheck/lint/test)の設定駆動一括実行・合否報告 |
| `agent-comprehension-check/` | 回答済み質問ファイルの判定・解説(別セッション対応) |
| `agent-review-commit/` | レビュー・修正再依頼・コミット |
| `agent-branch-guard/` | ワークフロー外の変更・コミットを伴う依頼のブランチ判定(branch-check) |
| `agents-md-setup/` | 正本化セットアップとリンク検証。`templates/` に利用先用テンプレート(`AGENTS.md`・`CLAUDE.md`・`workflow/` の config.json・README.md・scripts) |
| `workflow-update/` | `npx skills update` 後の確認と配置済みスクリプトの更新支援 |

`npx skills` が配るのは `SKILL.md` を持つディレクトリだけで、`tests/`・`docs/`・`AGENTS.md` は利用先に入りません。

## 前提

- プロジェクトは Git 管理されていること
- Node.js 22.20 以上(`npx skills` の要件。導入・更新のときだけ使う)
- `main` への直接コミットはしない。作業は `develop/<作業名>` ブランチで行う。`branch-check` は `main`(と `base_branch`)の上での作業を止め、`state-sync --set-branch` と `group-advance` は `develop/` で始まらないブランチ名を受け付けない
- 子CLI(既定は opencode)が使えること

## クイックスタート

1. 利用先プロジェクトのルートで以下を実行:
   ```bash
   npx skills add Musasaby/multi-ai-agents-workflow --skill '*' -a universal -y
   ```
   - `--skill '*'` で全 skill を入れます(このワークフローは全 skill が揃っている前提です)
   - `-a universal` で `.agents/skills/<name>/` にコピーで置かれます(symlink を作らないので Windows でも `--copy` は不要です)
   - ルートの `skills-lock.json` と `.agents/skills/` をコミットします(clone した人は Node.js なしで使えます)
   - `-a claude-code` は指定しません(`/agents-md-setup` が `.claude` を `.agents` へのリンクにするので、Claude Code からも同じ skill が見えます)
2. `/agents-md-setup` を実行して、テンプレートから `AGENTS.md`・`CLAUDE.md`・`.agents/workflow/` 設定を非破壊でスキャフォールドし、`.claude` リンクを作成・検証します
3. `AGENTS.md` の「プロジェクト概要」と「テスト・検証の注意(子エージェント向け)」をプロジェクトに合わせて書きます
4. `.agents/workflow/config.json` の `child_agent.command_template` で子CLIを決めます。既定は `opencode run "{prompt}"` です。Claude Code など他の CLI の設定例は [agents-md-setup/references/parent-child.md](agents-md-setup/references/parent-child.md) を参照してください
5. `test_command` と `quality_gate.steps` の `command` に、プロジェクトのテスト・型検査・lint のコマンドを書きます。設定キーの一覧は [config.json 節](agents-md-setup/templates/workflow/README.md) を参照してください
6. `develop/<作業名>` ブランチを作り、`skills-lock.json`・`.agents/skills/`・`.agents/workflow/`・`AGENTS.md`・`CLAUDE.md`・`.gitignore`・`.gitattributes` をコミットします
7. `/agent-workflow <Issue 番号または計画ドキュメントのパス>` を実行します。親がタスク分解を示して承認を求めるので、確かめて承認すると、子への依頼・レビュー・コミットがタスクごとに進みます

### `.agents/skills/` がすでにある場合

既存の skill はそのまま残り、配布物と同じディレクトリに共存します(配布物と名前が重ならないこと)。

その後はクイックスタートの手順2以降(`/agents-md-setup` の実行など)を続けます。`.claude/skills/` に
skill ごとの個別リンクを置く旧構成になっている場合、`/agents-md-setup` は `.claude` を
`.agents` へのリンクに置き換えるよう提案します(既存の skill も引き続き `.claude/skills/` から見えます)。

## 更新手順

`workflow-update` skill を実行するか、手動で以下を実行して更新します。

```bash
npx skills update -p -y
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh
```

`.agents/workflow/scripts/` と `.agents/workflow/README.md` はセットアップ時のコピーのため、
`npx skills update` だけでは更新されません。`workflow-update.sh` で差分があれば、続けて以下で差分を確認・反映してください
(`workflow-update` skill はこの手順も実行します):

```bash
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh                 # 差分の一覧
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --copy-missing  # 未配置ファイルをコピー
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --overwrite <名前,...>  # 差分を確認して上書き
```

## git subtree からの移行手順

`.agents/skills/` を `git subtree` で取り込んでいる利用先で行います(`workflow-update` が `escalate reason=not-npx` を出した場合)。
subtree 時代の `workflow-update` が `escalate reason=sync-failed`
(`.agents/skills/_templates/workflow/scripts/workflow-sync-scripts.sh` が見つからない)で止まった場合も、この手順に進みます。
subtree で取り込んだ配布物を `.agents/skills/` から消してコミットし、`npx skills add` で導入し直し、
配置済みスクリプトとの差分を反映してコミットします。コマンドは bash と PowerShell で同じものが使えます。
利用先固有の skill は `.agents/skills/` に残ります。
`--overwrite` には、`workflow-update.sh` の `differs` 行に出た名前をカンマ区切りで渡します(`differs` が無ければその行は飛ばします)。

```bash
git -C .agents/skills rm -r -q --ignore-unmatch agent-branch-guard agent-comprehension-check agent-dispatch agent-quality-gate agent-review-commit agent-task-plan agent-workflow agents-md-setup workflow-update _templates tests docs AGENTS.md README.md .gitignore .gitattributes .github
git commit -m "chore: subtree で取り込んだ配布物を削除する(npx skills へ移行)"
npx skills add Musasaby/multi-ai-agents-workflow --skill '*' -a universal -y
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.sh
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --copy-missing
bash .agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --overwrite <workflow-update が differs と出した名前,...>
git add .agents/skills skills-lock.json .agents/workflow/scripts .agents/workflow/README.md
git commit -m "chore: npx skills で配布物を導入する"
```

## 運用ルール

- **配布元の skill**: `.agents/skills/` 以下の配布元 skill は直接編集しません(`npx skills update` で上書きされます)。変更が必要な場合は upstream リポジトリで行ってから `workflow-update` で取り込んでください
- **利用先固有 skill**: プロジェクト独自の skill は、配布物と重ならない名前のディレクトリで追加してください。`npx skills update` は `skills-lock.json` に記録された skill だけを更新するため、共存できます
- **submodule ではない**: `.agents/skills/` と `skills-lock.json` をコミットするので、clone 後の追加操作は `/agents-md-setup` だけです

## ユーザーへの報告と日本語の推敲

### 報告の形

- 親エージェントの報告は、`agent-workflow/references/report-template.md` の3点(状況・起きたこと・次にすること)の形で書きます。場面ごとの書き方も、このファイルにあります
- 進捗は、親が数えずに `workflow-status` で機械的に出します。完了時は `workflow-status --summary` の出力からサマリーを作ります

### yomiyasu による日本語の推敲(任意)

[yomiyasu](https://github.com/nanaism/yomiyasu) は、AI が書いた日本語を推敲する skill です。本リポジトリには**同梱しません**。理由は次の3つです。

1. SKILL.md が大きく、トークンを多く使うため
2. `yomiyasu_check.py` の実行に Python が要るため
3. 入れ方と skill の名前が、利用者ごとに違うため

有効にする手順:

1. `npx skills add nanaism/yomiyasu` などで yomiyasu を導入します
2. `.agents/workflow/config.json` の `text_refine.skill` に、入れ方に合う名前を書きます。名前は、親エージェントの skill 一覧に出る名前です
3. 必要なら `text_refine.targets`(推敲する場面)と `text_refine.reader`(想定する読み手)を変えます

入れ方と `text_refine.skill` の対応(yomiyasu の資料で分かっているもの):

| 入れ方 | `text_refine.skill` |
|--------|---------------------|
| Claude Code の `npx skills add` / `gh skill install` | `yomiyasu` |
| Claude Code のプラグイン | `yomiyasu:yomiyasu` |
| Codex | `yomiyasu:yomiyasu` |
| `npx openskills install` | `yomiyasu` |

それ以外のエージェントは、親の skill 一覧で名前を確かめてください。

推敲される場面は、次の6つです(`targets` の値)。

- `commit`: コミットメッセージの説明
- `task_done`: タスク1件が done になったときの報告
- `pr_body`: PR の説明
- `confirm`: 停止して判断を仰ぐときの報告
- `summary`: 完了時のサマリー
- `tasks`: agent-task-plan で書く tasks.md(要件・前提・解釈・対象外・目的欄・受け入れ基準の文)

次のものは推敲されません: 子へのプロンプト(prompt.md・fix-notes.md)、state.json などの管理ファイル、スクリプトの出力、コード、途中経過の報告。

`text_refine.skill` が未設定のまま yomiyasu を導入していると、推敲の場面で知らせが出ます。どのエージェント用に入れた場合も対象です(プロジェクトとホームの `*/skills/yomiyasu/`、Claude Code のプラグイン)。

## 開発者向け(本リポジトリの開発)

本リポジトリの `.claude` は `.agents` へのジャンクション(標準形)です。
skill の編集はリポジトリルート直下の各ディレクトリ(`agent-workflow/` 等)が正本です。

### `.agents/skills/` への同期(配布元リポジトリ固有の手順)

本リポジトリでは `.agents/` 配下は**未追跡**(ローカル実行状態。`.gitignore` で除外)です。
ルート直下で skill を編集したら、`.claude/skills` 経由の Claude Code 等に反映するため、
以下のコピーで `.agents/skills/` を同期します(git 操作・コミットは不要):

```powershell
# ルート直下の配布物を .agents/skills にコピー
$items = 'agent-workflow','agent-task-plan','agent-dispatch','agent-review-commit',
         'agent-comprehension-check','agent-quality-gate','agent-branch-guard','agents-md-setup','workflow-update'
foreach ($i in $items) {
  Remove-Item ".agents/skills/$i" -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item $i ".agents/skills/$i" -Recurse
}
Copy-Item README.md .agents/skills/README.md -Force
```

> **利用先との違い**: 利用先では `.agents/skills/` は `npx skills add` で配置して追跡しますが、
> 本リポジトリ(配布元)はルートが配布物そのもののため、`.agents/` はローカル実行用のコピーとして
> 未追跡で運用します(`npx skills` は使わず、上のコピーで同期します)。

### テスト

`agents-md-setup/templates/workflow/scripts/` のスクリプトは `tests/` のシナリオテストで検証します。
一時ディレクトリにダミーの利用先プロジェクトを作ってスクリプトを実行するため、
本リポジトリの `.agents/` には影響しません(gh への実アクセスもしません)。

```bash
# POSIX 版(bash + python3 + git)
bash tests/run-all.sh
```
```powershell
# PowerShell 版(pwsh 7 + git)
pwsh -NoProfile -File tests/run-all.ps1
```

`run-all` は各テストファイルを名前順に実行し、各ファイルの結果(PASS / FAIL と所要秒数)を
1 行ずつ出力します。最後に失敗したファイルの一覧を出し、1 本でも失敗すれば exit 1、
すべて成功なら exit 0 になります。

既定は直列実行ですが、`--jobs <N>`(`run-all.ps1` は `-Jobs <N>`)を付けると
テストファイル単位の並列実行になります。並列実行時も各ファイルの出力は混ぜず、
実行後にファイルごとにまとめて出します。

POSIX 版のシグナル終了のテスト(Python 経由の経路)は Linux でのみ実行されます(Windows ではスキップ)。

構文・改行コード・BOM は `tests/syntax-check.ps1` で検査します(本リポジトリで workflow を回すときの
品質ゲート。`.agents/workflow/config.json` の `test_command` / `quality_gate` にこのコマンドを設定する):

```powershell
pwsh -NoProfile -File tests/syntax-check.ps1
```

- `agents-md-setup/templates/workflow/scripts/` と `tests/` の `.ps1` をパースし、`.sh` を `bash -n` で検査する
- git 管理下と未追跡(`.gitignore` 対象外)のテキストファイルについて、CRLF を含むもの・
  非 ASCII 文字を含むのに BOM が無い `.ps1`・BOM 付きの `.ps1` 以外のファイル(`.sh`・`.py`・`.md` 等)を失敗にする
- `tests/skill-size.ps1` を呼び出す(単体でも実行できる)

skill のサイズは `tests/skill-size.ps1` で検査します:

```powershell
pwsh -NoProfile -File tests/skill-size.ps1
```

- ワークフローのループで読み込まれる 3 つの skill の `SKILL.md` の合計が 30,000 バイトを超えたら失敗にする
- 各 `SKILL.md` が 18,000 バイトを超えたら失敗にする
- `SKILL.md` から `references/*.md` へのリンク先が存在しなければ失敗にする(バッククォートの `references/x.md` と Markdown リンク `[説明](references/x.md#見出し)` の両方。見出しは検査しない)

### CI

GitHub Actions(`.github/workflows/test.yml`)が push と pull_request で全テストを実行します:
`ubuntu-latest` で `bash tests/run-all.sh`、`windows-latest` で `pwsh -NoProfile -File tests/run-all.ps1` と
`pwsh -NoProfile -File tests/syntax-check.ps1`。POSIX 版のシグナル終了テストなど Linux でしか
通らない経路の結果は、この CI で確認します。

### 改行コード

`.gitattributes` で全テキストファイルを作業ツリーでも LF に固定しています(`core.autocrlf=true` の
環境でも LF でチェックアウトされます)。`.gitattributes` の導入前に clone した作業ツリーに CRLF の
ファイルが残っている場合は、未コミットの変更が無い状態で次を実行して LF でチェックアウトし直します:

```bash
git ls-files --eol | awk '$2 == "w/crlf" {print $NF}' | while read -r f; do rm -- "$f"; done
git checkout -- .
git ls-files --eol | grep -c "w/crlf"   # 0 になれば完了
```

### 旧構成からの移行

以前の「`.claude/skills` 配下に各 skill への個別ジャンクション/シンボリックリンクを作成する」方式は、現在の「`.claude` 全体を `.agents` へのジャンクションとする」標準形に統一されています。

### ワークフロー設定

`.agents/workflow/config.json` は `agents-md-setup/templates/workflow/config.json` をプロジェクトルートにコピーして使用してください。

```bash
cp agents-md-setup/templates/workflow/config.json .agents/workflow/config.json
```

## サンドボックス環境での実行注意点

Codex 等のサンドボックス環境で子エージェント CLI を実行する際、CLI がホームディレクトリ(`~/.config` 等)への書込を必要とする場合があります(以下は opencode を例にした記述です)。

制限環境では、例えば opencode で `EEXIST: file already exists, mkdir '~/.config/opencode'` 等のエラーが出て CLI が起動失敗する場合があります。対処の詳細は `agent-dispatch/SKILL.md` の「トラブルシューティング」節を参照してください。

簡易対処として、`.agents/workflow/config.json` の `child_agent.isolate_xdg` を `true` にすると、`dispatch-run` が子エージェント CLI の `XDG_CONFIG_HOME` と `XDG_DATA_HOME` をプロジェクト内の書き込み可能なディレクトリ(`.agents/workflow/.config`)に向けます。`isolate_xdg` を `true` にした後で `/agents-md-setup`(`workflow-setup`)を再実行すると `.agents/workflow/.config/` が作られます(その下に CLI が使うディレクトリ(例: opencode の `log`)は、CLI が作るか、作れない環境では事前に作成します。詳細は `agent-dispatch/references/opencode.md`)。この設定では `~/.local/share/<CLI>/auth.json` 等の認証情報が見えなくなるため、sandbox 環境以外では既定の `false` のまま使ってください。

```powershell
# PowerShell の例
$env:XDG_CONFIG_HOME = ".agents/workflow/.config"
$env:XDG_DATA_HOME = ".agents/workflow/.config"
$null | opencode run $prompt
```

```bash
# POSIX シェルの例
XDG_CONFIG_HOME=.agents/workflow/.config XDG_DATA_HOME=.agents/workflow/.config opencode run "$prompt" < /dev/null
```
