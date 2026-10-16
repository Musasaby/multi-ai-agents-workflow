# #16: dispatch-run の done マーカーと dispatch-check(PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Set-Child {
    param([string]$Body)
    Write-Utf8File "$script:Proj/child.ps1" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'pwsh -NoProfile -File ./child.ps1 "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt`n"
}

function Get-DoneExit { return (Get-Content "$script:Proj/.agents/workflow/runs/T1-1/done" -Encoding utf8)[0] }

# dispatch-run と同じ形式で guard.sha256 を書く(runs/<run>/prompt.md と管理ファイル)
function Write-Guard {
    param([string]$Run)
    Push-Location $script:Proj
    $lines = foreach ($f in @(".agents/workflow/runs/$Run/prompt.md", '.agents/workflow/state.json', '.agents/workflow/tasks.md', '.agents/workflow/config.json')) {
        $h = if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() } else { '-' }
        "$h  $f"
    }
    Pop-Location
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/guard.sha256" (($lines -join "`n") + "`n")
}

function New-Run {
    param([string]$Exit, [string]$Log, [string]$Run = 'T1-1')
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/prompt.md" "prompt`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/done" "EXIT:$Exit`nEND:2026-01-01T00:00:00+09:00`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/output.log" "$Log`n"
    Write-Guard $Run
}

function Set-Isolate {
    param([string]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.PSObject.Properties.Remove('isolate_xdg')
    if ($Value -ne 'absent') { $cfg.child_agent | Add-Member -NotePropertyName isolate_xdg -NotePropertyValue ($Value -eq 'true') }
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

function Get-ChildXdg {
    $env:XDG_DATA_HOME = 'C:/caller/xdg-data'
    try { Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1 } finally { Remove-Item Env:XDG_DATA_HOME -ErrorAction SilentlyContinue }
    return [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log")
}

$report = "作業しました`n## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス"

Write-Host "test-dispatch.ps1"

Invoke-TestCase "run: 正常終了はEXIT:0" {
    Set-Child 'Write-Output hello; exit 0'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:0" (Get-DoneExit) "done marker"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log")) "hello" "output.log"
}

Invoke-TestCase "run: 起動時の git 状態を git-state.txt に記録する" {
    Set-Child 'Write-Output hello; exit 0'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    $expected = "$(git -C "$script:Proj" rev-parse HEAD)".Trim()
    $gitStateLines = [System.IO.File]::ReadAllLines("$script:Proj/.agents/workflow/runs/T1-1/git-state.txt")
    Assert-Eq "head $expected" $gitStateLines[0] "git-state.txt first line"
    Assert-Eq 4 $gitStateLines.Count "git-state.txt has 4 lines"
}

Invoke-TestCase "run: 通常の非0は数値のまま" {
    Set-Child 'exit 3'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:3" (Get-DoneExit) "done marker"
}

Invoke-TestCase "run: isolate_xdg 未指定/false は XDG を引き継ぐ" {
    Set-Child 'Write-Output "DATA=$env:XDG_DATA_HOME"'
    Set-Isolate absent
    Assert-Contains (Get-ChildXdg) "DATA=C:/caller/xdg-data" "absent: caller XDG inherited"
    Set-Isolate false
    Assert-Contains (Get-ChildXdg) "DATA=C:/caller/xdg-data" "false: caller XDG inherited"
}

Invoke-TestCase "run: isolate_xdg true は XDG を切り替える" {
    Set-Child 'Write-Output "DATA=$env:XDG_DATA_HOME"'
    Set-Isolate true
    Assert-Contains (Get-ChildXdg) "DATA=.agents/workflow/.config" "true: XDG isolated"
}

Invoke-TestCase "check: 正常" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "kind: ok" "kind"
    Assert-Contains $script:Out "a.txt" "git status shown"
    Assert-Contains $script:Out "Completion report: found" "report found"
}

Invoke-TestCase "check: signalはexit 4" {
    New-Run "signal:15" "step 67 ..."
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: signal" "kind"
    Assert-Contains $script:Out "step 67" "log tail shown"
}

Invoke-TestCase "check: 非0はexit 4" {
    New-Run 3 $report
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: nonzero" "kind"
}

Invoke-TestCase "check: crashedはexit 4" {
    New-Run "crashed:boom" ""
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: crashed" "kind"
}

Invoke-TestCase "check: 完了報告なしはexit 5" {
    New-Run 0 "did something but no report"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code"
    Assert-Contains $script:Out "Completion report: missing" "report missing"
}

Invoke-TestCase "check: doneなしはexit 1" {
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/runs/T1-1"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "check: BOM付きdone" {
    New-Run 0 $report
    [System.IO.File]::WriteAllText("$script:Proj/.agents/workflow/runs/T1-1/done", "EXIT:0`r`nEND:x`r`n", [System.Text.UTF8Encoding]::new($true))
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "BOM-prefixed done marker parsed: $($script:Out)"
}

$esc = [char]27

