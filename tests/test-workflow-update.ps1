# #61: workflow-update(upstream の更新取り込み, PowerShell版)
. "$PSScriptRoot/lib.ps1"

$script:UpstreamDir = $null

# 利用先に upstream 用の別リポジトリを作り、そこから .agents/skills を subtree add する
function Initialize-ProjectWithUpstream {
    $script:UpstreamDir = "$script:Proj/.agents/upstream"
    $null = New-Item -ItemType Directory -Force $script:UpstreamDir
    Copy-Item -Recurse "$script:RepoRoot/_templates" "$script:UpstreamDir/_templates"
    git -C $script:UpstreamDir init -q -b main 2>$null
    Assert-OwnRepo $script:UpstreamDir
    Push-Location $script:UpstreamDir
    try {
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        git add -A
        git commit -q -m "upstream init"
    } finally {
        Pop-Location
    }
    Push-Location $script:Proj
    try {
        Write-Utf8File "$script:Proj/.gitignore" ".agents/upstream/`n.agents/workflow/`n"
        git add .gitignore
        git commit -q -m "gitignore"
        git subtree add -q --prefix=.agents/skills .agents/upstream main --squash 2>$null
    } finally {
        Pop-Location
    }
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName upstream -NotePropertyValue ([ordered]@{ url = '.agents/upstream'; branch = 'main' }) -Force
    Write-Utf8File $path (($cfg | ConvertTo-Json -Depth 10) + "`n")
}

# upstream で <file> の内容を <content> にしてコミットする
function Add-UpstreamCommit {
    param([string]$File, [string]$Content)
    $full = Join-Path $script:UpstreamDir $File
    Write-Utf8File $full "$Content`n"
    Push-Location $script:UpstreamDir
    try {
        git add -A
        git commit -q -m "upstream change"
    } finally {
        Pop-Location
    }
}

function Invoke-Update {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    $errFile = [System.IO.Path]::GetTempFileName()
    Push-Location $script:Proj
    $outLines = & pwsh -NoProfile -File ".agents/skills/_templates/workflow/scripts/workflow-update.ps1" @Rest 2> $errFile
    $script:Code = $LASTEXITCODE
    Pop-Location
    $script:Out = (@($outLines) -join "`n").Trim()
    $script:Err = [System.IO.File]::ReadAllText($errFile)
    Remove-Item $errFile -Force
}

Write-Host "test-workflow-update.ps1"

Invoke-TestCase "update: upstream の更新を取り込む" {
    Initialize-ProjectWithUpstream
    Add-UpstreamCommit "_templates/new.txt" "new"
    Invoke-Update
    Add-Result ($script:Code -eq 0 -or $script:Code -eq 3) "exit 0 or 3 (got $($script:Code)): $($script:Out) $($script:Err)"
    Assert-FileExists "$script:Proj/.agents/skills/_templates/new.txt" "new.txt pulled"
    Assert-Contains $script:Out "Upstream: .agents/upstream main" "Upstream line"
}

Invoke-TestCase "update: 作業ツリーが汚れていれば exit 20" {
    Initialize-ProjectWithUpstream
    Write-Utf8File "$script:Proj/untracked.txt" "x`n"
    Invoke-Update
    Assert-Eq 20 $script:Code "exit 20"
    Assert-Eq "Next: escalate reason=dirty-tree" (@($script:Out -split "`n")[-1].Trim()) "last line"
}

Invoke-TestCase "update: コンフリクトは CONFLICT 行と exit 2" {
    Initialize-ProjectWithUpstream
    $rel = "_templates/AGENTS.md"
    $projFile = "$script:Proj/.agents/skills/$rel"
    $body = @([System.IO.File]::ReadAllLines($projFile, [System.Text.Encoding]::UTF8) | Select-Object -Skip 1)
    Write-Utf8File $projFile ((@('project side') + $body) -join "`n")
    Push-Location $script:Proj
    try {
        git add -A
        git commit -q -m "project change"
    } finally {
        Pop-Location
    }
    $upBody = @([System.IO.File]::ReadAllLines("$script:UpstreamDir/$rel", [System.Text.Encoding]::UTF8) | Select-Object -Skip 1)
    Add-UpstreamCommit $rel ((@('upstream side') + $upBody) -join "`n")
    Invoke-Update
    Assert-Eq 2 $script:Code "exit 2: $($script:Out) $($script:Err)"
    Assert-Contains $script:Out "CONFLICT .agents/skills/_templates/AGENTS.md" "CONFLICT line"
    Assert-Eq "Next: escalate reason=conflict" (@($script:Out -split "`n")[-1].Trim()) "last line"
}

Invoke-TestCase "update: 差分の確認に失敗したら exit 22" {
    Initialize-ProjectWithUpstream
    Add-UpstreamCommit "_templates/workflow/scripts/workflow-sync-scripts.ps1" "exit 1"
    Invoke-Update
    Assert-Eq 22 $script:Code "exit 22: $($script:Out) $($script:Err)"
    Assert-Eq "Next: escalate reason=sync-failed" (@($script:Out -split "`n")[-1].Trim()) "last line"
    Assert-Contains $script:Err "workflow-sync-scripts.ps1 failed" "stderr"
}

Invoke-TestCase "update: upstream.branch が main なら WARN を出して取り込みは続ける" {
    Initialize-ProjectWithUpstream
    Invoke-Update
    Add-Result ($script:Code -eq 0 -or $script:Code -eq 3) "exit 0 or 3 (got $($script:Code)): $($script:Out) $($script:Err)"
    Assert-Contains $script:Err "WARN: upstream.branch is main" "WARN"
}

Invoke-TestCase "update: upstream.branch が dist なら WARN を出さない" {
    Initialize-ProjectWithUpstream
    git -C $script:UpstreamDir branch dist 2>$null
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg.upstream.branch = 'dist'
    Write-Utf8File $path (($cfg | ConvertTo-Json -Depth 10) + "`n")
    Invoke-Update
    Add-Result ($script:Code -eq 0 -or $script:Code -eq 3) "exit 0 or 3 (got $($script:Code)): $($script:Out) $($script:Err)"
    Assert-Contains $script:Out "Upstream: .agents/upstream dist" "Upstream line"
    Assert-NotContains $script:Err "WARN: upstream.branch" "no WARN"
}

Show-Summary
