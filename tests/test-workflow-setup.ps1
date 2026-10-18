# #61: workflow-setup(利用先のセットアップ, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# 空の利用先(Invoke-TestCase が New-TestProject 済み): テンプレートは .agents/skills/_templates/ 配下、.agents/workflow/ と .gitignore は無い
function Initialize-EmptyProject {
    Remove-Item -Recurse -Force "$script:Proj/.agents/workflow", "$script:Proj/.gitignore" -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/skills"
    Copy-Item -Recurse "$script:RepoRoot/_templates" "$script:Proj/.agents/skills/_templates"
}

# リンク自体だけを消す(リンク先の .agents の中身を巻き込まない)
function Remove-ClaudeLink {
    $item = Get-Item "$script:Proj/.claude" -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) { $item.Delete() }
}

function Invoke-Setup {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    $errFile = [System.IO.Path]::GetTempFileName()
    Push-Location $script:Proj
    $outLines = & pwsh -NoProfile -File ".agents/skills/_templates/workflow/scripts/workflow-setup.ps1" @Rest 2> $errFile
    $script:Code = $LASTEXITCODE
    Pop-Location
    $script:Out = (@($outLines) -join "`n").Trim()
    $script:Err = [System.IO.File]::ReadAllText($errFile)
    Remove-Item $errFile -Force
}

Write-Host "test-workflow-setup.ps1"

Invoke-TestCase "setup: 空の利用先に必要なものを揃える" {
    Initialize-EmptyProject
    Invoke-Setup
    Assert-Eq 0 $script:Code "exit 0: $($script:Out) $($script:Err)"
    Assert-FileExists "$script:Proj/.agents/workflow/config.json" "config.json"
    Assert-FileExists "$script:Proj/.agents/workflow/scripts/next-task.ps1" "scripts copied"
    Assert-FileExists "$script:Proj/AGENTS.md" "AGENTS.md"
    Assert-Eq "@AGENTS.md" ([System.IO.File]::ReadAllText("$script:Proj/CLAUDE.md").Replace("`r", '').Trim()) "CLAUDE.md content"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.gitignore")) ".agents/workflow/runs/" "gitignore line"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.gitattributes")) "text eol=lf" "gitattributes line"
    $linkType = "$((Get-Item "$script:Proj/.claude" -Force -ErrorAction SilentlyContinue).LinkType)"
    Add-Result ($linkType -in @('SymbolicLink', 'Junction')) ".claude is not a link (LinkType='$linkType')"
    Remove-ClaudeLink
}

Invoke-TestCase "setup: 2回目の実行では何も変えない" {
    Initialize-EmptyProject
    Invoke-Setup
    Invoke-Setup
    Assert-Eq 0 $script:Code "2nd run exit 0: $($script:Out) $($script:Err)"
    Assert-Eq "Next: continue" (@($script:Out -split "`n")[-1].Trim()) "2nd run last line"
    Remove-ClaudeLink
    Assert-NotContains $script:Out "CREATED" "no CREATED on 2nd run"
    Assert-NotContains $script:Out "APPENDED" "no APPENDED on 2nd run"
    $gitignore = @(([System.IO.File]::ReadAllText("$script:Proj/.gitignore") -split "\r?\n"))
    Assert-Eq 1 @($gitignore | Where-Object { $_ -ceq '.agents/workflow/runs/' }).Count "runs line once"
    Assert-Eq 1 @($gitignore | Where-Object { $_ -ceq '.claude' }).Count ".claude line once"
}

Invoke-TestCase "setup: 既存の CLAUDE.md の内容は上書きせず DECIDE を出す" {
    Initialize-EmptyProject
    Write-Utf8File "$script:Proj/CLAUDE.md" "# mine`n"
    Invoke-Setup
    Assert-Eq 3 $script:Code "exit 3"
    Assert-Eq "# mine" ([System.IO.File]::ReadAllText("$script:Proj/CLAUDE.md").Trim()) "CLAUDE.md untouched"
    Assert-Contains $script:Out "DECIDE claude-md" "DECIDE claude-md"
    Assert-Eq "Next: confirm" (@($script:Out -split "`n")[-1].Trim()) "last line"
    Remove-ClaudeLink
}

Invoke-TestCase "setup: -Check は何も変えずに不足を出す" {
    Initialize-EmptyProject
    Invoke-Setup -Check
    Assert-Eq 3 $script:Code "exit 3"
    Assert-Contains $script:Out "MISSING" "MISSING listed"
    Assert-FileAbsent "$script:Proj/.agents/workflow/config.json" "nothing created"
    Assert-FileAbsent "$script:Proj/CLAUDE.md" "CLAUDE.md not created"
}

Invoke-TestCase "setup: 旧レイアウトを DECIDE で知らせる" {
    Initialize-EmptyProject
    Invoke-Setup
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/logs"
    Invoke-Setup
    Assert-Contains $script:Out "DECIDE old-layout" "old layout detected"
    Remove-ClaudeLink
}

Show-Summary
