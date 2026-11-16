# T16: workflow-run.ps1(前提の確認・ロック・記録・タスクの起動と完了待ち, PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Invoke-Git {
    Push-Location $script:Proj
    & git @args 2>$null
    Pop-Location
}

function Get-LastLine { param([string]$Text) return ($Text -split "`n" | Select-Object -Last 1) }

# runs/<run>/done が現れるまで最大120秒待つ(0.5秒ごと)
function Wait-Done {
    param([string]$RunId)
    for ($i = 0; $i -lt 240; $i++) {
        if (Test-Path "$script:Proj/.agents/workflow/runs/$RunId/done") { return }
        Start-Sleep -Milliseconds 500
    }
}

function Set-StateBranch {
    param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

# 子のスタブの本文を差し替える(config は同じ絶対パスを指したまま)
function Set-ChildBody {
    param([string]$Body)
    Write-Utf8File "$script:Proj/.agents/child-stub.sh" ("#!/bin/bash`n" + ($Body -replace "`r`n", "`n") + "`n")
}

# 30秒眠ってから完了報告を出す子
function Set-SlowChild {
    Write-Utf8File "$script:Proj/.agents/child-stub.sh" @'
#!/bin/bash
sleep 30
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
printf 'line\n' >> "$id.txt"
echo "## 完了報告"
echo "- 変更ファイル: $id.txt"
echo "- テスト結果: 全件パス"
'@
}

# config.json の review.mode を消し、max_parallel を $MaxParallel にする
function Set-BreakPrecondition {
    param([int]$MaxParallel)
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($MaxParallel -eq 0) {
        $cfg.review.PSObject.Properties.Remove('mode')
    } else {
        $cfg.review | Add-Member -NotePropertyName mode -NotePropertyValue 'dispatch' -Force
        $cfg.max_parallel = $MaxParallel
    }
    Write-Utf8File $path ($cfg | ConvertTo-Json -Depth 10)
}

# T1.txt・T2.txt をコミットし、workflow-run を使える config.json と子のスタブを用意する
function Initialize-Runner {
    Invoke-Git switch -q -c develop/t
    Write-Utf8File "$script:Proj/T1.txt" "one`n"
    Write-Utf8File "$script:Proj/T2.txt" "one`n"
    Invoke-Git add T1.txt T2.txt
    Invoke-Git commit -q -m "add T1 T2"
    Set-Tasks @'
# タスク一覧: test

## T1: 一番目
- **目的**: a
- **対象**: T1.txt を直す
- **参照ファイル**:
  - `T1.txt`(変更対象)
- **依存**: なし

## T2: 二番目
- **目的**: b
- **対象**: T2.txt を直す
- **参照ファイル**:
  - `T2.txt`(変更対象)
- **依存**: なし
'@
    Set-State 'T1:pending' 'T2:pending'
    Set-StateBranch develop/t
    Set-GhStubResult -Stdout '[]'
    # 子は worktree の中で動く(.agents/ は worktree に無い)ため、スタブは絶対パスで指定する。
    # カレントディレクトリ(worktree)の親ディレクトリ名(T1-1)からタスクIDを取り、<ID>.txt に1行足す
    Write-Utf8File "$script:Proj/.agents/child-stub.sh" @'
#!/bin/bash
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
printf 'line\n' >> "$id.txt"
echo "## 完了報告"
echo "- 変更ファイル: $id.txt"
echo "- テスト結果: 全件パス"
'@
    # レビュー役(このタスクの範囲では使わないが、config の条件を満たすために置く)
    Write-Utf8File "$script:Proj/.agents/review-stub.sh" @'
#!/bin/bash
echo "## 完了報告"
echo "- Verdict: pass"
'@
    $bash = ((Get-Command bash).Source -replace '\\', '/')
    $child = ("$script:Proj/.agents/child-stub.sh" -replace '\\', '/')
    $review = ("$script:Proj/.agents/review-stub.sh" -replace '\\', '/')
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg.max_parallel = 2
    $cfg.verify_before_commit = $false
    $cfg.review = [pscustomobject]@{
        mode = 'dispatch'
        command_template = '"' + $bash + '" "' + $review + '" "{prompt}"'
    }
    $cfg.child_agent.command_template = '"' + $bash + '" "' + $child + '" "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

Write-Host "test-workflow-run.ps1"

Invoke-TestCase "run: 使える条件を満たさなければ runner-unsupported(exit 4)" {
    Initialize-Runner
    Set-BreakPrecondition 0
    Invoke-Script workflow-run.ps1
    Assert-Eq 4 $script:Code "review.mode が無ければ exit 4: $($script:Err)"
    Assert-Contains $script:Err "review.mode" "stderr に理由"
    Assert-Eq "Next: escalate reason=runner-unsupported" (Get-LastLine $script:Out) "最後の行"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/workflow-run/lock" "ロックを取らない"

    Set-BreakPrecondition 1
    Invoke-Script workflow-run.ps1
    Assert-Eq 4 $script:Code "max_parallel が 1 なら exit 4: $($script:Err)"
    Assert-Contains $script:Err "max_parallel" "stderr に理由"
    Assert-Eq "Next: escalate reason=runner-unsupported" (Get-LastLine $script:Out) "最後の行"
}

Invoke-TestCase "run: 生きているロックは already-running、死んでいれば引き継ぐ" {
    Initialize-Runner
    $lock = "$script:Proj/.agents/workflow/runs/workflow-run/lock"
    $null = New-Item -ItemType Directory -Force $lock
    Write-Utf8File "$lock/pid" "$PID`n"

    Invoke-Script workflow-run.ps1
    Assert-Eq 5 $script:Code "生きているロックは exit 5: $($script:Err)"
    Assert-Contains $script:Err "already running" "stderr に理由"
    Assert-Eq "Next: escalate reason=already-running" (Get-LastLine $script:Out) "最後の行"

    Write-Utf8File "$lock/pid" "999999`n"
    Set-State 'T1:done' 'T2:done'
    Set-StateBranch develop/t
    Invoke-Script workflow-run.ps1
    Assert-Eq 0 $script:Code "死んだロックは引き継ぐ: $($script:Err)"
    Assert-Eq "Next: finish" (Get-LastLine $script:Out) "最後の行"
    Assert-FileAbsent $lock "終了後にロックが消える"
}

Invoke-TestCase "run: 並列に起動し、max-wait で Next: wait を返す" {
    Initialize-Runner
    Set-SlowChild
    Invoke-Script workflow-run.ps1 -MaxWait 1 -Interval 1
    Assert-Eq 2 $script:Code "exit 2: $($script:Err)"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/done" "子の完了を待たずに max-wait で返る"
    Assert-Contains $script:Out "Started: T1-1" "T1 を起動した"
    Assert-Contains $script:Out "Started: T2-1" "T2 を起動した"
    Assert-Contains $script:Out "In flight: T1-1 running" "実行中を出す"
    Assert-Eq "Next: wait" (Get-LastLine $script:Out) "最後の行"
    $progress = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/workflow-run/progress.log")
    Assert-Contains $progress "Started: T1-1" "progress.log に記録"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/workflow-run/lock" "終了後にロックが消える"

    # 子(30秒 sleep)が終わってから一時ディレクトリを片付ける
    Wait-Done T1-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/done" "T1 の done"
    Wait-Done T2-1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T2-1/done" "T2 の done"
}

Invoke-TestCase "run: 実装の run が異常終了したら、その理由で止まる" {
    Initialize-Runner
    Set-ChildBody 'exit 1'
    Invoke-Script workflow-run.ps1 -MaxWait 60 -Interval 1
    Assert-Eq 3 $script:Code "exit 3: $($script:Err)"
    Assert-Contains $script:Out "Stopped: T1 reason=abnormal-exit" "異常終了で止まる"
    Assert-Contains $script:Out "Detail: " "詳細のパスを出す"
    Assert-Eq "Next: escalate reason=abnormal-exit" (Get-LastLine $script:Out) "最後の行"
    $first = Get-Content -LiteralPath "$script:Proj/.agents/workflow/runs/T1-1/done" -TotalCount 1
    Assert-Eq "EXIT:1" "$first" "子が実際に異常終了した"
    Wait-Done T2-1
}

Invoke-TestCase "run: 全タスク done なら Next: finish" {
    Initialize-Runner
    Set-State 'T1:done' 'T2:done'
    Set-StateBranch develop/t
    Invoke-Script workflow-run.ps1
    Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
    Assert-Eq "Next: finish" (Get-LastLine $script:Out) "最後の行"
}

Show-Summary
