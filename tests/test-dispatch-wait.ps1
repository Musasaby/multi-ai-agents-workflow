# T14(#56): dispatch-wait.ps1(子の完了待ちポーリング)
. "$PSScriptRoot/lib.ps1"

# dispatch-run と同じ形式で guard.sha256 を書き(runs/<run>/prompt.md と管理ファイル)、
# dispatch-run と同じく git-state.ps1 の出力で git-state.txt も書く(test-dispatch.ps1 と同じ作り方)
function Write-Guard {
    param([string]$Run)
    Push-Location $script:Proj
    $lines = foreach ($f in @(".agents/workflow/runs/$Run/prompt.md", '.agents/workflow/state.json', '.agents/workflow/tasks.md', '.agents/workflow/config.json')) {
        $h = if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() } else { '-' }
        "$h  $f"
    }
    Pop-Location
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/guard.sha256" (($lines -join "`n") + "`n")
    Push-Location $script:Proj
    $gitState = @(& pwsh -NoProfile -File .agents/workflow/scripts/git-state.ps1)
    Pop-Location
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/git-state.txt" (($gitState -join "`n") + "`n")
}

function New-Run {
    param([string]$Exit, [string]$Log, [string]$Run = 'T1-1')
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/prompt.md" "prompt`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/done" "EXIT:$Exit`nEND:2026-01-01T00:00:00+09:00`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/output.log" "$Log`n"
    Write-Guard $Run
}

# done 無しの実行中の run(runs/T1-1/ に guard.sha256・output.log だけ)
function New-RunningRun {
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" ''
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" "running`n"
}

$report = "作業しました`n## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス"

# child_agent.timeout_seconds を設定する($Value = 秒)
function Set-TimeoutSeconds {
    param([int]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.PSObject.Properties.Remove('timeout_seconds')
    $cfg.child_agent | Add-Member -NotePropertyName timeout_seconds -NotePropertyValue $Value
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

# <ファイル> の最終更新時刻(LastWriteTimeUtc)を 60 秒前にする
function Set-Mtime60sAgo {
    param([string]$Path)
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(-60)
}

Write-Host "test-dispatch-wait.ps1"

Invoke-TestCase "wait: done があれば dispatch-check の結果を返す" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-wait.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Verdict: ok" "verdict"
    Assert-Contains $script:Out "Next: review T1" "next line"
}

Invoke-TestCase "wait: max-wait に達したら exit 2 と Next: wait" {
    New-RunningRun
    Invoke-Script dispatch-wait.ps1 -TaskId T1 -Attempt 1 -MaxWait 1 -Interval 1
    Assert-Eq 2 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Run: T1-1" "run line"
    Assert-Contains $script:Out "Status: running" "status line"
    Assert-Contains $script:Out "Elapsed: " "elapsed line"
    Assert-Contains $script:Out "Log idle: " "log idle line"
    Assert-Contains $script:Out "Log: .agents/workflow/runs/T1-1/output.log" "log line"
    Assert-Eq "Next: wait" (($script:Out -split "`n")[-1]) "last line"
}

Invoke-TestCase "wait: 経過が timeout_seconds を超えたら exit 3" {
    Set-TimeoutSeconds 5
    New-RunningRun
    Set-Mtime60sAgo "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256"
    Invoke-Script dispatch-wait.ps1 -TaskId T1 -Attempt 1 -MaxWait 10 -Interval 1
    Assert-Eq 3 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Status: running" "status line"
    Assert-Eq "Next: escalate reason=timeout" (($script:Out -split "`n")[-1]) "last line"
}

Invoke-TestCase "wait: 起動されていない run は exit 1" {
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/runs/T1-1"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" "running`n"
    Invoke-Script dispatch-wait.ps1 -TaskId T1 -Attempt 1 -MaxWait 1 -Interval 1
    Assert-Eq 1 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "not started" "stderr"
}

Show-Summary
