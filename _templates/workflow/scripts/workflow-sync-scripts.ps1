# 配布テンプレート(このスクリプトがあるディレクトリ)と利用先の配置先
# (.agents/workflow/scripts/ と .agents/workflow/README.md)を比較し、差分を反映する。
# 必ずテンプレート側のコピー(利用先では .agents/skills/_templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-sync-scripts.ps1                          差分の一覧(missing / differs)を表示
#   workflow-sync-scripts.ps1 -CopyMissing             未配置のファイルだけをコピー(既存は上書きしない)
#   workflow-sync-scripts.ps1 -Overwrite <名前,...>    指定したファイルをテンプレートで上書き(ユーザー承認後)
#   workflow-sync-scripts.ps1 -Diff <名前>             配置先 → テンプレートの差分を表示
# 名前は一覧に表示される形式(例: scripts/dispatch-run.sh, README.md)
# exit: 0=成功(一覧モードでは差分なし) / 1=使い方不備 / 3=一覧モードで差分あり
# 改行コード(CRLF/LF)だけの違いは差分とみなさない。
param(
    [switch]$CopyMissing,
    [string[]]$Overwrite,
    [string]$Diff
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$templateScripts = $PSScriptRoot
$templateRoot = Split-Path $templateScripts -Parent
Push-Location $templateScripts
$root = "$(git rev-parse --show-toplevel 2>$null)".Trim()
Pop-Location
if (-not $root) {
    [Console]::Error.WriteLine("Not inside a git repository: $templateScripts")
    exit 1
}
$destRoot = Join-Path $root '.agents/workflow'

function Get-SyncNames {
    $names = @(Get-ChildItem -Path $templateScripts -File | Sort-Object Name | ForEach-Object { "scripts/$($_.Name)" })
    if (Test-Path (Join-Path $templateRoot 'README.md')) { $names += 'README.md' }
    return $names
}

# CRLF・BOM を無視した内容
function Get-NormalizedText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n")
}

function Get-SyncStatus {
    param([string]$Name)
    $dst = Join-Path $destRoot $Name
    if (-not (Test-Path $dst -PathType Leaf)) { return 'missing' }
    if ((Get-NormalizedText (Join-Path $templateRoot $Name)) -ceq (Get-NormalizedText $dst)) { return 'same' }
    return 'differs'
}

function Copy-SyncFile {
    param([string]$Name)
    $dst = Join-Path $destRoot $Name
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Force $dir }
    Copy-Item -Force (Join-Path $templateRoot $Name) $dst
    if ($Name.EndsWith('.sh') -and (Get-Command chmod -ErrorAction SilentlyContinue)) { chmod +x $dst }
}

$all = @(Get-SyncNames)

if ($Overwrite -or $Diff) {
    $requested = if ($Diff) { @($Diff) } else { @($Overwrite | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ }) }
    foreach ($n in $requested) {
        if ($all -cnotcontains $n) {
            [Console]::Error.WriteLine("Unknown file name: '$n' (use a name shown by the list mode)")
            exit 1
        }
    }
    foreach ($n in $requested) {
        if ($Diff) {
            $dst = Join-Path $destRoot $n
            if (Test-Path $dst) {
                git --no-pager diff --no-index --ignore-cr-at-eol -- $dst (Join-Path $templateRoot $n)
            } else {
                Write-Output "missing  $n (not deployed yet)"
            }
        } else {
            Copy-SyncFile $n
            Write-Output "overwritten $n"
        }
    }
    exit 0
}

if ($CopyMissing) {
    foreach ($n in $all) {
        if ((Get-SyncStatus $n) -eq 'missing') {
            Copy-SyncFile $n
            Write-Output "copied   $n"
        }
    }
    exit 0
}

$found = $false
foreach ($n in $all) {
    $st = Get-SyncStatus $n
    if ($st -ne 'same') {
        Write-Output ("{0,-8} {1}" -f $st, $n)
        $found = $true
    }
}
if ($found) { exit 3 }
Write-Output "All files are in sync with the template"
exit 0
