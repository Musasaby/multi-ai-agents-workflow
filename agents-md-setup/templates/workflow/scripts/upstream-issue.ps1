# ワークフロー由来の問題を upstream(multi-ai-agents-workflow の配布元)リポジトリに Issue として起票する。
# 起票先は .agents/workflow/config.json の upstream.url から決める(利用先リポジトリには起票しない)。
#
# Usage:
#   upstream-issue.ps1 -Search "<キーワード>" [-DryRun]                     重複候補を一覧表示(open/closed)
#   upstream-issue.ps1 -Create -Title "<件名>" -BodyFile <パス> [-DryRun]   起票(ユーザー承認後に実行)
# exit: 0=成功 / 1=使い方・config 不備 / その他=gh の exit code
param(
    [string]$Search,
    [switch]$Create,
    [string]$Title,
    [string]$BodyFile,
    [switch]$DryRun
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

# -BodyFile の相対パスは呼び出し時のカレントディレクトリ基準で解決する
if ($BodyFile -and -not [System.IO.Path]::IsPathRooted($BodyFile)) {
    $BodyFile = Join-Path (Get-Location).Path $BodyFile
}
Set-Location $PSScriptRoot\..\..\..
$configPath = ".agents/workflow/config.json"

if ($Create) {
    if (-not $Title) { Fail "-Create requires -Title" }
    if (-not $BodyFile -or -not (Test-Path $BodyFile -PathType Leaf)) {
        Fail "-Create requires an existing -BodyFile (got: '$BodyFile')"
    }
} elseif (-not $Search) {
    Fail 'Specify -Search "<query>" or -Create -Title "<title>" -BodyFile <path>'
}

if (-not (Test-Path $configPath)) { Fail "config.json not found: $configPath" }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$url = if ($config.upstream -and $config.upstream.url) { "$($config.upstream.url)".Trim() } else { '' }
if (-not $url) { Fail "upstream.url is not set in config.json" }
if ($url -notmatch '^(?:https?://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+?)(?:\.git)?/?$') {
    Fail "upstream.url is not a GitHub repository URL: $url"
}
$repo = "$($Matches[1])/$($Matches[2])"

if ($Create) {
    $ghArgs = @('issue', 'create', '-R', $repo, '--title', $Title, '--body-file', $BodyFile)
} else {
    $ghArgs = @('issue', 'list', '-R', $repo, '--state', 'all', '--search', $Search, '--limit', '20')
}

Write-Output "Repository: $repo"
if ($DryRun) {
    $shown = $ghArgs | ForEach-Object { if ($_ -match '\s' -or $_ -eq '') { "`"$_`"" } else { $_ } }
    Write-Output "Command (dry-run): gh $($shown -join ' ')"
    exit 0
}
& gh @ghArgs
exit $LASTEXITCODE
