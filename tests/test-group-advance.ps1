# T3: group-advance(グループ完了後の PR 状態判定とブランチ切替, PowerShell版)。
# gh を PATH 先頭に置いたスタブ(gh.cmd)で差し替え、PR 状態(NO_PR / OPEN / CLOSED / MERGED)
# ごとの exit code と、MERGED 時のブランチ作成・切替・state.json 更新を検証する。
. "$PSScriptRoot/lib.ps1"

# --- gh スタブ(gh.cmd を PATH 先頭に置き、環境変数で挙動を切り替える) ---
$ghStubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gh-stub-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force $ghStubDir
$stubCmd = @'
@echo off
if "%GH_STUB_CODE%"=="" set GH_STUB_CODE=0
if not "%GH_STUB_LOG%"=="" echo %*>>"%GH_STUB_LOG%"
if not "%GH_STUB_STDOUT%"=="" echo %GH_STUB_STDOUT%
if not "%GH_STUB_STDERR%"=="" echo %GH_STUB_STDERR% 1>&2
exit /b %GH_STUB_CODE%
'@
[System.IO.File]::WriteAllText((Join-Path $ghStubDir 'gh.cmd'), $stubCmd)
$env:PATH = "$ghStubDir;$env:PATH"
$script:GhStubLog = Join-Path $ghStubDir 'log.txt'

# Set-GhStub <NO_PR|OPEN|CLOSED|MERGED|FAIL> [url] [code]
function Set-GhStub {
    param([string]$Scenario, [string]$Url = '', [int]$Code = 0)
    Remove-Item $script:GhStubLog -Force -ErrorAction SilentlyContinue
    $env:GH_STUB_LOG = $script:GhStubLog
    $env:GH_STUB_CODE = "$Code"
    $env:GH_STUB_STDOUT = ''
    $env:GH_STUB_STDERR = ''
    switch ($Scenario) {
        'NO_PR' {
            # 実 gh と同じ「PR が見つからない」メッセージと exit 1 を再現する
            $env:GH_STUB_CODE = '1'
            $env:GH_STUB_STDERR = 'no pull requests found for branch "develop/g1"'
        }
        'OPEN'   { $env:GH_STUB_STDOUT = '{"state":"OPEN","url":"' + $Url + '"}' }
        'CLOSED' { $env:GH_STUB_STDOUT = '{"state":"CLOSED","url":"' + $Url + '"}' }
        'MERGED' { $env:GH_STUB_STDOUT = '{"state":"MERGED","url":"' + $Url + '"}' }
        'FAIL'   { $env:GH_STUB_STDERR = 'gh stub failure' }
    }
}

# グループ P(T1)・A(T2, T3)。既定グループにタスクは無い
$paTasks = @'
<!-- グループ P -->

## T1: Pの処理
- **目的**: p
- **依存**: なし

<!-- グループ A -->

## T2: Aの処理
- **目的**: a
- **依存**: T1

## T3: Aの処理2
- **目的**: b
- **依存**: T2
'@

# origin(bare)付きのリポジトリに develop/g1 ブランチを用意し、
# state.json を「作業グループ P が完了・ブランチ develop/g1」に揃える
function Initialize-AdvanceProject {
    # テストケースが作ったダミープロジェクト($script:Proj)をそのまま使う(作り直さない)
    Push-Location $script:Proj
    try {
        git init -q --bare -b main .agents/remote.git 2>$null
        git remote add origin .agents/remote.git
        Set-Content a.txt 'a'; git add a.txt; git commit -q -m "init main"
        git push -q -u origin main 2>$null
        git checkout -q -b develop/g1 2>$null
        Set-Content b.txt 'b'; git add b.txt; git commit -q -m "feat: g1"
    } finally {
        Pop-Location
    }
    Set-Tasks $paTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Set-StateGroup P
    Set-StateBranch develop/g1
}

