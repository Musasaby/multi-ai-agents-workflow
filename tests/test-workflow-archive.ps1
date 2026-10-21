# workflow-archive(workflow 状態のアーカイブ移動, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# "Archived: <dir> (<names>)" から <dir> を取り出す
function Get-ArchiveDir {
    $rest = $script:Out -replace '^Archived: ', ''
    return ($rest -replace ' \([^)]*\)$', '')
}

Write-Host "test-workflow-archive.ps1"

Invoke-TestCase "全対象の移動と Archived: の出力" {
    Set-Tasks "# tasks"
    Set-State 'T1:done'
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T0-1/report.md" "r`n"
    Write-Utf8File "$script:Proj/.agents/workflow/comprehension/questions.md" "q`n"
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    $dir = Get-ArchiveDir
    Assert-Contains $script:Out "(tasks.md, state.json, runs, comprehension)" "output lists all targets"
    Assert-FileExists "$dir/tasks.md" "tasks.md moved"
    Assert-FileExists "$dir/state.json" "state.json moved"
    Assert-FileExists "$dir/runs/T0-1/report.md" "runs moved"
    Assert-FileExists "$dir/comprehension/questions.md" "comprehension moved"
    Assert-FileAbsent "$script:Proj/.agents/workflow/tasks.md" "tasks.md removed from workflow dir"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json removed from workflow dir"
}

Invoke-TestCase "一部の対象だけ移動" {
    Set-State 'T1:done'
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    $dir = Get-ArchiveDir
    Assert-Contains $script:Out "(state.json, runs)" "output lists state.json and runs"
    Assert-NotContains $script:Out "tasks.md" "output lists only existing targets"
    Assert-FileExists "$dir/state.json" "state.json moved"
    Assert-FileAbsent "$dir/tasks.md" "tasks.md untouched"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json removed from workflow dir"
}

Invoke-TestCase "スラッグなしは exit 1" {
    Set-State 'T1:done'
    Invoke-Script workflow-archive.ps1
    Assert-Eq 1 $script:Code "no slug rejected"
    Assert-Contains $script:Err "使い方" "usage message"
    Assert-FileExists "$script:Proj/.agents/workflow/state.json" "nothing moved"
    Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created"
}

Invoke-TestCase "パス区切り・.. を含むスラッグは exit 1" {
    Set-State 'T1:done'
    foreach ($slug in @('a/b', 'a\b', 'a..b', '..')) {
        Invoke-Script workflow-archive.ps1 $slug
        Assert-Eq 1 $script:Code "slug '$slug' rejected"
        Assert-FileExists "$script:Proj/.agents/workflow/state.json" "nothing moved for '$slug'"
        Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created for '$slug'"
    }
}

Invoke-TestCase "移動対象なしは exit 1" {
    Remove-Item -Recurse -Force "$script:Proj/.agents/workflow/runs"
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 1 $script:Code "no targets rejected"
    Assert-Contains $script:Err "移動対象がありません" "message"
    Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created"
}

function Set-StateBranch { param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

function Initialize-BranchState {
    Set-Tasks "# tasks"
    Set-State 'T1:done'
    Set-StateBranch develop/x
}

Invoke-TestCase "PR が OPEN なら exit 2 で何も移動しない" {
    Initialize-BranchState
    Set-GhStubResult -Stdout '{"state":"OPEN","url":"https://example.com/pr/1"}'
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 2 $script:Code "exit: $($script:Err)"
    Assert-Eq "OPEN https://example.com/pr/1" (($script:Out -split "`n")[0].Trim()) "first line"
    Assert-Eq "Next: escalate reason=pr-open" (($script:Out -split "`n")[-1].Trim()) "Next line"
    Assert-FileExists "$script:Proj/.agents/workflow/state.json" "state.json kept"
    Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created"
}

Invoke-TestCase "PR が CLOSED なら exit 3" {
    Initialize-BranchState
    Set-GhStubResult -Stdout '{"state":"CLOSED","url":"https://example.com/pr/1"}'
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 3 $script:Code "exit: $($script:Err)"
    Assert-Eq "Next: escalate reason=pr-closed" (($script:Out -split "`n")[-1].Trim()) "Next line"
    Assert-FileExists "$script:Proj/.agents/workflow/state.json" "state.json kept"
    Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created"
}

Invoke-TestCase "gh が失敗したら exit 4" {
    Initialize-BranchState
    Set-GhStubResult -Code 1 -Stderr 'gh stub failure'
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 4 $script:Code "exit: $($script:Err)"
    Assert-Eq "Next: escalate reason=gh-unavailable" (($script:Out -split "`n")[-1].Trim()) "Next line"
    Assert-FileExists "$script:Proj/.agents/workflow/state.json" "state.json kept"
    Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created"
}

Invoke-TestCase "PR が MERGED ならアーカイブする" {
    Initialize-BranchState
    Set-GhStubResult -Stdout '{"state":"MERGED","url":"https://example.com/pr/1"}'
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json moved"
    Assert-Contains (Get-GhStubLog) "pr view develop/x" "gh pr view called"
}

Invoke-TestCase "-Force なら PR を確かめずにアーカイブする" {
    Initialize-BranchState
    Invoke-Script workflow-archive.ps1 myslug -Force
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "" ("$(Get-GhStubLog)".Trim()) "gh not called"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json moved"
}

Invoke-TestCase "PR 未作成で未マージのコミットがあれば exit 5" {
    Initialize-BranchState
    Set-GhStubResult -Code 1 -Stderr 'no pull requests found for branch "develop/x"'
    Push-Location $script:Proj
    try {
        git checkout -q -b develop/x
        Write-Utf8File "$script:Proj/x.txt" "x`n"
        git add x.txt
        git commit -q -m "feat: x"
    } finally { Pop-Location }
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 5 $script:Code "exit: $($script:Err)"
    Assert-Eq "NO_PR" (($script:Out -split "`n")[0].Trim()) "first line"
    Assert-Eq "Next: escalate reason=pr-not-created" (($script:Out -split "`n")[-1].Trim()) "Next line"
    Assert-Contains $script:Err "1 commit(s)" "stderr mentions commit count"
    Assert-FileExists "$script:Proj/.agents/workflow/state.json" "state.json kept"
    Assert-FileAbsent "$script:Proj/.agents/workflow/archive" "no archive dir created"
}

Invoke-TestCase "PR 未作成で未マージのコミットが無ければアーカイブする" {
    Initialize-BranchState
    Set-GhStubResult -Code 1 -Stderr 'no pull requests found for branch "develop/x"'
    git -C $script:Proj branch develop/x
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json moved"
}

Invoke-TestCase "PR 未作成でブランチが無ければアーカイブする" {
    Initialize-BranchState
    Set-GhStubResult -Code 1 -Stderr 'no pull requests found for branch "develop/x"'
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json moved"
}

Invoke-TestCase "PR 未作成のとき比較先は base_branch" {
    Initialize-BranchState
    Set-GhStubResult -Code 1 -Stderr 'no pull requests found for branch "develop/x"'
    Push-Location $script:Proj
    try {
        git checkout -q -b develop/x
        Write-Utf8File "$script:Proj/x.txt" "x`n"
        git add x.txt
        git commit -q -m "feat: x"
        git branch trunk develop/x
    } finally { Pop-Location }
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName base_branch -NotePropertyValue 'trunk' -Force
    $cfg | Add-Member -NotePropertyName upstream -NotePropertyValue ([pscustomobject]@{ url = 'https://github.com/example/repo.git'; branch = 'dist' }) -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Invoke-Script workflow-archive.ps1 myslug
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/state.json" "state.json moved"
}

Show-Summary
