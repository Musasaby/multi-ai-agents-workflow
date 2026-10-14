# 今のブランチが作業に使ってよいかを機械的に判定する(Issue #32)。何も書き換えない。
# Usage: branch-check.ps1 [-State]
# squash マージでは git merge-base --is-ancestor が成り立たず、main から切った直後の
# 新ブランチでは逆に成り立ってしまうため、祖先判定は使わず gh の PR 状態で判定する。
# 判定順(gh を呼ばずに済む判定を先に行う):
#   1. 使い方不備・git 失敗(detached HEAD を含む)→ exit 1
#   2. 現在のブランチが main(config.json の upstream.branch があればその名前も)→ exit 2
#   3. -State 指定時、state.json の branch と現在のブランチが異なる → exit 5
#      (state.json が無い・branch が空の場合はこの判定を飛ばす)
#   4. gh が無い・認証切れ等で PR 状態を取得できない → exit 4
#   5. 現在のブランチの PR がマージ済み → stdout "MERGED <PR URL>"、exit 3
#   6. いずれにも当たらない → stdout "OK <ブランチ名>"、exit 0
# gh pr list --head <branch> --state merged は、一致する PR が無ければ [] を出力して exit 0。
# (古い gh が「no pull requests found」で失敗した場合も PR なしとして扱う)
# exit: 0=使ってよい / 1=使い方・git 失敗 / 2=main 上 / 3=PR マージ済み / 4=gh で判定不能
#       5=state.json の branch と不一致
param(
    [switch]$State,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$usage = 'Usage: branch-check.ps1 [-State]'

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

# Get-JsonField <path> <dotted.key> → 値(無い・読めない場合は空文字列)
function Get-JsonField {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return '' }
    try {
        $value = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return ''
    }
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $value -or -not ($value -is [System.Management.Automation.PSCustomObject])) { return '' }
        if (-not $value.PSObject.Properties[$part]) { return '' }
        $value = $value.$part
    }
    if ($value -is [string]) { return $value }
    return ''
}

if ($Rest -and $Rest.Count -gt 0) { Fail "Unknown argument: $($Rest -join ' ')`n$usage" }

Set-Location $PSScriptRoot\..\..\..
$statePath = '.agents/workflow/state.json'
$configPath = '.agents/workflow/config.json'

# --- 1. 現在のブランチ ---
$branchOut = @(& git branch --show-current 2>&1 | ForEach-Object { "$_" })
$gitCode = $LASTEXITCODE
if ($gitCode -ne 0) { Fail "git branch --show-current failed (exit $gitCode): $($branchOut -join "`n")" }
$branch = ($branchOut -join '').Trim()
if (-not $branch) { Fail 'HEAD is detached (switch to a work branch first)' }

# --- 2. main 上 ---
$upstreamBranch = Get-JsonField $configPath 'upstream.branch'
if ($branch -ceq 'main' -or ($upstreamBranch -and $branch -ceq $upstreamBranch)) {
    Fail "On '$branch': do not work on the main branch (create a develop/<name> branch from the latest origin/main)" 2
}

# --- 3. state.json の branch との一致(-State 指定時のみ) ---
if ($State) {
    $stateBranch = Get-JsonField $statePath 'branch'
    if ($stateBranch -and $stateBranch -cne $branch) {
        Fail "Current branch '$branch' differs from state.json's branch '$stateBranch' (switch to '$stateBranch', or update state.json if the workflow moved)" 5
    }
}

# --- 4・5. PR 状態(マージ済みか) ---
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "gh not found: cannot check whether '$branch' has a merged PR" 4
}

$errFile = [System.IO.Path]::GetTempFileName()
try {
    $ghOut = & gh pr list --head $branch --state merged --json url --limit 1 2> $errFile
    $ghCode = $LASTEXITCODE
    $ghErr = [System.IO.File]::ReadAllText($errFile)
} catch {
    $ghCode = 127
    $ghErr = $_.Exception.Message
} finally {
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}

if ($ghCode -ne 0) {
    if ($ghErr -match '(?i)no pull request') {
        Write-Output "OK $branch"
        exit 0
    }
    Fail "gh pr list failed (exit $ghCode): cannot check whether '$branch' has a merged PR: $ghErr" 4
}

$ghJson = (@($ghOut) -join "`n").Trim()
if (-not $ghJson) { $ghJson = '[]' }
if (-not $ghJson.StartsWith('[')) {
    Fail "Failed to parse gh pr list output (expected a JSON list): $ghJson" 4
}
try {
    # Windows PowerShell 5.1 は配列を1オブジェクトとして、PowerShell 7 は要素ごとに出力するため、
    # ForEach-Object で要素に展開してからまとめる(どちらでも [] は 0 件になる)
    $prs = @($ghJson | ConvertFrom-Json | ForEach-Object { $_ })
} catch {
    Fail "Failed to parse gh pr list output (expected a JSON list): $ghJson" 4
}

if ($prs.Count -gt 0) {
    $url = "$($prs[0].url)"
    if (-not $url) { $url = '(unknown URL)' }
    Write-Output "MERGED $url"
    exit 3
}

Write-Output "OK $branch"
exit 0
