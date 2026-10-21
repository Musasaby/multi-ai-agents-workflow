# 親エージェント・子CLIの対応

親と子にどのエージェントを使えるか、どう設定するかをまとめる。

## 親エージェント

- Claude Code: `CLAUDE.md`(`@AGENTS.md` の1行)と `.claude` リンクで、AGENTS.md と skill を読み込む
- AGENTS.md を直接読む親(Codex 等): 追加の設定は不要
- 別の名前の設定ファイルを読む親: その設定ファイルから AGENTS.md を読み込む(import できなければ内容を写す)
- skill の仕組みが無い親: `.agents/skills/<名前>/SKILL.md` を読ませて手順に従わせる
- 親固有の機能(進捗表示のタスク登録等)は任意手順であり、対応していなくてもワークフローは進められる

## 子CLI

子CLIは `.agents/workflow/config.json` の `child_agent.command_template` で決まる。
`{prompt}` にプロンプト本文、`{prompt_file}` に prompt.md の絶対パスが入る(どちらも無ければ stdin で渡す)。

既定の opencode の設定は次のとおり。

```json
{
  "child_agent": {
    "command_template": "opencode run \"{prompt}\"",
    "profile": ""
  }
}
```

Claude Code を子にする場合は次のとおり。

```json
{
  "child_agent": {
    "command_template": "claude -p --output-format stream-json --verbose --permission-mode bypassPermissions \"{prompt}\"",
    "profile": "claude-stream-json"
  }
}
```

`--permission-mode bypassPermissions` は、子が確認なしでファイルを編集しコマンドを実行できるようにする。権限の範囲は環境に合わせて選ぶ。

- `.agents/workflow/config.json` の `child_agent.profile` で、子CLIの出力形式と検知パターンを選ぶ。プロファイルの一覧は `.agents/workflow/README.md` の「子CLIのプロファイル」節を参照する
- 組み込みのプロファイルに無い CLI は、`.agents/workflow/child-profiles.json` で定義する
- 検知できない検査は、`dispatch-check` が `Disabled checks:` に出す。opencode の注意は [../../agent-dispatch/references/opencode.md](../../agent-dispatch/references/opencode.md) を参照する
