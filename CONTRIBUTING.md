# 開発者向けの手順(本リポジトリの開発)

`AGENTS.md` は、このリポジトリを開発するエージェント向けのルールです。
`CONTRIBUTING.md`(このファイル)は、人とエージェントが読む開発手順です。

## 構成

本リポジトリの `.claude` は `.agents` へのジャンクション(標準形)です。
skill の正本はリポジトリルート直下の各ディレクトリ(`agent-workflow/` 等)で、編集はここで行います。
`.agents/` 配下は**未追跡**(ローカル実行状態。`.gitignore` で除外)のミラーで、編集しません。

> **利用先との違い**: 利用先では `.agents/skills/` は `npx skills add` で配置して追跡しますが、
> 本リポジトリ(配布元)はルートが配布物そのもののため、`.agents/` はローカル実行用のコピーとして
> 未追跡で運用します(`npx skills` は使わず、下の同期のコピーで更新します)。

## 開発環境の準備

clone 後に、次の順で行います。

1. 下の「skill・スクリプトを編集した後の同期」のコピーで `.agents/skills/` を作る。
2. `bash agents-md-setup/templates/workflow/scripts/workflow-setup.sh` を実行し、
   `.agents/workflow/`(`config.json`・`README.md`・`scripts/`・`runs/`)を作る。
3. workflow-setup が `.gitignore` と `.gitattributes` に足した行は、このリポジトリでは不要
   (`.agents/` を丸ごと除外している)なので、`git checkout -- .gitignore .gitattributes` で戻す。
4. `.agents/workflow/config.json` の `test_command` と `quality_gate.steps` に
   `pwsh -NoProfile -File tests/syntax-check.ps1` を設定する。

## skill・スクリプトを編集した後の同期

ルート直下で skill を編集したら、`.claude/skills` 経由の Claude Code 等に反映するため、
次のコピーで `.agents/skills/` を同期します(git 操作・コミットは不要です)。

```powershell
# ルート直下の配布物を .agents/skills にコピー
$items = 'agent-workflow','agent-task-plan','agent-dispatch','agent-review-commit',
         'agent-comprehension-check','agent-quality-gate','agent-branch-guard','agents-md-setup','workflow-update'
New-Item -ItemType Directory -Force .agents/skills | Out-Null
foreach ($i in $items) {
  Remove-Item ".agents/skills/$i" -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item $i ".agents/skills/$i" -Recurse
}
```

スクリプト(`agents-md-setup/templates/workflow/scripts/`)を編集した後は、
`.agents/workflow/` への反映も必要です。次のコマンドで差分を一覧し、
`--overwrite <名前,...>` で `.agents/workflow/` に反映します。

```bash
bash agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh
bash agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.sh --overwrite <名前,...>
```

## テスト

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

既定はテストファイル単位の並列実行で、同時実行数は `tests/run-all.conf` の `jobs`(既定は 4)です。1 行目に `Jobs: <同時実行数>` を出します。
`--print-jobs`(`run-all.ps1` は `-PrintJobs`)を付けると、同時実行数だけを出して終わります。
`--jobs <N>`(`run-all.ps1` は `-Jobs <N>`)で同時実行数を指定でき、直列にするときは
`--jobs 1`(`-Jobs 1`)を付けます。直列のときは各ファイルの出力をそのまま流し、
並列のときは各ファイルの出力を混ぜず、実行後にファイルごとにまとめて出します。

POSIX 版のシグナル終了のテスト(Python 経由の経路)は Linux でのみ実行されます(Windows ではスキップ)。

## どこで何を確かめるか

テスト一式(`run-all`)は直列で 13〜18 分かかり、子エージェントの Bash は 10 分で打ち切られます。
そのため、確かめる場所を次のように分けます。タスクの受け入れ基準にはテスト一式(`run-all`)を書きません。

- 子エージェント: 変更したスクリプトに対応するテストファイル(`tests/test-<名前>.sh` と `.ps1`。
  1 つずつ別のコマンドで実行する)と `tests/syntax-check.ps1`
- 親エージェント: 子の完了報告のテスト結果を確かめる。レビューでテスト一式を再実行しない。
  `tests/` の共通部分(`lib.*`・`run-all.*`)を変えたときなど影響が広いときだけ、並列で実行する
- GitHub Actions: テスト一式

## 品質ゲートと skill のサイズ

構文・改行コード・BOM は `tests/syntax-check.ps1` で検査します(本リポジトリで workflow を回すときの
品質ゲートで、`.agents/workflow/config.json` の `test_command` / `quality_gate` にこのコマンドを設定します)。

```powershell
pwsh -NoProfile -File tests/syntax-check.ps1
```

- `agents-md-setup/templates/workflow/scripts/` と `tests/` の `.ps1` をパースし、`.sh` を `bash -n` で検査する
- git 管理下と未追跡(`.gitignore` 対象外)のテキストファイルについて、CRLF を含むもの・
  非 ASCII 文字を含むのに BOM が無い `.ps1`・BOM 付きの `.ps1` 以外のファイル(`.sh`・`.py`・`.md` 等)を失敗にする
- `tests/skill-size.ps1` を呼び出す(単体でも実行できる)

skill のサイズは `tests/skill-size.ps1` で検査します。

```powershell
pwsh -NoProfile -File tests/skill-size.ps1
```

- ワークフローのループで読み込まれる 3 つの skill の `SKILL.md` の合計が 30,000 バイトを超えたら失敗にする
- 各 `SKILL.md` が 18,000 バイトを超えたら失敗にする
- `SKILL.md` から `references/*.md` へのリンク先が存在しなければ失敗にする(バッククォートの `references/x.md` と Markdown リンク `[説明](references/x.md#見出し)` の両方。見出しは検査しない)

## CI

GitHub Actions(`.github/workflows/test.yml`)が、`main` への push と pull_request を起動条件にして、全テストを実行します。
PR に続けて push すると、古い実行は取り消されます。
`ubuntu-latest` では `bash tests/run-all.sh --jobs 4` を、`windows-latest` では
`pwsh -NoProfile -File tests/run-all.ps1 -Jobs 4` と `pwsh -NoProfile -File tests/syntax-check.ps1` を実行します。
POSIX 版のシグナル終了テストなど Linux でしか通らない経路の結果は、この CI で確認します。

## 改行コード

`.gitattributes` で全テキストファイルを作業ツリーでも LF に固定しています(`core.autocrlf=true` の
環境でも LF でチェックアウトされます)。`.gitattributes` の導入前に clone した作業ツリーに CRLF の
ファイルが残っている場合は、未コミットの変更が無い状態で次を実行して LF でチェックアウトし直します。

```bash
git ls-files --eol | awk '$2 == "w/crlf" {print $NF}' | while read -r f; do rm -- "$f"; done
git checkout -- .
git ls-files --eol | grep -c "w/crlf"   # 0 になれば完了
```
