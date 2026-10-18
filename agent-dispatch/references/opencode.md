# opencode を子CLIにするときの手順

`child_agent.profile` が `opencode` または `auto` のとき(opencode を子CLIにするとき)に読む。
`agent-dispatch/SKILL.md` から、子CLI固有の確かめ方としてリンクされている。

## stdin を閉じること

opencode は stdin が開いたままだとハングする。`dispatch-run` はどの場合も stdin を閉じる:

- テンプレートに `{prompt}` または `{prompt_file}` があれば、stdin を閉じて起動する
- どちらも無ければ、プロンプトを stdin に書き込んでから閉じる

そのため、`dispatch-run` 経由で起動する限り対処は要らない。`dispatch-run` を使わずに手で
opencode を起動して確かめるときは、stdin を閉じること(例: `opencode run "..." < /dev/null`)。

## 子CLIのログ(`cli_log`)

`child_agent.cli_log` が未設定なら、opencode のデフォルトのログ先は
`~/.local/share/opencode/log/opencode.log`。ハングや `idle-timeout` では、その末尾の
ERROR 行を確認する(利用上限・プロバイダー障害の行があれば `Provider error: yes` になる)。

## `reason=token-limit` の確かめ方

セッション DB(`~/.local/share/opencode/opencode.db` の `message` テーブル)で該当セッションの
最後の assistant メッセージを見て、`finish` が `length`(出力トークン上限で打ち切り)であること、
または `tokens` の `reasoning` が上限(例: 32000)に近いことを確かめる。
親がセッション DB を確かめられない場合は、ユーザーに確認を依頼する。

## トラブルシューティング

### `.agents/workflow/.config/opencode/log` の事前作成

`child_agent.isolate_xdg: true` の sandbox 環境で、`.agents/workflow/.config/opencode/log` の
作成が拒否される場合は、`/agents-md-setup` 等のセットアップ時に、リポジトリのセットアップ権限で
このディレクトリを事前に作成しておく。

### 認証エラー・`Unexpected server error`

`isolate_xdg` が `true` だと `~/.local/share/opencode/auth.json` が見えなくなる。
sandbox 環境でなければ `isolate_xdg` を `false`(既定)にする。`true` が必要な場合は、
`.agents/workflow/.config` 配下でログインする:

```bash
XDG_CONFIG_HOME=.agents/workflow/.config XDG_DATA_HOME=.agents/workflow/.config opencode auth login
```

### `EEXIST: file already exists, mkdir '~/.config/...'`

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` を設定しても opencode 起動時にこのエラーが出る場合は、
環境変数が opencode まで渡っていない可能性がある。`command_template` 内で `~` が展開される等の
意図しないパス解釈が起きていないか、`isolate_xdg` の設定と合わせて確認する。
