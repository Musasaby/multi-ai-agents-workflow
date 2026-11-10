# サブエージェントでの起動

`dispatch-start` が `Next: subagent <ID> <N>` を出したときに読む(`--subagent-capable` を付けて起動した場合)。
コマンド例は `.sh` 版だけを示す(PowerShell への読み替えは `agent-dispatch/SKILL.md` の冒頭と同じ)。
出力の `Run:`・`Prompt:`・`Workdir:`・`Output:`・`Model:` を使う。

## 手順

1. Agent ツールでサブエージェントを起動する。プロンプトは短くし、`Prompt:` のファイルを読んで
   従うよう指示する(例: 「`<Prompt のパス>` を読み、その指示に従って実装とテストを行う。作業ディレクトリは `<Workdir>`」)。
   **親は prompt.md の全文を読み込まない**
2. `Model:` が `default` 以外なら、Agent ツールの model に渡す
3. 並列(`Next: dispatch A B`)のときは、複数のサブエージェントをバックグラウンドで起動する
4. 完了通知を受けたら、`Output:` のファイルが無ければサブエージェントの最終応答をそこに書く
5. `dispatch-finish` を実行する。Agent ツールがエラーで終わったときは `--exit 1` を付ける

   ```bash
   .agents/workflow/scripts/dispatch-finish.sh <ID> <N>
   .agents/workflow/scripts/dispatch-finish.sh <ID> <N> --exit 1
   ```

6. 出力の最後の `Next:` 行で、`SKILL.md` §2 の分岐に従う

## 注意

- サブエージェントの run は `dispatch-wait` で待たない。完了通知を待って `dispatch-finish` を実行する
- 親のセッションが切れると、実行中のサブエージェントは失われる。再開時は、`Output:` のファイルが無ければ
  「親のセッションが切れてサブエージェントが失われた」と1行書き(`dispatch-finish` は `output.log` が無いと止まる)、
  `dispatch-finish.sh <ID> <N> --exit 1` で `abnormal-exit` にしてから、再 dispatch する
- `Disabled checks:` が `none` 以外の項目は、サブエージェントの run では検知できない。
  報告に添えて `output.log` の末尾を目で確かめる
  ([無効な検査の扱い](troubleshooting.md#無効な検査の扱い))