function Set-StateBranch { param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

function Get-StateBranch {
    return [string]((ConvertFrom-Json (Get-StateText)).branch)
}

function Get-CurrentBranch {
    Push-Location $script:Proj
    $branch = (git branch --show-current)
    Pop-Location
    return ("$branch").Trim()
}

Write-Host "test-group-advance.ps1"

Invoke-TestCase "advance: PR なしは exit 7" {
    Initialize-AdvanceProject
    Set-GhStub NO_PR
    Invoke-Script group-advance.ps1
    Assert-Eq 7 $script:Code "exit code: $($script:Err)"
    Assert-Eq "NO_PR" $script:Out "stdout"
    Assert-Contains ([System.IO.File]::ReadAllText($script:GhStubLog)) "view develop/g1" "gh called with the state branch"
    Assert-Eq "develop/g1" (Get-StateBranch) "state.json unchanged"
    Assert-Eq "P" (Get-StateGroup) "group unchanged"
}

Invoke-TestCase "advance: OPEN は exit 8" {
    Initialize-AdvanceProject
    Set-GhStub OPEN 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1
    Assert-Eq 8 $script:Code "exit code: $($script:Err)"
    Assert-Eq "OPEN https://example.com/pr/1" $script:Out "stdout has the PR URL"
    Assert-Eq "P" (Get-StateGroup) "group unchanged"
}

Invoke-TestCase "advance: CLOSED は exit 9" {
    Initialize-AdvanceProject
    Set-GhStub CLOSED 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1
    Assert-Eq 9 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "CLOSED" "stderr explains the closed PR"
    Assert-Eq "develop/g1" (Get-StateBranch) "state.json unchanged"
}

Invoke-TestCase "advance: MERGED はブランチ作成と state 更新" {
    Initialize-AdvanceProject
    Set-GhStub MERGED 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1 '-Branch' 'develop/g2'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "ADVANCED develop/g2 A" $script:Out "stdout shows the new branch and group"
    Assert-Eq "develop/g2" (Get-CurrentBranch) "switched to the new branch"
    Assert-Eq "develop/g2" (Get-StateBranch) "state.json branch updated"
    Assert-Eq "A" (Get-StateGroup) "state.json group updated to the next group"
}

Invoke-TestCase "advance: MERGED は main を origin/main まで進める" {
    Initialize-AdvanceProject
    # origin/main にだけあるコミットを用意し、ローカル main を古くしておく
    Push-Location $script:Proj
    git clone -q .agents/remote.git .agents/other-clone 2>$null
    Push-Location .agents/other-clone
    git config user.email "test@example.com"
    git config user.name "test"
    Set-Content c.txt 'c'; git add c.txt; git commit -q -m "on origin"
    git push -q origin main 2>$null
    Pop-Location
    $oldMain = ("$(git rev-parse main)").Trim()
    $bareMain = (git --git-dir=.agents/remote.git rev-parse main)
    Pop-Location
    Set-GhStub MERGED 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1 '-Branch' 'develop/g2'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Push-Location $script:Proj
    $newMain = ("$(git rev-parse main)").Trim()
    $newOriginMain = ("$(git rev-parse origin/main)").Trim()
    Pop-Location
    Assert-Eq ("$bareMain").Trim() $newOriginMain "origin/main fast-forwarded to the remote tip"
    Assert-Eq ("$bareMain").Trim() $newMain "main fast-forwarded to origin/main"
    Assert-NotContains $newMain $oldMain "main actually moved"
}

Invoke-TestCase "advance: MERGED で -Branch 無しは exit 1" {
    Initialize-AdvanceProject
    Set-GhStub MERGED 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "-Branch" "usage shown"
    Assert-Eq "develop/g1" (Get-CurrentBranch) "still on the work branch"
    Assert-Eq "develop/g1" (Get-StateBranch) "state.json unchanged"
    Assert-Eq "P" (Get-StateGroup) "group unchanged"
}

Invoke-TestCase "advance: develop/ 以外の -Branch は exit 1" {
    Initialize-AdvanceProject
    Set-GhStub MERGED 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1 '-Branch' 'feature/x'
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "develop/" "stderr explains the prefix rule"
    Assert-Eq "P" (Get-StateGroup) "state.json unchanged"
}

Invoke-TestCase "advance: 作業ツリーが汚れていると exit 1" {
    Initialize-AdvanceProject
    Set-GhStub MERGED 'https://example.com/pr/1'
    Set-Content "$script:Proj/dirt.txt" 'x'
    Invoke-Script group-advance.ps1 '-Branch' 'develop/g2'
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "clean" "stderr explains the dirty tree"
    Assert-Eq "develop/g1" (Get-CurrentBranch) "branch unchanged"
    Assert-Eq "P" (Get-StateGroup) "state.json unchanged"
}

Invoke-TestCase "advance: 作業グループ未完了は exit 1" {
    Initialize-AdvanceProject
    # 作業グループ P は T1 のみ。T1 が未完了なら境界ではない
    Set-State 'T1:in_review' 'T2:pending' 'T3:pending'
    Set-StateGroup P
    Set-StateBranch develop/g1
    Set-GhStub NO_PR
    Invoke-Script group-advance.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Eq "" $script:Out "stdout empty"
    Assert-Contains $script:Err "T1" "stderr names the unfinished task"
    Assert-Eq "P" (Get-StateGroup) "group unchanged"
    Assert-Eq "develop/g1" (Get-StateBranch) "state.json unchanged"
}

Invoke-TestCase "advance: 未知のグループ名は exit 1" {
    Initialize-AdvanceProject
    Set-StateGroup ZZZ
    Invoke-Script group-advance.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "group" "stderr explains"
    Assert-Eq "ZZZ" (Get-StateGroup) "state.json unchanged"
}

Invoke-TestCase "advance: gh 失敗は exit code を返す" {
    Initialize-AdvanceProject
    Set-GhStub FAIL -Code 4
    Invoke-Script group-advance.ps1
    Assert-Eq 4 $script:Code "gh's exit code is returned"
    Assert-Contains $script:Err "gh pr view failed" "stderr explains"
    Assert-Eq "P" (Get-StateGroup) "state.json unchanged"
}

Invoke-TestCase "advance: 全タスク完了で切替先が無ければ exit 1" {
    Initialize-AdvanceProject
    Set-State 'T1:done' 'T2:done' 'T3:done'
    Set-StateGroup P
    Set-StateBranch develop/g1
    Set-GhStub MERGED 'https://example.com/pr/1'
    Invoke-Script group-advance.ps1 '-Branch' 'develop/g2'
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "unfinished" "stderr explains no next group"
    Assert-Eq "P" (Get-StateGroup) "state.json unchanged"
}

# PATH を元に戻し、スタブを削除してから集計する
$env:PATH = ($env:PATH -replace [regex]::Escape("$ghStubDir;"), '')
Remove-Item $ghStubDir -Recurse -Force -ErrorAction SilentlyContinue
Show-Summary
