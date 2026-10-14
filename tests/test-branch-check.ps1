# #32: branch-check(作業ブランチが使ってよいかの判定, PowerShell版)。
# gh を PATH 先頭に置いたスタブ(gh.cmd)で差し替え、判定ごとの exit code と stdout、
# -State の判定が gh より先に行われること、何も書き換えないことを検証する。
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

# Set-GhStub <NONE|NO_PR_MESSAGE|MERGED|FAIL> [url]
function Set-GhStub {
    param([string]$Scenario, [string]$Url = '')
    Remove-Item $script:GhStubLog -Force -ErrorAction SilentlyContinue
    $env:GH_STUB_LOG = $script:GhStubLog
    $env:GH_STUB_CODE = '0'
    $env:GH_STUB_STDOUT = ''
    $env:GH_STUB_STDERR = ''
    switch ($Scenario) {
        # 実 gh は一致する PR が無いとき [] を出力して exit 0
        'NONE' { $env:GH_STUB_STDOUT = '[]' }
        # 古い gh の「PR が見つからない」失敗(PR なしとして扱う)
        'NO_PR_MESSAGE' {
            $env:GH_STUB_CODE = '1'
            $env:GH_STUB_STDERR = 'no pull requests found for branch "develop/g1"'
        }
        'MERGED' { $env:GH_STUB_STDOUT = '[{"url":"' + $Url + '"}]' }
        'FAIL' {
            $env:GH_STUB_CODE = '4'
            $env:GH_STUB_STDERR = 'HTTP 401: Bad credentials'
        }
    }
}

function Get-StubLog {
    if (Test-Path $script:GhStubLog) { return [System.IO.File]::ReadAllText($script:GhStubLog) }
    return ''
}

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

# 作業ブランチ develop/g1 に切り替え、state.json の branch を develop/g1 にする
function Initialize-WorkBranch {
    Invoke-Git checkout -q -b develop/g1
    Set-State 'T1:pending'
    Set-StateBranch develop/g1
}

# 作業ツリー・state.json の状態(実行前後で一致することを確かめる)
function Get-Snapshot {
    Push-Location $script:Proj
    $status = (@(git status --porcelain) + @(git branch --show-current)) -join "`n"
    Pop-Location
    $state = ''
    if (Test-Path "$script:Proj/.agents/workflow/state.json") { $state = Get-StateText }
    return "$status`n$state"
}

Write-Host "test-branch-check.ps1"

Invoke-TestCase "branch-check: main 上は exit 2" {
    Set-GhStub NONE
    Invoke-Script branch-check.ps1
    Assert-Eq 2 $script:Code "exit code: $($script:Err)"
    Assert-Eq "" $script:Out "stdout empty"
    Assert-Contains $script:Err "main" "stderr explains"
    Assert-Eq "" (Get-StubLog) "gh not called"
}

Invoke-TestCase "branch-check: config の upstream.branch 上も exit 2" {
    Invoke-Git checkout -q -b trunk
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.upstream = [pscustomobject]@{ url = 'https://github.com/example/repo.git'; branch = 'trunk' }
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Set-GhStub NONE
    Invoke-Script branch-check.ps1
    Assert-Eq 2 $script:Code "upstream.branch is treated as main: $($script:Err)"
}

Invoke-TestCase "branch-check: マージ済み PR ありは exit 3 と MERGED <URL>" {
    Initialize-WorkBranch
    Set-GhStub MERGED 'https://example.com/pr/1'
    $before = Get-Snapshot
    Invoke-Script branch-check.ps1
    Assert-Eq 3 $script:Code "exit code: $($script:Err)"
    Assert-Eq "MERGED https://example.com/pr/1" $script:Out "stdout has the PR URL"
    Assert-Contains (Get-StubLog) "pr list --head develop/g1 --state merged" "gh asked for merged PRs of the branch"
    Assert-Eq $before (Get-Snapshot) "nothing changed"
}

Invoke-TestCase "branch-check: PR なし([])は exit 0 と OK <branch>" {
    Initialize-WorkBranch
    Set-GhStub NONE
    $before = Get-Snapshot
    Invoke-Script branch-check.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "OK develop/g1" $script:Out "stdout"
    Assert-Eq $before (Get-Snapshot) "nothing changed"
}

