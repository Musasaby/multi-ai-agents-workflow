# Codex における agent-workflow skill 動作確認結果

## 概要

2026-06-12 に Codex 環境で `agent-workflow` skill が使用できるかを確認した。

結論として、`agent-workflow` は **Codex で使用可能。ただし子エージェント CLI
(`opencode`) の起動にはサンドボックス制約への対処が必要**。

## 確認した内容

- `agent-workflow` / `agent-task-plan` / `agent-dispatch` / `agent-review-commit` の
  `SKILL.md` は Codex から読み込み可能
- 現在ブランチは `develop/subtree-distribution` で、`agent-workflow` の前提である
  `develop/*` ブランチ条件を満たしている
- `.agents/workflow/state.json` は全タスク `done` で、未完了ワークフローとの衝突はない
- `.agents/workflow/tasks.md` と `state.json` の内容は整合している
- `opencode` は PATH 上に存在する
- 昇格実行かつ `XDG_CONFIG_HOME=.agents\workflow\.config` を指定した場合、
  `opencode --version` は `1.17.3` を返して成功する

## 発見した問題

### 1. 通常 sandbox 内では opencode が起動できない

通常の Codex sandbox 内で `opencode --version` を実行すると、以下のエラーで失敗した。

```text
EEXIST: file already exists, mkdir 'C:\Users\0127K\.config\opencode'
```

`C:\Users\0127K\.config` 配下へのアクセスも権限制約で失敗するため、ホームディレクトリ
配下の設定作成・参照が Codex sandbox と相性が悪い。

### 2. XDG_CONFIG_HOME 回避策も初回は昇格が必要

`agent-dispatch/SKILL.md` には回避策として
`XDG_CONFIG_HOME=.agents/workflow/.config` を指定する手順がある。

ただし、今回の Codex sandbox では `.agents/workflow/.config` の初回作成自体が
拒否された。

```text
Access to the path
'C:\D\ServiceProject\multi-ai-agents-workflow\.agents\workflow\.config'
is denied.
```

その後、昇格実行で同じ `XDG_CONFIG_HOME` を指定すると `opencode --version` は成功し、
`.agents/workflow/.config/opencode` が作成された。

### 3. `.agents/workflow/README.md` が存在しない

`agent-task-plan/SKILL.md` は `.agents/workflow/README.md` のフォーマットに従うと
記載しているが、現在の利用先側には同ファイルが存在しない。

実体は `.agents/skills/_templates/workflow/README.md` にあるため、Codex では読み替え
可能だが、skill 指示としては利用先セットアップ時に README を配置するか、参照先を明確に
する余地がある。

## 使用可能と判断できる条件

Codex で `agent-workflow` を実運用する場合は、以下のいずれかを満たす必要がある。

- `opencode` 実行時に昇格許可を行う
- 事前に `.agents/workflow/.config/opencode` を作成し、`XDG_CONFIG_HOME` を
  `.agents\workflow\.config` に向けて起動する
- Codex sandbox 外で子エージェント CLI の設定ディレクトリ作成を済ませる

推奨する起動前プリフライト:

```powershell
$env:XDG_CONFIG_HOME = ".agents\workflow\.config"
opencode --version
```

これが `1.17.3` のようなバージョン番号を返せば、少なくとも子エージェント CLI の
疎通は確認できている。

## 今回実行しなかったこと

`opencode run` による実際の子エージェント dispatch は実行していない。

理由は、実 dispatch はリポジトリ内の実装変更・テスト実行・状態更新を伴う可能性があり、
今回の依頼範囲は「Codex で問題なく使用できるかの調査」だったため。

## 結論

`agent-workflow` skill 本体と関連 skill は Codex から問題なく読み込める。
ワークフロー state も完了状態で衝突はなく、ブランチ条件も満たしている。

一方で、子エージェント CLI である `opencode` は通常 sandbox 内では起動に失敗する。
Codex で `agent-workflow` を実行するには、`XDG_CONFIG_HOME` の差し替えと、初回設定
ディレクトリ作成時の昇格許可を前提にする必要がある。
