# #57: dispatch-start(事前チェック〜デタッチ起動, PowerShell版)。
# gh は lib.ps1 のスタブ、子は .agents/child.sh(ダミープロジェクトで gitignore 済み)で差し替える。
. "$PSScriptRoot/lib.ps1"

function Invoke-Git {
    Push-Location $script:Proj
    & git @args 2>$null
    Pop-Location
}

function Set-StateBranch { param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

# 作業ブランチ・tasks.md・state.json・子スタブを用意する
function Initialize-StartProject {
    param([string[]]$States)
    Invoke-Git switch -q -c develop/t
    Set-Tasks @'
## T1: 一番目
- **目的**: a
- **依存**: なし

## T2: 二番目
- **目的**: b
- **依存**: T1

'@
    Set-State @States
    Set-StateBranch develop/t
    Set-GhStubResult -Stdout '[]'
    Write-Utf8File "$script:Proj/.agents/child.sh" "#!/bin/bash`necho child`n"
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'bash ./.agents/child.sh "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

# runs/<ID>/done が現れるまで最大30秒待つ(0.5秒ごと)
function Wait-Done {
    param([string]$RunId)
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path "$script:Proj/.agents/workflow/runs/$RunId/done") { return }
        Start-Sleep -Milliseconds 500
    }
}

function Get-LastLine { param([string]$Text) return ($Text -split "`n" | Select-Object -Last 1) }

Write-Host "test-dispatch-start.ps1"

Invoke-TestCase "start: 起動して prompt.md・in_progress・done ができる" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: wait" (Get-LastLine $script:Out) "last line"
    Assert-Contains $script:Out "Run: T1-1" "Run line"
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt.md"
    Assert-Eq in_progress (Get-StateTask T1).status "T1 status"
    Wait-Done T1-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/done" "done within 30s"
}

Invoke-TestCase "start: 作業ツリーが汚れていれば exit 20" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Write-Utf8File "$script:Proj/x.txt" "x`n"
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 20 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "Working tree is not clean:" "stderr"
    Assert-Eq "Next: escalate reason=dirty-tree" (Get-LastLine $script:Out) "last line"
    Assert-Eq pending (Get-StateTask T1).status "T1 status"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "no prompt"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/done" "child not started"
}

Invoke-TestCase "start: 依存が未完了なら exit 42" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Invoke-Script dispatch-start.ps1 -TaskId T2
    Assert-Eq 42 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: escalate reason=prompt-gen" (Get-LastLine $script:Out) "last line"
    Assert-Eq pending (Get-StateTask T2).status "T2 status"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T2-1/done" "child not started"
}

Invoke-TestCase "start: main 上なら exit 12" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Invoke-Git switch -q main
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 12 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: switch-branch reason=main" (Get-LastLine $script:Out) "last line"
    Assert-Eq pending (Get-StateTask T1).status "T1 status"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/done" "child not started"
}

Invoke-TestCase "start: done のタスクは exit 21" {
    Initialize-StartProject 'T1:done', 'T2:pending'
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 21 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: escalate reason=task-status" (Get-LastLine $script:Out) "last line"
    Assert-Eq done (Get-StateTask T1).status "T1 status"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/done" "child not started"
}

Show-Summary
