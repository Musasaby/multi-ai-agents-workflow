## worktree でレビューする場合の追加の指示

- 作業ディレクトリは git worktree `{workdir}` です。子の変更はまだ本体に取り込まれていません。`git status --porcelain` と `git diff HEAD` は `{workdir}` の中で実行してください
- 完了報告の読み込み・fix-notes.md・理解確認の質問ファイルは、上に書かれた絶対パス(本体 `{main_root}` の下)を使ってください。`{workdir}` の中の `.agents/workflow/` には書かないでください
