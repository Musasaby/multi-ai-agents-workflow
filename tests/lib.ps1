# テスト共通ヘルパー(PowerShell版スクリプト用)。
# ダミーの利用先プロジェクト(.agents/workflow/ 一式 + git リポジトリ。agents-md-setup/templates/workflow/scripts/
# のスクリプトを含む)の雛形を 1 度だけ作り、ケースごとに一時ディレクトリへコピーして実行する。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# テストの git を利用者のグローバル設定・システム設定から切り離す(Issue F-1)。
# lib は Linux でも動くため、NULL デバイスのパスは $IsWindows で切り替える
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_GLOBAL = if ($IsWindows) { 'NUL' } else { '/dev/null' }

# ダミープロジェクトに .git が無い場合でも、git が親ディレクトリの本物のリポジトリにたどり着かないようにする
$env:GIT_CEILING_DIRECTORIES = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')

# gh スタブ(gh.cmd を PATH 先頭に置き、Set-GhStubResult で挙動を切り替える)。
# 既定(Set-GhStubResult で設定していない状態)では、意図しない gh 呼び出しを
# stderr に記録して exit 97 で失敗させる(利用先テストでの実 gh 呼び出し防止)
$script:GhStubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gh-stub-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force $script:GhStubDir
$stubCmd = @'
@echo off
if not "%GH_STUB_LOG%"=="" echo %*>>"%GH_STUB_LOG%"
if not "%GH_STUB_SET%"=="1" goto unexpected
if "%GH_STUB_CODE%"=="" set GH_STUB_CODE=0
if not "%GH_STUB_STDOUT%"=="" echo %GH_STUB_STDOUT%
if not "%GH_STUB_STDERR%"=="" echo %GH_STUB_STDERR% 1>&2
exit /b %GH_STUB_CODE%
:unexpected
echo gh stub: unexpected call: %* 1>&2
exit /b 97
'@
[System.IO.File]::WriteAllText((Join-Path $script:GhStubDir 'gh.cmd'), $stubCmd)
$env:PATH = "$($script:GhStubDir);$env:PATH"

# gh スタブの挙動を設定する(-Code <code> -Stdout <stdout> -Stderr <stderr>)。
# (Stdout / Stderr を指定しなければ出力なし。設定時に呼び出し記録も空にする)
function Set-GhStubResult {
    param([int]$Code = 0, [string]$Stdout = '', [string]$Stderr = '')
    $env:GH_STUB_LOG = "$($script:GhStubDir)/log.txt"
    $env:GH_STUB_SET = '1'
    $env:GH_STUB_CODE = "$Code"
    $env:GH_STUB_STDOUT = $Stdout
    $env:GH_STUB_STDERR = $Stderr
    Remove-Item $env:GH_STUB_LOG -Force -ErrorAction SilentlyContinue
}

# gh の呼び出し記録を返す(gh が呼ばれていなければ空文字列)
function Get-GhStubLog {
    if ($env:GH_STUB_LOG -and (Test-Path $env:GH_STUB_LOG)) {
        return [System.IO.File]::ReadAllText($env:GH_STUB_LOG)
    }
    return ''
}

# スタブの挙動を既定(未設定 = 意図しない呼び出しは exit 97)に戻す
function Reset-GhStub {
    $env:GH_STUB_LOG = $null
    $env:GH_STUB_SET = $null
    $env:GH_STUB_CODE = $null
    $env:GH_STUB_STDOUT = $null
    $env:GH_STUB_STDERR = $null
    Remove-Item "$($script:GhStubDir)/log.txt" -Force -ErrorAction SilentlyContinue
}

$script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
$script:TemplateScripts = Join-Path $script:RepoRoot 'agents-md-setup/templates/workflow/scripts'
$script:PassCount = 0
$script:FailCount = 0
$script:FailedNames = @()
$script:CurrentTest = ''
$script:Proj = $null
$script:ProjTemplate = $null
$script:CreatedProjects = [System.Collections.Generic.List[string]]::new()

# $Dir が自分自身の git リポジトリであることを確かめる(親の本物のリポジトリに git を実行しないため)
function Assert-OwnRepo {
    param([string]$Dir)
    $expected = ((Resolve-Path -LiteralPath $Dir).Path -replace '\\', '/').TrimEnd('/')
    $actual = (git -C $Dir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or "$actual" -ne $expected) {
        [Console]::Error.WriteLine("FATAL: test project is not its own git repository: $Dir (toplevel: $actual)")
        exit 1
    }
}

