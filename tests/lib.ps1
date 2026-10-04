# テスト共通ヘルパー(PowerShell版スクリプト用)。
# 一時ディレクトリにダミーの利用先プロジェクト(.agents/workflow/ 一式 + git リポジトリ)を作り、
# _templates/workflow/scripts/ のスクリプトをコピーして実行する。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
$script:TemplateScripts = Join-Path $script:RepoRoot '_templates/workflow/scripts'
$script:PassCount = 0
$script:FailCount = 0
$script:FailedNames = @()
$script:CurrentTest = ''
$script:Proj = $null

function New-TestProject {
    $script:Proj = Join-Path ([System.IO.Path]::GetTempPath()) ("wf-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/scripts", "$script:Proj/.agents/workflow/runs"
    Copy-Item "$script:TemplateScripts/*" "$script:Proj/.agents/workflow/scripts/"
    Copy-Item "$script:RepoRoot/_templates/workflow/config.json" "$script:Proj/.agents/workflow/config.json"
    Push-Location $script:Proj
    git init -q -b main 2>$null
    git config user.email "test@example.com"
    git config user.name "test"
    git config core.autocrlf false
    Set-Content -Path .gitignore -Value '.agents/' -NoNewline
    git add .gitignore
    git commit -q -m "init"
    Pop-Location
}

function Remove-TestProject {
    if ($script:Proj) { Remove-Item -Recurse -Force $script:Proj -ErrorAction SilentlyContinue }
    $script:Proj = $null
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Force $dir }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Set-Tasks { param([string]$Content) Write-Utf8File "$script:Proj/.agents/workflow/tasks.md" ($Content -replace "`r`n", "`n") }
function Add-Tasks { param([string]$Content) Set-Tasks ((Get-TasksText) + ($Content -replace "`r`n", "`n")) }
function Get-TasksText { return [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/tasks.md") }
function Get-StateText { return [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/state.json") }

# Set-State 'T1:done' 'T2:pending'
function Set-State {
    $tasks = foreach ($item in $args) {
        # "T1:status" または "T1:status:retries"
        $id, $status, $retries = $item -split ':', 3
        [ordered]@{ id = $id; title = "$id title"; status = $status; retries = [int]("0$retries"); commit = $null }
    }
    $state = [ordered]@{ source = 'test'; branch = 'main'; updated_at = '2026-01-01T00:00:00+09:00'; tasks = @($tasks) }
    Write-Utf8File "$script:Proj/.agents/workflow/state.json" ($state | ConvertTo-Json -Depth 10)
}

function Set-Report {
    param([string]$TaskId, [int]$Attempt)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$TaskId-$Attempt/report.md" "## 完了報告`n- 変更ファイル: a`n"
}

function Get-StateTask {
    param([string]$Id)
    return (ConvertFrom-Json (Get-StateText)).tasks | Where-Object { $_.id -eq $Id }
}

function Get-StateIds { return (@((ConvertFrom-Json (Get-StateText)).tasks | ForEach-Object { $_.id }) -join ',') }

# Invoke-Script <name.ps1> [args...] → $script:Out / $script:Err / $script:Code
function Invoke-Script {
    param([string]$Name, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    $errFile = [System.IO.Path]::GetTempFileName()
    Push-Location $script:Proj
    $outLines = & pwsh -NoProfile -File ".agents/workflow/scripts/$Name" @Rest 2> $errFile
    $script:Code = $LASTEXITCODE
    Pop-Location
    $script:Out = (@($outLines) -join "`n").Trim()
    $script:Err = [System.IO.File]::ReadAllText($errFile)
    Remove-Item $errFile -Force
}

function Add-Result {
    param([bool]$Ok, [string]$Message)
    if ($Ok) { $script:PassCount++ } else {
        $script:FailCount++
        $script:FailedNames += "$($script:CurrentTest): $Message"
        Write-Host "    FAIL: $Message"
    }
}

function Assert-Eq { param($Expected, $Actual, [string]$Message) Add-Result ("$Expected" -ceq "$Actual") "$Message (expected '$Expected', got '$Actual')" }
function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    $short = if ($Haystack.Length -gt 400) { $Haystack.Substring(0, 400) } else { $Haystack }
    Add-Result ($Haystack.Contains($Needle)) "$Message (missing '$Needle' in: $short)"
}
function Assert-NotContains { param([string]$Haystack, [string]$Needle, [string]$Message) Add-Result (-not $Haystack.Contains($Needle)) "$Message (unexpected '$Needle')" }
function Assert-FileExists { param([string]$Path, [string]$Message) Add-Result (Test-Path $Path) "$Message (file not found: $Path)" }
function Assert-FileAbsent { param([string]$Path, [string]$Message) Add-Result (-not (Test-Path $Path)) "$Message (file exists: $Path)" }

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    $script:CurrentTest = $Name
    Write-Host "  - $Name"
    New-TestProject
    try { & $Body } catch { Add-Result $false "exception: $($_.Exception.Message)" }
    Remove-TestProject
}

function Show-Summary {
    Write-Host ""
    Write-Host "PASS: $($script:PassCount)  FAIL: $($script:FailCount)"
    if ($script:FailCount -gt 0) {
        $script:FailedNames | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    exit 0
}