# #35: 子がテンプレートを cat しただけの `## 完了報告` に一致させない
Invoke-TestCase "check: 完了報告の後にツール実行が続けば無効(exit 5)" {
    New-Run 0 "$esc[0m`$ $esc[0mcat dispatch-pr-prompt-template.md`n## 完了報告`n- PR URL: <作成した PR の URL>`n$esc[0m→ $esc[0mRead README.md`n$esc[0m`$ $esc[0mls"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "invalid (tool activity after the report" "reason"
}

Invoke-TestCase "check: テンプレートのままの完了報告は無効(exit 5)" {
    New-Run 0 "## 完了報告`n- 変更ファイル: <一覧>`n- テスト結果: <パス/失敗の件数>"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "template placeholder" "reason"
}

Invoke-TestCase "check: 必須項目が無い完了報告は無効(exit 5)" {
    New-Run 0 "## 完了報告`n- 変更ファイル: a.txt`n- 備考: なし"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "missing field: テスト結果" "reason"
}

Invoke-TestCase "check: 箇条書きの値・CRLF・ANSIを含む完了報告は有効" {
    New-Run 0 "$esc[0m`$ $esc[0mbash tests/test.sh`r`n## 完了報告`r`n- 変更ファイル:`r`n  - ``a.txt```r`n- テスト結果: 全件パス`r"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "check: 権限拒否はexit 6" {
    New-Run 0 "! permission requested: external_directory (/tmp/*); auto-rejecting`n✗ cd /tmp && git init failed`nError: The user rejected permission to use this specific tool call."
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Permission denied: yes" "flag"
    Assert-Contains $script:Out "auto-rejecting" "denied line shown"
}

Invoke-TestCase "check: 変更0件はexit 7" {
    New-Run 0 $report
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 7 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Changes: 0" "changes"
}

Invoke-TestCase "check: PR作成のrunは変更0件でも正常" {
    New-Run 0 "## 完了報告`n- PR URL: https://github.com/o/r/pull/1`n- タイトル: t" 'pr-1-1'
    Invoke-Script dispatch-check.ps1 -TaskId pr-1 -Attempt 1
    Assert-Eq 0 $script:Code "pr run is not checked for changes: $($script:Out)"
}

# #34: 管理ファイルの変更・削除を検知する
Invoke-TestCase "check: state.jsonの変更はexit 8" {
    Set-State 'T1:in_progress'
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Set-State 'T1:done'
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "changed: .agents/workflow/state.json" "issue"
}

Invoke-TestCase "check: prompt.mdの削除はexit 8" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/prompt.md"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "deleted: .agents/workflow/runs/T1-1/prompt.md" "issue"
}

Invoke-TestCase "check: guard.sha256が無ければexit 8" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "guard.sha256 not found" "issue"
}

Invoke-TestCase "check: output.logの切り詰めはexit 8" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" ("`0`0`0" + $report + "`n")
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "truncated during the run" "issue"
}

# #44: 切り詰められた output.log の末尾表示から NUL を除く(sh 版と揃える)
Invoke-TestCase "check: 切り詰められたoutput.logの表示にNULを含めない" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" ("`0`0`0" + $report + "`n")
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-NotContains $script:Out ([string][char]0) "no NUL in output"
    Assert-Contains $script:Out "テスト結果: 全件パス" "report body shown"
}

# dispatch-run が書いた guard.sha256 を dispatch-check が検証する(結合)
Invoke-TestCase "run+check: 子が正常に完了すればexit 0" {
    Set-State 'T1:in_progress'
    Set-Child "Set-Content -Path a.txt -Value x; Write-Output '## 完了報告'; Write-Output '- 変更ファイル: a.txt'; Write-Output '- テスト結果: 全件パス'"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" "guard written"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "run+check: 子がprompt.mdを消せばexit 8" {
    Set-Child "Remove-Item .agents/workflow/runs/T1-1/prompt.md; Set-Content -Path a.txt -Value x; Write-Output '## 完了報告'; Write-Output '- 変更ファイル: a.txt'; Write-Output '- テスト結果: 全件パス'"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "check: 報告本文の→や$で始まる行は有効" {
    New-Run 0 "## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス`n`$ npm test`n→ 要確認"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "check: 表示されたソース中の権限拒否の文字列には反応しない" {
    New-Run 0 "$esc[0m`$ $esc[0mgrep -n auto-rejecting tests/test-dispatch.sh`n12:    make_run 0 `"! permission requested: external_directory (/tmp/*); auto-rejecting`nError: The user rejected permission to use this specific tool call.`"`n$report"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Permission denied: no" "flag"
}

Invoke-TestCase "check: 色付きの権限拒否行もexit 6" {
    New-Run 0 "$esc[91m! permission requested: external_directory (/tmp/*); auto-rejecting$esc[0m"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "colored permission line detected: $($script:Out)"
}

Invoke-TestCase "check: UTF-16LEのoutput.log(Windows PowerShell 5.1)を読める" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    [System.IO.File]::WriteAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log", "$report`r`n", [System.Text.UnicodeEncoding]::new($false, $true))
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Guard: ok" "UTF-16 is not treated as truncated"
}

Show-Summary
