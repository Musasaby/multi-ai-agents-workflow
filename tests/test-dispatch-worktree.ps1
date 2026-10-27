# dispatch-worktree の create・remove・collect(PowerShell版)
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

function Write-Plain {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# 本体に base.txt(2行)を足して履歴に残し、T1 の変更対象を base.txt だけにして create する。worktree のパスを返す
function Initialize-Collect {
    Write-Plain "$script:Proj/base.txt" "line1`nline2`n"
    git -C $script:Proj add base.txt *> $null
    git -C $script:Proj commit -q -m "add base" *> $null
    Set-Tasks @'
## T1: 一番目
- **目的**: a
- **依存**: なし
- **対象**: `base.txt`(変更対象)
'@
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create exit: $($script:Err)"
    return "$script:Proj/.agents/workflow/runs/T1-1/worktree"
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

Invoke-TestCase "dispatch-worktree: collect で変更が本体に入り worktree が消える" {
    $wt = Initialize-Collect
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$wt/new.txt" "new`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-Eq "Next: review T1" (Get-LastLine) "最後の行は Next: review T1"
    Assert-Eq "line1`nfromwt`n" ([System.IO.File]::ReadAllText("$script:Proj/base.txt") -replace "`r`n", "`n") "既存ファイルの変更が本体に入る"
    Assert-FileExists "$script:Proj/new.txt" "新規ファイルが本体に入る"
    Assert-Contains $script:Out "Undeclared: new.txt" "変更対象に無い new.txt は Undeclared に出る"
    Assert-NotContains $script:Out "Undeclared: base.txt" "base.txt は Undeclared に出ない"
    Assert-FileAbsent $wt "worktree が消える"
    Add-Result (-not (Test-Branch 'agents-run/T1-1')) "ブランチが消える"
}

Invoke-TestCase "dispatch-worktree: collect で本体と衝突すると exit 40 で worktree が残る" {
    $wt = Initialize-Collect
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$script:Proj/base.txt" "line1`nfrommain`n"
    git -C $script:Proj commit -q -a -m "main change" *> $null
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 40 $script:Code "exit 40"
    Assert-Eq "Next: escalate reason=conflict" (Get-LastLine) "escalate reason=conflict"
    Add-Result (Test-Path -LiteralPath $wt -PathType Container) "worktree は残る"
}

Invoke-TestCase "dispatch-worktree: collect で本体が dirty だと exit 20" {
    $wt = Initialize-Collect
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$script:Proj/base.txt" "dirty`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 20 $script:Code "exit 20"
    Assert-Eq "Next: escalate reason=dirty-tree" (Get-LastLine) "escalate reason=dirty-tree"
    Add-Result (Test-Path -LiteralPath $wt -PathType Container) "worktree は残る"
}

Show-Summary
