# T10: run-phase(state.json と runs/ からタスクの段階を判定, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# runs/ 配下のファイル一覧(実行前後で増えないことを確かめる)
function Get-RunsFiles {
    Push-Location $script:Proj
    try {
        $files = @(Get-ChildItem -LiteralPath '.agents/workflow/runs' -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName.Substring($script:Proj.Length).TrimStart('\', '/') -replace '\\', '/' } |
            Sort-Object)
        return $files -join "`n"
    } finally {
        Pop-Location
    }
}

# New-RunFile <runs/ からの相対パス> → 空のファイルを作る(親ディレクトリも作る)
function New-RunFile {
    param([string]$Rel)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Rel" ''
}

# New-RunText <runs/ からの相対パス> <内容>
function New-RunText {
    param([string]$Rel, [string]$Content)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Rel" $Content
}

# Assert-Phase <期待する1行> [TaskId] → 出力・exit 0・state.json と runs/ が変わらないことを確かめる
function Assert-Phase {
    param([string]$Want, [string]$TaskId = 'T1')
    $stateBefore = Get-StateText
    $runsBefore = Get-RunsFiles
    Invoke-Script run-phase.ps1 $TaskId
    Assert-Eq 0 $script:Code "run-phase $TaskId exit: $($script:Err)"
    Assert-Eq $Want $script:Out "run-phase $TaskId output"
    Assert-Eq $stateBefore (Get-StateText) "state.json unchanged"
    Assert-Eq $runsBefore (Get-RunsFiles) "runs/ unchanged"
}

Write-Host "test-run-phase.ps1"

Invoke-TestCase "in_progress の段階を run のファイルから判定する" {
    Set-State 'T1:in_progress'
    Assert-Phase 'Phase: start 1'
    New-RunFile 'T1-1/guard.sha256'
    Assert-Phase 'Phase: running 1'
    New-RunFile 'T1-1/checked'
    Assert-Phase 'Phase: review-start 1'
    New-RunFile 'review-T1-1/guard.sha256'
    Assert-Phase 'Phase: reviewing 1'
}

Invoke-TestCase "verdict と印から collect・retry・次の試行を判定する" {
    Set-State 'T1:in_progress'
    New-RunFile 'T1-1/guard.sha256'
    New-RunFile 'T1-1/checked'
    New-RunFile 'review-T1-1/guard.sha256'
    New-RunText 'review-T1-1/verdict' "pass`n"
    Assert-Phase 'Phase: collect 1'
    New-RunText 'review-T1-1/verdict' "fail`n"
    Assert-Phase 'Phase: retry 1'
    New-RunFile 'T1-1/superseded'
    Assert-Phase 'Phase: start 2'
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/superseded" -Force
    New-RunFile 'T1-1/collected'
    Assert-Phase 'Phase: start 2'
}

Invoke-TestCase "in_review の段階を判定する" {
    Set-State 'T1:in_review:1'
    New-RunFile 'T1-1/guard.sha256'
    New-RunFile 'review-T1-1/guard.sha256'
    New-RunText 'review-T1-1/verdict' "pass`n"
    New-RunFile 'T1-1/collected'
    Assert-Phase 'Phase: gate 1'
    New-RunText 'review-T1-1/verdict' "fail`n"
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/collected" -Force
    Assert-Phase 'Phase: retry 1'
    Remove-Item "$script:Proj/.agents/workflow/runs/review-T1-1/verdict" -Force
    Assert-Phase 'Phase: manual 1'
}

Invoke-TestCase "対象外の状態と使い方の誤り" {
    Set-State 'T1:pending'
    Assert-Phase 'Phase: pending 0'
    Invoke-Script run-phase.ps1 T9
    Assert-Eq 1 $script:Code "unknown task exit 1"
    Assert-Contains $script:Err "not found" "unknown task explains"
    Invoke-Script run-phase.ps1
    Assert-Eq 1 $script:Code "no args exit 1"
    Assert-Contains $script:Err "Usage:" "no args prints usage"
    Remove-Item "$script:Proj/.agents/workflow/state.json" -Force
    Invoke-Script run-phase.ps1 T1
    Assert-Eq 1 $script:Code "no state.json exit 1"
    Assert-Contains $script:Err "state.json not found" "no state.json explains"
}

Show-Summary
