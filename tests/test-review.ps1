# dispatch-prompt-gen -Review(レビュー用プロンプトの機械生成, PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Set-ReviewTasks {
    Set-Tasks "## T1: レビュー対象のタスク`n- **依存**: なし`n"
}

# comprehension_check を有効にする
function Enable-ComprehensionCheck {
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cc = [ordered]@{ enabled = $true; questions_per_task = 2 }
    $cfg | Add-Member -NotePropertyName comprehension_check -NotePropertyValue $cc -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

# 完了報告を echo するスタブの子で review の run を dispatch-run に作らせる
function Set-ReviewChild {
    param([string]$Body)
    Write-Utf8File "$script:Proj/review-child.ps1" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.PSObject.Properties.Remove('review')
    $cfg | Add-Member -NotePropertyName review -NotePropertyValue ([pscustomobject]@{ command_template = 'pwsh -NoProfile -File ./review-child.ps1 "{prompt}"' })
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

function New-ReviewRun {
    param([string]$Report, [string]$Extra = '')
    $body = (@($Report -split "`n") | ForEach-Object { "Write-Output '" + ($_ -replace "'", "''") + "'" }) -join "`n"
    $body += "`n"
    if ($Extra) { $body += $Extra + "`n" }
    Set-ReviewChild $body
    Write-Utf8File "$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md" "prompt`n"
    Invoke-Script dispatch-run.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
}

Write-Host "test-review.ps1"

Invoke-TestCase "review のプロンプトを生成する" {
    Set-ReviewTasks
    Set-Report -TaskId 'T1' -Attempt 1
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "RunId: review-T1" "run id"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md")
    Assert-Contains $prompt "レビュー対象のタスク" "task title"
    Assert-Contains $prompt ".agents/workflow/runs/T1-1/report.md" "report path"
    Assert-Contains $prompt ".agents/workflow/runs/T1-2/fix-notes.md" "fix notes path"
    Assert-Contains $prompt "質問ファイルは作らない" "comprehension disabled instruction"
}

Invoke-TestCase "report.md が無いと exit 2" {
    Set-ReviewTasks
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 2 $script:Code "missing report -> exit 2"
}

Invoke-TestCase "理解確認が有効なら質問ファイルの指示を入れる" {
    Set-ReviewTasks
    Set-Report -TaskId 'T1' -Attempt 1
    Enable-ComprehensionCheck
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md")
    Assert-Contains $prompt ".agents/workflow/comprehension/T1.md" "question file path"
    Assert-Contains $prompt "2 問" "question count"
}

Invoke-TestCase "合格なら commit を出す" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Next: commit T1" "next commit"
    Assert-Contains $script:Out "Review summary: 問題なし" "review summary"
}

Invoke-TestCase "不合格で fix-notes があれば retry を出す" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: fail`n- 指摘: a.txt の修正`n- 要約: 修正が必要`n- fix-notes: あり`n- 理解確認: 対象外" `
        "New-Item -ItemType Directory -Force '.agents/workflow/runs/T1-2' | Out-Null; Set-Content -Path '.agents/workflow/runs/T1-2/fix-notes.md' -Value '修正点'"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Next: retry T1" "next retry"
}

Invoke-TestCase "不合格で fix-notes が無ければ no-report" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: fail`n- 指摘: a.txt の修正`n- 要約: 修正が必要`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 5 $script:Code "missing fix-notes -> exit 5"
    Assert-Contains $script:Out "fix-notes not found" "fix-notes not found"
}

Invoke-TestCase "Verdict が pass/fail 以外なら no-report" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: ok`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 5 $script:Code "invalid verdict -> exit 5"
    Assert-Contains $script:Out "Verdict must be pass or fail" "invalid verdict message"
}

Invoke-TestCase "レビューの run が作業ツリーを変えたら tampered" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外" `
        "Set-Content -Path a.txt -Value 'changed'"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 8 $script:Code "main tree changed -> exit 8"
    Assert-Contains $script:Out "changed: main worktree: a.txt" "changed main worktree"
}

Show-Summary
