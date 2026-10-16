# lib-guard(tests/lib.ps1 の git 閉じ込めガード, PowerShell版)
. "$PSScriptRoot/lib.ps1"

$script:LibPs1 = Join-Path $PSScriptRoot 'lib.ps1'

# 外側のリポジトリ($script:Proj)の状態(コミット数と .git/config の内容)
function Get-OuterState { "$(git -C $script:Proj rev-list --count HEAD)|$([System.IO.File]::ReadAllText("$script:Proj/.git/config"))" }

# 別プロセスで lib を読み込んで $Body を実行する → $script:Out / $script:Err / $script:Code
function Invoke-InChild {
    param([string]$Body)
    $tmp = Join-Path $script:Proj 'tmp'; $inner = Join-Path $script:Proj 'inner'
    $null = New-Item -ItemType Directory -Force $tmp, $inner
    $saved = @{ TEMP = $env:TEMP; TMP = $env:TMP }
    $env:LIB_PS1 = $script:LibPs1; $env:INNER = $inner; $env:TEMP = $tmp; $env:TMP = $tmp
    try {
        $errFile = Join-Path $script:Proj 'child.err'
        $outLines = & pwsh -NoProfile -Command $Body 2> $errFile
        $script:Code = $LASTEXITCODE
    } finally {
        $env:TEMP = $saved.TEMP; $env:TMP = $saved.TMP; $env:LIB_PS1 = $null; $env:INNER = $null
    }
    $script:Out = (@($outLines) -join "`n")
    $script:Err = [System.IO.File]::ReadAllText($errFile)
}

Write-Host "test-lib-guard.ps1"

Invoke-TestCase "guard: .git の無いディレクトリは assert_own_repo で失敗する" {
    $before = Get-OuterState
    Invoke-InChild '. $env:LIB_PS1; Assert-OwnRepo $env:INNER'
    Assert-Eq 1 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Err "FATAL: test project is not its own git repository" "fatal message"
    Assert-Eq $before (Get-OuterState) "外側のリポジトリは変化しない"
}

Invoke-TestCase "guard: GIT_CEILING_DIRECTORIES があれば外側のリポジトリに届かない" {
    $before = Get-OuterState
    Invoke-InChild '. $env:LIB_PS1; $d = Join-Path $env:TEMP ''nogit''; $null = New-Item -ItemType Directory -Force $d; git -C $d rev-parse --show-toplevel; exit $LASTEXITCODE'
    Assert-Eq 128 $script:Code "exit: $($script:Err)"
    Assert-Eq $before (Get-OuterState) "外側のリポジトリは変化しない"
}

Invoke-TestCase "guard: 外側のリポジトリ内でも new_project はダミー自身のリポジトリになる" {
    $before = Get-OuterState
    Invoke-InChild '. $env:LIB_PS1; New-TestProject; Write-Output OK'
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Out "OK" "new_project がダミー自身のリポジトリを作る"
    Assert-Eq $before (Get-OuterState) "外側のリポジトリは変化しない"
}

Show-Summary
