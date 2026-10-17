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

Invoke-TestCase "start: 戻った時点で guard.sha256 がある" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" "guard.sha256 on return"
    Wait-Done T1-1
}

Invoke-TestCase "start: dispatch-run が起動しなければ exit 60" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Remove-Item "$script:Proj/.agents/workflow/scripts/dispatch-run.ps1"
    $env:DISPATCH_START_LAUNCH_TIMEOUT = '2'
    try {
        Invoke-Script dispatch-start.ps1 -TaskId T1
    } finally {
        Remove-Item Env:DISPATCH_START_LAUNCH_TIMEOUT
    }
    Assert-Eq 60 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: escalate reason=launch" (Get-LastLine $script:Out) "last line"
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

Invoke-TestCase "start: リトライ(fix-notes あり)は作業ツリーが汚れていても起動する" {
    Initialize-StartProject 'T1:in_progress', 'T2:pending'
    Write-Utf8File "$script:Proj/x.txt" "x`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-2/fix-notes.md" "fix`n"
    Invoke-Script dispatch-start.ps1 -TaskId T1 -Attempt 2
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: wait" (Get-LastLine $script:Out) "last line"
    Wait-Done T1-2
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-2/done" "done within 30s"
    Assert-Eq in_progress (Get-StateTask T1).status "T1 status"
}

Invoke-TestCase "start: リトライでも fix-notes が無ければ exit 20" {
    Initialize-StartProject 'T1:in_progress', 'T2:pending'
    Write-Utf8File "$script:Proj/x.txt" "x`n"
    Invoke-Script dispatch-start.ps1 -TaskId T1 -Attempt 2
    Assert-Eq 20 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: escalate reason=dirty-tree" (Get-LastLine $script:Out) "last line"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-2/done" "child not started"
}

Invoke-TestCase "start: 試行回数 0 は exit 1" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Invoke-Script dispatch-start.ps1 -TaskId T1 -Attempt 0
    Assert-Eq 1 $script:Code "exit code: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-0/done" "child not started"
}

Invoke-TestCase "start: リトライで fix-notes が無ければ stderr に案内を出す" {
    Initialize-StartProject 'T1:in_progress', 'T2:pending'
    Write-Utf8File "$script:Proj/x.txt" "x`n"
    Invoke-Script dispatch-start.ps1 -TaskId T1 -Attempt 2
    Assert-Eq 20 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "fix-notes.md not found" "stderr"
}

function Set-ChildCfg { param([string]$Key, $Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

Invoke-TestCase "start: healthcheck_command が失敗すれば exit 30" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Set-ChildCfg healthcheck_command 'exit 3'
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 30 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: escalate reason=healthcheck" (Get-LastLine $script:Out) "last line"
    Assert-Eq pending (Get-StateTask T1).status "T1 status"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/done" "child not started"
}

Invoke-TestCase "start: warmup_command は最初の dispatch だけ実行する" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Set-ChildCfg warmup_command 'Add-Content .agents/warmup.log w'
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 0 $script:Code "exit code (T1): $($script:Err)"
    Wait-Done T1-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/done" "T1 done"
    Set-Report T1 1
    Set-State 'T1:done' 'T2:pending'
    Set-StateBranch develop/t
    Invoke-Script dispatch-start.ps1 -TaskId T2
    Assert-Eq 0 $script:Code "exit code (T2): $($script:Err)"
    Wait-Done T2-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T2-1/done" "T2 done"
    Assert-Eq 1 @(Get-Content "$script:Proj/.agents/warmup.log").Count "warmup.log lines"
}

Invoke-TestCase "start: warmup_command が失敗すれば exit 31" {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Set-ChildCfg warmup_command 'exit 1'
    Invoke-Script dispatch-start.ps1 -TaskId T1
    Assert-Eq 31 $script:Code "exit code: $($script:Err)"
    Assert-Eq "Next: escalate reason=warmup" (Get-LastLine $script:Out) "last line"
    Assert-Eq pending (Get-StateTask T1).status "T1 status"
}

# -Pr 用: origin(bare)付きで develop/t に1コミットし、T1 を done(commit=そのハッシュ)にする
function Initialize-PrProject {
    Initialize-StartProject 'T1:pending', 'T2:pending'
    Push-Location $script:Proj
    git switch -q main 2>$null
    git init -q --bare -b main .agents/remote.git 2>$null
    git remote add origin .agents/remote.git
    git push -q -u origin main 2>$null
    git switch -q develop/t 2>$null
    Set-Content b.txt 'b'; git add b.txt; git commit -q -m "feat: t1"
    $h = "$(git rev-parse --short HEAD)".Trim()
    Pop-Location
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $t1 = $state.tasks | Where-Object { $_.id -ceq 'T1' }
    $t1.status = 'done'
    $t1.commit = $h
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

Invoke-TestCase "start: -Pr は pr-<N> の run を起動する" {
    Initialize-PrProject
    Invoke-Script dispatch-start.ps1 '-Pr'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Run: pr-" "Run line"
    Assert-Eq "Next: wait" (Get-LastLine $script:Out) "last line"
    $run = (($script:Out -split "`n" | Where-Object { $_ -match '^Run: ' } | Select-Object -First 1) -replace '^Run: ', '').Trim()
    Wait-Done $run
    Assert-FileExists "$script:Proj/.agents/workflow/runs/$run/done" "done within 30s"
}

Invoke-TestCase "start: -Pr で main 上なら exit 12" {
    Initialize-StartProject 'T1:done', 'T2:pending'
    Invoke-Git switch -q main
    Invoke-Script dispatch-start.ps1 '-Pr'
    Assert-Eq 12 $script:Code "exit code: $($script:Err)"
}

Show-Summary
