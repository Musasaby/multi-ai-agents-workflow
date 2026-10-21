# #61: workflow-update(npx skills 導入の確認と配置済みスクリプトとの差分確認, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# 利用先にテンプレートを .agents/skills/ としてコピーし、skills-lock.json を置く
function Initialize-ProjectNpx {
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/skills/agents-md-setup"
    Copy-Item -Recurse "$script:RepoRoot/agents-md-setup/templates" "$script:Proj/.agents/skills/agents-md-setup/templates"
    Copy-Item "$script:RepoRoot/agents-md-setup/templates/workflow/README.md" "$script:Proj/.agents/workflow/README.md"
    Write-Utf8File "$script:Proj/skills-lock.json" "{`"version`": 1, `"skills`": {}}`n"
}

function Invoke-Update {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    $errFile = [System.IO.Path]::GetTempFileName()
    Push-Location $script:Proj
    $outLines = & pwsh -NoProfile -File ".agents/skills/agents-md-setup/templates/workflow/scripts/workflow-update.ps1" @Rest 2> $errFile
    $script:Code = $LASTEXITCODE
    Pop-Location
    $script:Out = (@($outLines) -join "`n").Trim()
    $script:Err = [System.IO.File]::ReadAllText($errFile)
    Remove-Item $errFile -Force
}

Write-Host "test-workflow-update.ps1"

Invoke-TestCase "update: skills-lock.json が無ければ exit 2" {
    Initialize-ProjectNpx
    Remove-Item "$script:Proj/skills-lock.json" -Force
    Invoke-Update
    Assert-Eq 2 $script:Code "exit 2: $($script:Out) $($script:Err)"
    Assert-Eq "Next: escalate reason=not-npx" (@($script:Out -split "`n")[-1].Trim()) "last line"
    Assert-Contains $script:Err "skills-lock.json" "stderr"
    Assert-Contains $script:Err "workflow-update/references/migrations.md" "stderr points to migrations"
}

Invoke-TestCase "update: 差分が無ければ exit 0" {
    Initialize-ProjectNpx
    Invoke-Update
    Assert-Eq 0 $script:Code "exit 0: $($script:Out) $($script:Err)"
    Assert-Eq "Next: continue" (@($script:Out -split "`n")[-1].Trim()) "last line"
}

Invoke-TestCase "update: 配置済みスクリプトに差分があれば exit 3" {
    Initialize-ProjectNpx
    Write-Utf8File "$script:Proj/.agents/workflow/scripts/dispatch-run.ps1" "Write-Output old`n"
    Invoke-Update
    Assert-Eq 3 $script:Code "exit 3: $($script:Out) $($script:Err)"
    Assert-Contains $script:Out "differs  scripts/dispatch-run.ps1" "differs line"
    Assert-Eq "Next: confirm" (@($script:Out -split "`n")[-1].Trim()) "last line"
}

Invoke-TestCase "update: 差分の確認に失敗したら exit 22" {
    Initialize-ProjectNpx
    Write-Utf8File "$script:Proj/.agents/skills/agents-md-setup/templates/workflow/scripts/workflow-sync-scripts.ps1" "exit 1`n"
    Invoke-Update
    Assert-Eq 22 $script:Code "exit 22: $($script:Out) $($script:Err)"
    Assert-Eq "Next: escalate reason=sync-failed" (@($script:Out -split "`n")[-1].Trim()) "last line"
    Assert-Contains $script:Err "workflow-sync-scripts.ps1 failed" "stderr"
}

Show-Summary
