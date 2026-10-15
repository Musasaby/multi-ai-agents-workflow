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

Invoke-TestCase "search: .gitなし" {
    Set-Upstream "https://github.com/someone/repo"
    Invoke-Script upstream-issue.ps1 -Search x -DryRun
    Assert-Contains $script:Out "someone/repo" "url without .git"
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

Invoke-TestCase "値の欠けたオプションでハングしない" {
    Invoke-Script upstream-issue.ps1 -Create -Title
    Assert-Eq 1 $script:Code "option without value -> exit 1"
}

Invoke-TestCase "body-file の絶対パス" {
    Write-Utf8File "$script:Proj/body.md" "x`n"
    Invoke-Script upstream-issue.ps1 -Create -Title t -BodyFile (Join-Path $script:Proj 'body.md') -DryRun
    Assert-Eq 0 $script:Code "absolute body-file path accepted: $($script:Err)"
}

Invoke-TestCase "gh スタブ: 設定しないと gh 呼び出しは失敗する" {
    # -DryRun を付け忘れると gh を実際に呼ぶ → lib の既定スタブが失敗させる(Issue F-2)
    Invoke-Script upstream-issue.ps1 -Search "signal 241"
    Assert-Eq 97 $script:Code "gh stub rejects the unexpected call: $($script:Err)"
    Assert-Contains $script:Err "unexpected call" "stderr mentions the stub"
}

Invoke-TestCase "gh スタブ: search で引数が渡り stdout が出る" {
    # -DryRun なしで search が gh を実際に呼ぶ → スタブの応答と引数を確かめる(Issue D-2)
    Set-GhStubResult -Stdout '#123 first issue'
    Invoke-Script upstream-issue.ps1 -Search signal-241
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Repository: Musasaby/multi-ai-agents-workflow" "repo line kept"
    Assert-Contains $script:Out "#123 first issue" "gh stdout passthrough"
    $log = Get-GhStubLog
    Assert-Contains $log "issue list -R Musasaby/multi-ai-agents-workflow --state all" "gh args: $log"
    Assert-Contains $log "--search signal-241 --limit 20" "query and --limit 20 in sequence: $log"
}

Invoke-TestCase "gh スタブ: create で引数が渡る" {
    Set-GhStubResult -Stdout 'https://upstream.example.com/issues/123'
    Write-Utf8File "$script:Proj/body.md" "x`n"
    Invoke-Script upstream-issue.ps1 -Create -Title t -BodyFile body.md
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "https://upstream.example.com/issues/123" "gh stdout passthrough"
    $log = Get-GhStubLog
    Assert-Contains $log "issue create -R Musasaby/multi-ai-agents-workflow --title t --body-file" "gh args: $log"
}

Invoke-TestCase "gh スタブ: gh 失敗時は同じ終了コード" {
    Set-GhStubResult -Code 4 -Stderr 'HTTP 401: Bad credentials'
    Invoke-Script upstream-issue.ps1 -Search x
    Assert-Eq 4 $script:Code "gh exit code propagated: $($script:Err)"
    Assert-Contains $script:Err "HTTP 401" "gh stderr passthrough"
}

Show-Summary
