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

Show-Summary
