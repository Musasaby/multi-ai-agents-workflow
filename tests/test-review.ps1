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

Show-Summary
