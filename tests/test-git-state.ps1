# git-state(git 状態の4行出力, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# $script:Out の N 行目(1 始まり)を返す
function Get-OutLine {
    param([int]$N)
    return (@($script:Out -split "`n")[$N - 1])
}

# 等しくないことを検証する(lib.ps1 に Assert-Ne が無いため、ここで定義する)
function Assert-Ne {
    param($ExpectedNot, $Actual, [string]$Message)
    Add-Result ("$ExpectedNot" -cne "$Actual") "$Message (both lines are '$ExpectedNot')"
}

Write-Host "test-git-state.ps1"

Invoke-TestCase "git-state: 4 項目を出力する" {
    Invoke-Script git-state.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq 4 (@($script:Out -split "`n")).Count "出力は4行"
    $head = "$(git -C $script:Proj rev-parse HEAD)".Trim()
    Assert-Eq "head $head" (Get-OutLine 1) "1行目は head <HEAD の値>"
    Assert-Eq "branch refs/heads/main" (Get-OutLine 2) "2行目は branch refs/heads/main"
    Add-Result ((Get-OutLine 3) -cmatch '^refs [0-9a-f]{64}$') "3行目は refs + 16進64文字"
    Add-Result ((Get-OutLine 4) -cmatch '^config [0-9a-f]{64}$') "4行目は config + 16進64文字"
}

Invoke-TestCase "git-state: コミットで head が変わる" {
    Invoke-Script git-state.ps1
    $beforeHead = Get-OutLine 1
    $beforeConfig = Get-OutLine 4
    git -C $script:Proj commit -q --allow-empty -m x
    Invoke-Script git-state.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Ne $beforeHead (Get-OutLine 1) "コミットで head 行が変わる"
    Assert-Eq $beforeConfig (Get-OutLine 4) "config 行は同じ"
}

Invoke-TestCase "git-state: git config で config が変わる" {
    Invoke-Script git-state.ps1
    $beforeHead = Get-OutLine 1
    $beforeBranch = Get-OutLine 2
    $beforeRefs = Get-OutLine 3
    $beforeConfig = Get-OutLine 4
    git -C $script:Proj config user.name x
    Invoke-Script git-state.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Ne $beforeConfig (Get-OutLine 4) "git config で config 行が変わる"
    Assert-Eq $beforeHead (Get-OutLine 1) "head 行は変わらない"
    Assert-Eq $beforeBranch (Get-OutLine 2) "branch 行は変わらない"
    Assert-Eq $beforeRefs (Get-OutLine 3) "refs 行は変わらない"
}

Invoke-TestCase "git-state: ブランチ作成で refs が変わる" {
    Invoke-Script git-state.ps1
    $beforeHead = Get-OutLine 1
    $beforeBranch = Get-OutLine 2
    $beforeRefs = Get-OutLine 3
    $beforeConfig = Get-OutLine 4
    git -C $script:Proj branch x
    Invoke-Script git-state.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Ne $beforeRefs (Get-OutLine 3) "ブランチ作成で refs 行が変わる"
    Assert-Eq $beforeHead (Get-OutLine 1) "head 行は変わらない"
    Assert-Eq $beforeBranch (Get-OutLine 2) "branch 行は変わらない"
    Assert-Eq $beforeConfig (Get-OutLine 4) "config 行は変わらない"
}

Invoke-TestCase "git-state: detached HEAD では branch が -" {
    git -C $script:Proj checkout -q --detach
    Invoke-Script git-state.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "branch -" (Get-OutLine 2) "detached HEAD では branch -"
    $head = "$(git -C $script:Proj rev-parse HEAD)".Trim()
    Assert-Eq "head $head" (Get-OutLine 1) "head 行は HEAD の値のまま"
}

Show-Summary