Invoke-TestCase "branch-check: gh の「no pull requests found」失敗も PR なし扱い" {
    Initialize-WorkBranch
    Set-GhStub NO_PR_MESSAGE
    Invoke-Script branch-check.ps1
    Assert-Eq 0 $script:Code "'no pull requests found' failure is treated as no PR: $($script:Err)"
    Assert-Eq "OK develop/g1" $script:Out "stdout"
}

Invoke-TestCase "branch-check: OPEN の PR のみは exit 0" {
    # OPEN の PR しか無いブランチでは、--state merged の結果は空になる
    Initialize-WorkBranch
    Set-GhStub NONE
    Invoke-Script branch-check.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains (Get-StubLog) "--state merged" "only merged PRs are asked for"
}

Invoke-TestCase "branch-check: gh 失敗は exit 4" {
    Initialize-WorkBranch
    Set-GhStub FAIL
    Invoke-Script branch-check.ps1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Eq "" $script:Out "stdout empty"
    Assert-Contains $script:Err "Bad credentials" "stderr includes gh's message"
}

Invoke-TestCase "branch-check: gh の出力が解析できなければ exit 4" {
    Initialize-WorkBranch
    Set-GhStub NONE
    $env:GH_STUB_STDOUT = 'not json'
    Invoke-Script branch-check.ps1
    Assert-Eq 4 $script:Code "unparsable gh output: $($script:Err)"
}

Invoke-TestCase "branch-check: -State で state.json と不一致は exit 5(gh を呼ばない)" {
    Initialize-WorkBranch
    Set-StateBranch develop/other
    Set-GhStub MERGED 'https://example.com/pr/1'
    Invoke-Script branch-check.ps1 '-State'
    Assert-Eq 5 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Err "develop/g1" "stderr shows the current branch"
    Assert-Contains $script:Err "develop/other" "stderr shows the state branch"
    Assert-Eq "" (Get-StubLog) "gh not called"
}

Invoke-TestCase "branch-check: -State で一致すれば exit 0" {
    Initialize-WorkBranch
    Set-GhStub NONE
    Invoke-Script branch-check.ps1 '-State'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq "OK develop/g1" $script:Out "stdout"
}

Invoke-TestCase "branch-check: -State なしでは state.json を見ない" {
    Initialize-WorkBranch
    Set-StateBranch develop/other
    Set-GhStub NONE
    Invoke-Script branch-check.ps1
    Assert-Eq 0 $script:Code "state.json is not checked without -State: $($script:Err)"
}

Invoke-TestCase "branch-check: state.json 無しは -State でも判定を飛ばす" {
    Invoke-Git checkout -q -b develop/g1
    Remove-Item "$script:Proj/.agents/workflow/state.json" -Force -ErrorAction SilentlyContinue
    Set-GhStub NONE
    Invoke-Script branch-check.ps1 '-State'
    Assert-Eq 0 $script:Code "missing state.json skips the check: $($script:Err)"
    Assert-Eq "OK develop/g1" $script:Out "stdout"
}

Invoke-TestCase "branch-check: main の判定は state.json の判定より先" {
    # main 上では state.json と不一致でも exit 2(判定順 2 が 3 より先)
    Set-State 'T1:pending'
    Set-StateBranch develop/other
    Set-GhStub NONE
    Invoke-Script branch-check.ps1 '-State'
    Assert-Eq 2 $script:Code "main is checked first: $($script:Err)"
}

Invoke-TestCase "branch-check: detached HEAD は exit 1" {
    Invoke-Git checkout -q --detach
    Set-GhStub NONE
    Invoke-Script branch-check.ps1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "detached" "stderr explains"
}

Invoke-TestCase "branch-check: 不明な引数は exit 1" {
    Set-GhStub NONE
    Invoke-Script branch-check.ps1 'bogus'
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err "Usage" "usage shown"
    Assert-Eq "" (Get-StubLog) "gh not called"
}

# PATH を元に戻し、スタブを削除してから集計する
$env:PATH = ($env:PATH -replace [regex]::Escape("$ghStubDir;"), '')
Remove-Item $ghStubDir -Recurse -Force -ErrorAction SilentlyContinue
Show-Summary
