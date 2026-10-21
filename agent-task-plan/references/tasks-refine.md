# tasks.md の推敲(yomiyasu、任意)

前提・解釈: コード例は `.sh` 版だけを示す。PowerShell では `.agents/workflow/scripts/<名>.ps1` を使い、`--check` のようなオプションを `-Check` の形の名前付き引数に読み替える。

tasks.md を書いた後、state-sync の前に行う。
`text_refine.skill` が未設定なら `Next: continue` が返るので、そのまま state-sync に進む。
`Hint:` の扱い、`Next: refine` の依頼文の実行、`--check` の候補の判断、yomiyasu を呼べなかったときは
`agent-workflow/references/report-template.md` の「日本語の推敲」に従う(ここには書き写さない)

1. tasks.md を `.agents/workflow/runs/refine/tasks.md` にコピーする
2. 場面 `tasks` で `text-refine` を実行する

   ```bash
   .agents/workflow/scripts/text-refine.sh tasks .agents/workflow/runs/refine/tasks.md
   ```
3. `Next: continue` のときは、そのまま state-sync に進む(tasks.md は書き換えない)
4. `Next: refine` のときは、`Request:` の依頼文で推敲し、`--check` を実行する

   ```bash
   .agents/workflow/scripts/text-refine.sh tasks .agents/workflow/runs/refine/tasks.md --check
   ```
   - `Next: continue` のときは、`Output:` のファイル(`.agents/workflow/runs/refine/tasks.refined.md`)で
     `.agents/workflow/tasks.md` を置き換えてから、state-sync に進む
   - `Next: escalate reason=refine-structure-changed` のとき(機械パースする行が推敲で変わった)は、
     **state-sync に進まずに止める**。`Changed:`・`Refined:` 行を利用者に示し、推敲前の tasks.md を使うか、
     推敲後の文を直すかを決めてもらう
