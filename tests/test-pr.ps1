# #15: dispatch-prompt-gen -Pr(PR作成プロンプトの機械生成, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# origin(bare)を用意し、次の状態を作って state.json に記録する:
#   T2: main のコミット / T4: origin/main にだけあるコミット(ローカル main が古い)
#   T1: develop/feature(origin/main から分岐)上のコミット / T3: 未着手
function Initialize-Branch {
    Push-Location $script:Proj
    git init -q --bare .agents/remote.git
    git remote add origin .agents/remote.git
    Set-Content a.txt 'a'; git add a.txt; git commit -q -m "feat: T2"
    Set-Content d.txt 'd'; git add d.txt; git commit -q -m "feat: T4"
    git push -q origin main 2>$null
    git reset -q --hard HEAD~1
    git checkout -q -b develop/feature origin/main 2>$null
    Set-Content b.txt 'b'; git add b.txt; git commit -q -m "feat: T1"
    $mainHash = "$(git rev-parse --short main)".Trim()
    $t4Hash = "$(git rev-parse --short origin/main)".Trim()
    $branchHash = "$(git rev-parse --short HEAD)".Trim()
    Pop-Location
    Set-Tasks "## T1: ブランチ上のタスク`n- **依存**: なし`n`n## T2: マージ済みのタスク`n- **依存**: なし`n`n## T3: 未着手のタスク`n- **依存**: なし`n`n## T4: 別PRでマージ済みのタスク`n- **依存**: なし`n"
    $state = [ordered]@{ source = 'test'; branch = 'develop/feature'; updated_at = 'x'; tasks = @(
        [ordered]@{ id = 'T1'; title = 'ブランチ上のタスク'; status = 'done'; retries = 0; commit = $branchHash },
        [ordered]@{ id = 'T2'; title = 'マージ済みのタスク'; status = 'done'; retries = 0; commit = $mainHash },
        [ordered]@{ id = 'T3'; title = '未着手のタスク'; status = 'pending'; retries = 0; commit = $null },
        [ordered]@{ id = 'T4'; title = '別PRでマージ済みのタスク'; status = 'done'; retries = 0; commit = $t4Hash }
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
    Assert-NotContains $prompt "T4:" "task merged into origin/main excluded even if local main is stale"
    Assert-Contains $prompt "git log origin/main..HEAD" "prompt compares with origin/main"
    Assert-Contains $prompt "develop/feature" "branch name"
    Assert-Contains $prompt "--base main" "base branch"
    Assert-Contains $prompt "日本語" "japanese instruction"
    Assert-Contains $prompt "git push -u" "push instruction"
    Assert-Contains $prompt 'gh api -X PATCH "repos/{owner}/{repo}/pulls/' "update existing PR via gh api"
    Assert-Contains $prompt "-F body=@.agents/workflow/runs/pr-1-1/pr-body.md" "body file for update"
    Assert-NotContains ($prompt.Replace('{owner}/{repo}', '')) "{" "all placeholders replaced except {owner}/{repo}"
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

function Set-BaseBranch {
    param([string]$Name)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName base_branch -NotePropertyValue $Name -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

Invoke-TestCase "pr: base_branch があればその向きで比較する" {
    Initialize-Branch
    Push-Location $script:Proj; git push -q origin main:release/v1 2>$null; Pop-Location
    Set-BaseBranch 'release/v1'
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/pr-1-1/prompt.md")
    Assert-Contains $prompt "--base release/v1" "base branch"
    Assert-Contains $prompt "origin/release/v1" "compares with origin/release/v1"
    Assert-Contains $prompt "T1:" "branch task listed"
    Assert-Contains $prompt "T4:" "T4 included because range changed"
}

Invoke-TestCase "pr: base_branch が main 以外でも main 上は exit 1" {
    Initialize-Branch
    Set-BaseBranch 'release/v1'
    Push-Location $script:Proj; git checkout -q main; Pop-Location
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "pr: base_branch の上は exit 1" {
    Initialize-Branch
    Set-BaseBranch 'release/v1'
    Push-Location $script:Proj; git checkout -q -b release/v1 main 2>$null; Pop-Location
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "TaskId省略はexit 1" {
    Invoke-Script dispatch-prompt-gen.ps1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "pr: origin が無ければexit 1" {
    Initialize-Branch
    Push-Location $script:Proj; git remote remove origin; Pop-Location
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 1 $script:Code "no origin -> exit 1"
}

Invoke-TestCase "pr: 要件の対応をプロンプトに載せる" {
    Initialize-Branch
    Set-Tasks "## 要件`n- R1: 要望1`n- R2: 要望2`n`n## T1: ブランチ上のタスク`n- **要件**: R1`n- **依存**: なし`n`n## T2: マージ済みのタスク`n- **要件**: R2`n- **依存**: なし`n`n## T3: 未着手のタスク`n- **要件**: R1`n- **依存**: なし`n`n## T4: 別PRでマージ済みのタスク`n- **要件**: なし`n- **依存**: なし`n"
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/pr-1-1/prompt.md")
    Assert-Contains $prompt "- R1: 要望1(この PR: T1 / 他の PR: T3)" "requirement line"
    Assert-NotContains $prompt "- R2:" "requirement of merged task excluded"
}

Invoke-TestCase "pr: 要件の節が無ければなしと書く" {
    Initialize-Branch
    Invoke-Script dispatch-prompt-gen.ps1 '-Pr'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/pr-1-1/prompt.md")
    Assert-Contains $prompt "- なし(tasks.md に要件の節が無い、またはこの PR のタスクに対応する要件が無い)" "none text"
    Assert-NotContains $prompt "{requirement_list}" "placeholder replaced"
}

Show-Summary
