# #17: workflow-sync-scripts(テンプレートと配置先の差分検出・反映, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# 利用先の構成を再現する: テンプレートは .agents/skills/_templates/workflow/ 配下、
# 配置先は .agents/workflow/ 配下(New-TestProject が全スクリプトを配置済み)
function Initialize-UserProject {
    $tpl = "$script:Proj/.agents/skills/_templates/workflow"
    $null = New-Item -ItemType Directory -Force "$tpl/scripts"
    Copy-Item "$script:TemplateScripts/*" "$tpl/scripts/"
    Copy-Item "$script:RepoRoot/_templates/workflow/README.md" "$tpl/README.md"
    # 差分を作る: next-task.ps1 は未配置、dispatch-run.ps1 は古い版、README.md は CRLF だけが違う
    Remove-Item "$script:Proj/.agents/workflow/scripts/next-task.ps1"
    Write-Utf8File "$script:Proj/.agents/workflow/scripts/dispatch-run.ps1" "Write-Output old`n"
    $readme = [System.IO.File]::ReadAllText("$script:RepoRoot/_templates/workflow/README.md").Replace("`r`n", "`n").Replace("`n", "`r`n")
    Write-Utf8File "$script:Proj/.agents/workflow/README.md" $readme
}

function Invoke-Sync {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    $errFile = [System.IO.Path]::GetTempFileName()
    Push-Location $script:Proj
    $outLines = & pwsh -NoProfile -File ".agents/skills/_templates/workflow/scripts/workflow-sync-scripts.ps1" @Rest 2> $errFile
    $script:Code = $LASTEXITCODE
    Pop-Location
    $script:Out = (@($outLines) -join "`n").Trim()
    $script:Err = [System.IO.File]::ReadAllText($errFile)
    Remove-Item $errFile -Force
}

Write-Host "test-sync-scripts.ps1"

Invoke-TestCase "一覧: missing/differs を表示しexit 3" {
    Initialize-UserProject
    Invoke-Sync
    Assert-Eq 3 $script:Code "differences -> exit 3: $($script:Err)"
    Assert-Contains $script:Out "missing  scripts/next-task.ps1" "missing listed"
    Assert-Contains $script:Out "differs  scripts/dispatch-run.ps1" "differs listed"
    Assert-NotContains $script:Out "README.md" "CRLF-only difference ignored"
    Assert-NotContains $script:Out "state-sync.ps1" "identical file not listed"
    Assert-FileAbsent "$script:Proj/.agents/workflow/scripts/next-task.ps1" "list mode changes nothing"
}

Invoke-TestCase "一覧: 一致ならexit 0" {
    Initialize-UserProject
    Copy-Item "$script:TemplateScripts/next-task.ps1", "$script:TemplateScripts/dispatch-run.ps1" "$script:Proj/.agents/workflow/scripts/"
    Invoke-Sync
    Assert-Eq 0 $script:Code "in sync -> exit 0: $($script:Out)"
}

Invoke-TestCase "-CopyMissing" {
    Initialize-UserProject
    Invoke-Sync '-CopyMissing'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-FileExists "$script:Proj/.agents/workflow/scripts/next-task.ps1" "missing file copied"
    Assert-Eq "Write-Output old" ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/scripts/dispatch-run.ps1").Trim()) "differing file untouched"
}

Invoke-TestCase "-Overwrite" {
    Initialize-UserProject
    Invoke-Sync '-Overwrite' 'scripts/dispatch-run.ps1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq ([System.IO.File]::ReadAllText("$script:TemplateScripts/dispatch-run.ps1")) ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/scripts/dispatch-run.ps1")) "overwritten"
    Assert-FileAbsent "$script:Proj/.agents/workflow/scripts/next-task.ps1" "other files untouched"
}

Invoke-TestCase "-Overwrite: 不明な名前は拒否" {
    Initialize-UserProject
    Invoke-Sync '-Overwrite' 'scripts/dispatch-run.ps1,scripts/nope.ps1'
    Assert-Eq 1 $script:Code "exit code"
    Assert-Eq "Write-Output old" ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/scripts/dispatch-run.ps1").Trim()) "nothing overwritten"
}

Invoke-TestCase "-Diff" {
    Initialize-UserProject
    Invoke-Sync '-Diff' 'scripts/dispatch-run.ps1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Write-Output old" "diff shows old content"
}

Invoke-TestCase "配置先のコピーからの実行は拒否" {
    Initialize-UserProject
    Push-Location $script:Proj
    & pwsh -NoProfile -File ".agents/workflow/scripts/workflow-sync-scripts.ps1" *> $null
    $code = $LASTEXITCODE
    Pop-Location
    Assert-Eq 1 $code "exit code"
}

Show-Summary