# ダミープロジェクトの雛形(スクリプト一式・config.json・初回コミット済みの git リポジトリ)を 1 度だけ作る
function New-ProjTemplate {
    $script:ProjTemplate = Join-Path ([System.IO.Path]::GetTempPath()) ("wf-tpl-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $tpl = $script:ProjTemplate
    $null = New-Item -ItemType Directory -Force "$tpl/.agents/workflow/scripts", "$tpl/.agents/workflow/runs"
    Copy-Item "$script:TemplateScripts/*" "$tpl/.agents/workflow/scripts/"
    Copy-Item "$script:RepoRoot/agents-md-setup/templates/workflow/config.json" "$tpl/.agents/workflow/config.json"
    git -C $tpl init -q -b main 2>$null
    Assert-OwnRepo $tpl
    Push-Location $tpl -ErrorAction Stop
    try {
        git config user.email "test@example.com"
        git config user.name "test"
        git config core.autocrlf false
        Set-Content -Path .gitignore -Value '.agents/' -NoNewline
        git add .gitignore
        git commit -q -m "init"
    } finally {
        Pop-Location
    }
}

function New-TestProject {
    if (-not $script:ProjTemplate) { New-ProjTemplate }
    $script:Proj = Join-Path ([System.IO.Path]::GetTempPath()) ("wf-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:CreatedProjects.Add($script:Proj)
    # $script:Proj はまだ存在しないので、雛形のディレクトリごと $script:Proj という名前でコピーされる。
    # .git は Hidden 属性なので、"<雛形>/*" のようなワイルドカードではコピーしない
    Copy-Item -LiteralPath $script:ProjTemplate -Destination $script:Proj -Recurse
    Assert-OwnRepo $script:Proj
}

function Remove-TestProject {
    if ($script:Proj) {
        # dispatch-start がデタッチ起動した dispatch-run は done を書いた後も少しの間動いており、
        # Windows ではその間ディレクトリを消せない。コマンドラインにプロジェクト名を含むプロセスの終了を待つ(最大30秒)。
        # Get-Process の CommandLine はプロセスごとに問い合わせて遅いため、WMI の1回のクエリで探す
        if ($IsWindows) {
            $name = Split-Path $script:Proj -Leaf
            for ($i = 0; $i -lt 60; $i++) {
                $alive = @(Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$name%'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessId -ne $PID })
                if ($alive.Count -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }
        }
        Remove-Item -Recurse -Force $script:Proj -ErrorAction SilentlyContinue
    }
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

# state.json のトップレベル group を設定する(空文字列は「既定グループ」として設定)。
# (キー自体を削除したい場合は Remove-StateGroup を使うこと)
function Set-StateGroup {
    param([string]$Group)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($state.PSObject.Properties['group']) { $state.PSObject.Properties.Remove('group') }
    $state | Add-Member -NotePropertyName group -NotePropertyValue $Group
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

# state.json のトップレベル group キーを削除する(groupフィールド無しの旧state.json相当)
function Remove-StateGroup {
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($state.PSObject.Properties['group']) { $state.PSObject.Properties.Remove('group') }
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

# state.json のトップレベル group を返す(キーが無ければ <absent>)
function Get-StateGroup {
    $state = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/state.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($state.PSObject.Properties['group']) { return $state.group }
    return '<absent>'
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
    try {
        $outLines = & pwsh -NoProfile -File ".agents/workflow/scripts/$Name" @Rest 2> $errFile
        $script:Code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
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
    Reset-GhStub
    New-TestProject
    try { & $Body } catch { Add-Result $false "exception: $($_.Exception.Message)" }
    Remove-TestProject
}

function Show-Summary {
    # gh スタブのディレクトリも PATH から外して削除する(消えなければ残留として検出する)
    $env:PATH = ($env:PATH -replace [regex]::Escape("$($script:GhStubDir);"), '')
    Remove-Item $script:GhStubDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $script:GhStubDir) {
        $script:FailCount++
        $script:FailedNames += "gh スタブの残留: $($script:GhStubDir)"
        Write-Host "    leftover temp dir: $($script:GhStubDir)"
    }
    # ダミープロジェクトの雛形も削除する(消えなければ残留として検出する)
    if ($script:ProjTemplate) {
        Remove-Item $script:ProjTemplate -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $script:ProjTemplate) {
            $script:FailCount++
            $script:FailedNames += "雛形の残留: $($script:ProjTemplate)"
            Write-Host "    leftover temp dir: $($script:ProjTemplate)"
        }
    }
    # 一時ディレクトリの残留検出(New-TestProject が作ったディレクトリがすべて消えていること)
    $leftovers = @($script:CreatedProjects | Where-Object { Test-Path $_ })
    if ($leftovers.Count -gt 0) {
        $script:FailCount++
        $script:FailedNames += "一時ディレクトリの残留: $($leftovers -join ' ')"
        $leftovers | ForEach-Object { Write-Host "    leftover temp dir: $_" }
    }
    Write-Host ""
    Write-Host "PASS: $($script:PassCount)  FAIL: $($script:FailCount)"
    if ($script:FailCount -gt 0) {
        $script:FailedNames | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    exit 0
}
