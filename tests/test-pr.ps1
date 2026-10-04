# #15: dispatch-prompt-gen -Pr(PR作成プロンプトの機械生成, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# main に1コミット(T2)、develop/feature に1コミット(T1)を作り、state.json に記録する
function Initialize-Branch {
    Push-Location $script:Proj
    Set-Content a.txt 'a'; git add a.txt; git commit -q -m "feat: T2"
    git checkout -q -b develop/feature
    Set-Content b.txt 'b'; git add b.txt; git commit -q -m "feat: T1"
    $mainHash = "$(git rev-parse --short main)".Trim()
    $branchHash = "$(git rev-parse --short HEAD)".Trim()
    Pop-Location
    Set-Tasks "## T1: ブランチ上のタスク`n- **依存**: なし`n`n## T2: マージ済みのタスク`n- **依存**: なし`n`n## T3: 未着手のタスク`n- **依存**: なし`n"
    $state = [ordered]@{ source = 'test'; branch = 'develop/feature'; updated_at = 'x'; tasks = @(
        [ordered]@{ id = 'T1'; title = 'ブランチ上のタスク'; status = 'done'; retries = 0; commit = $branchHash },
        [ordered]@{ id = 'T2'; title = 'マージ済みのタスク'; status = 'done'; retries = 0; commit = $mainHash },
        [ordered]@{ id = 'T3'; title = '未着手のタスク'; status = 'pending'; retries = 0; commit = $null }
    ) }
    Write-Utf8File "$script:Proj/.agents/workflow/state.json" ($state | ConvertTo-Json -Depth 10)
}

Write-Host "test-pr.ps1"

Invoke-TestCase "pr: プロンプト生成" {
    Initialize-Branch
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "RunId: pr-1" "run id"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/pr-1-1/prompt.md")
    Assert-Contains $prompt "T1: ブランチ上のタスク" "branch task listed"
    Assert-NotContains $prompt "T2:" "merged task excluded"
    Assert-NotContains $prompt "T3:" "pending task excluded"
    Assert-Contains $prompt "develop/feature" "branch name"
    Assert-Contains $prompt "--base main" "base branch"
    Assert-Contains $prompt "日本語" "japanese instruction"
    Assert-Contains $prompt "git push -u" "push instruction"
    Assert-NotContains $prompt "{" "all placeholders replaced"
}

Invoke-TestCase "pr: 連番" {
    Initialize-Branch
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 0 $script:Code "exit code"
    Assert-Contains $script:Out "RunId: pr-2" "second run id"
}

Invoke-TestCase "pr: main上はexit 1" {
    Initialize-Branch
    Push-Location $script:Proj; git checkout -q main; Pop-Location
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "pr: 対象タスクなしはexit 1" {
    Initialize-Branch
    Push-Location $script:Proj; git checkout -q -b develop/empty main; Pop-Location
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "TaskId省略はexit 1" {
    Invoke-Script dispatch-prompt-gen.ps1
    Assert-Eq 1 $script:Code "exit code"
}

Show-Summary
