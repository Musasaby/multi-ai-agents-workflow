# #10: upstream-issue(起票先の解決・重複検索・起票, PowerShell版。gh は -DryRun で呼ばない)
. "$PSScriptRoot/lib.ps1"

function Set-Upstream {
    param([string]$Url)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($Url) { $cfg.upstream.url = $Url } else { $cfg.PSObject.Properties.Remove('upstream') }
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

Write-Host "test-upstream-issue.ps1"

Invoke-TestCase "search: https" {
    Invoke-Script upstream-issue.ps1 -Search "signal 241" -DryRun
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Musasaby/multi-ai-agents-workflow" "repo from default config"
    Assert-Contains $script:Out "gh issue list" "search command"
    Assert-Contains $script:Out "--state all" "includes closed issues"
    Assert-Contains $script:Out "signal 241" "query"
}

Invoke-TestCase "search: ssh" {
    Set-Upstream "git@github.com:someone/forked-workflow.git"
    Invoke-Script upstream-issue.ps1 -Search x -DryRun
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "someone/forked-workflow" "ssh url parsed"
    Assert-NotContains $script:Out ".git" "suffix stripped"
}

Invoke-TestCase "upstream未設定はexit 1" {
    Set-Upstream ""
    Invoke-Script upstream-issue.ps1 -Search x -DryRun
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "github以外はexit 1" {
    Set-Upstream "https://gitlab.com/a/b.git"
    Invoke-Script upstream-issue.ps1 -Search x -DryRun
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "create: dry-run" {
    Write-Utf8File "$script:Proj/body.md" "## 現象`nx`n"
    Invoke-Script upstream-issue.ps1 -Create -Title "テストの件名" -BodyFile body.md -DryRun
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "gh issue create" "create command"
    Assert-Contains $script:Out "-R Musasaby/multi-ai-agents-workflow" "explicit repo"
    Assert-Contains $script:Out "テストの件名" "title"
    Assert-NotContains $script:Out "--label" "no label"
}

Invoke-TestCase "create: title必須" {
    Write-Utf8File "$script:Proj/body.md" "x`n"
    Invoke-Script upstream-issue.ps1 -Create -BodyFile body.md -DryRun
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "create: body-file必須" {
    Invoke-Script upstream-issue.ps1 -Create -Title t -BodyFile nothing.md -DryRun
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "モード未指定はexit 1" {
    Invoke-Script upstream-issue.ps1 -DryRun
    Assert-Eq 1 $script:Code "exit code"
}

Show-Summary
