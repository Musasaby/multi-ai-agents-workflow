# dispatch-worktree の create・remove(PowerShell版)
. "$PSScriptRoot/lib.ps1"

# $script:Out の最後の行を返す
function Get-LastLine {
    return (@($script:Out -split "`n") | Select-Object -Last 1)
}

# 本体にブランチ <name> があれば $true
function Test-Branch {
    param([string]$Name)
    git -C $script:Proj rev-parse --verify -q "refs/heads/$Name" *> $null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "test-dispatch-worktree.ps1"

Invoke-TestCase "dispatch-worktree: create で worktree・ブランチ・worktree.txt ができる" {
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "最後の行は Next: continue"
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Add-Result (Test-Path -LiteralPath "$run/worktree" -PathType Container) "worktree ができる"
    Add-Result (Test-Branch 'agents-run/T1-1') "ブランチ agents-run/T1-1 ができる"
    Assert-FileExists "$run/worktree.txt" "worktree.txt ができる"
    $lines = @([System.IO.File]::ReadAllText("$run/worktree.txt") -split "`n" | Where-Object { $_ -ne '' })
    Assert-Eq 3 $lines.Count "worktree.txt は3行"
    Add-Result ($lines[0].StartsWith('path ')) "1行目は path"
    Assert-Eq "branch refs/heads/agents-run/T1-1" $lines[1] "2行目は branch"
    $head = "$(git -C $script:Proj rev-parse HEAD)".Trim()
    Assert-Eq "base $head" $lines[2] "3行目は base <HEAD>"
    Add-Result (Test-Path -LiteralPath "$run/worktree/.agents/workflow/runs/T1-1/tmp" -PathType Container) "worktree 内に tmp ができる"
    Assert-Contains $script:Out "Carried: none" "試行 1 は持ち越しなし"

    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 30 $script:Code "2回目は exit 30"
    Assert-Eq "Next: escalate reason=worktree" (Get-LastLine) "2回目は escalate reason=worktree"
}

Invoke-TestCase "dispatch-worktree: remove で worktree とブランチが消える" {
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create exit: $($script:Err)"
    Invoke-Script dispatch-worktree.ps1 remove T1 1
    Assert-Eq 0 $script:Code "remove exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "remove は Next: continue"
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Assert-FileAbsent "$run/worktree" "worktree が消える"
    Assert-FileAbsent "$run/worktree.txt" "worktree.txt が消える"
    Add-Result (-not (Test-Branch 'agents-run/T1-1')) "ブランチが消える"

    Invoke-Script dispatch-worktree.ps1 remove T1 1
    Assert-Eq 0 $script:Code "無くても remove は exit 0"
}

Invoke-TestCase "dispatch-worktree: 試行 2 の create で前の変更を持ち越す" {
    $run1 = ".agents/workflow/runs/T1-1"
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create 1 exit: $($script:Err)"
    [System.IO.File]::WriteAllText("$script:Proj/$run1/worktree/a.txt", "hello`n", (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-FileExists "$script:Proj/a.txt" "collect で本体に a.txt が当たる"
    Assert-FileExists "$script:Proj/$run1/changes.patch" "changes.patch ができる"

    Invoke-Script dispatch-worktree.ps1 create T1 2
    Assert-Eq 0 $script:Code "create 2 exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "最後の行は Next: continue"
    Assert-Contains $script:Out "Carried: $run1/changes.patch" "試行 1 の変更を持ち越す"
    Assert-FileAbsent "$script:Proj/a.txt" "本体から a.txt が取り除かれる"
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-2/worktree/a.txt" "新しい worktree に a.txt がある"
}

Show-Summary
