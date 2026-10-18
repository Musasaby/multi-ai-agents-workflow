# 利用先プロジェクトに .agents/workflow/ 一式と関連設定(AGENTS.md・CLAUDE.md・.claude・.gitignore・.gitattributes)を揃える。
# すべて冪等で、既存のファイルは上書きしない。必ずテンプレート側のコピー
# (利用先では .agents/skills/_templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-setup.ps1           不足しているものを作る・足す(CREATED / APPENDED を出力)
#   workflow-setup.ps1 -Check    何も変えず、不足しているものを MISSING で出力
# 利用者の判断が要る事項は DECIDE <種別>: <内容> で出力する。
# 最後の行: DECIDE があれば "Next: confirm"、無ければ "Next: continue"
# exit: 0=変更済み(-Check では不足なし)かつ DECIDE なし / 1=使い方不備・git の外 / 3=DECIDE あり(-Check では MISSING あり)
param([switch]$Check)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$templateScripts = $PSScriptRoot
$templateRoot = Split-Path $templateScripts -Parent
$templates = Split-Path $templateRoot -Parent
Push-Location $templateScripts
$root = "$(git rev-parse --show-toplevel 2>$null)".Trim()
Pop-Location
if (-not $root) {
    [Console]::Error.WriteLine("Not inside a git repository: $templateScripts")
    exit 1
}
$destRoot = Join-Path $root '.agents/workflow'
if ((Test-Path $destRoot) -and ((Resolve-Path $templateRoot).Path.TrimEnd('\', '/') -eq (Resolve-Path $destRoot).Path.TrimEnd('\', '/'))) {
    [Console]::Error.WriteLine("Run this script from the template copy (.agents/skills/_templates/workflow/scripts/), not from .agents/workflow/scripts/")
    exit 1
}

Set-Location $root
$script:Decide = $false
$script:Missing = $false
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Add-Decide { param([string]$Text) Write-Output "DECIDE $Text"; $script:Decide = $true }

function Confirm-Dir { # ROOT からの相対パス
    param([string]$Path)
    if (Test-Path $Path -PathType Container) { return }
    if ($Check) { Write-Output "MISSING $Path"; $script:Missing = $true }
    else { $null = New-Item -ItemType Directory -Force $Path; Write-Output "CREATED $Path" }
}

function Confirm-Copy { # コピー元, ROOT からの相対パス(無ければコピー)
    param([string]$Src, [string]$Path)
    if (Test-Path $Path) { return }
    if ($Check) { Write-Output "MISSING $Path"; $script:Missing = $true; return }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Force $dir }
    Copy-Item $Src $Path
    Write-Output "CREATED $Path"
}

function Confirm-Line { # ファイル, 行(完全一致で判定し、無ければ末尾に足す。BOM なし UTF-8・LF)
    param([string]$Path, [string]$Line)
    $full = Join-Path $root $Path
    $text = $null
    if (Test-Path $full -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($full, $utf8)
        if (($text -split "\r?\n") -ccontains $Line) { return }
    }
    if ($Check) { Write-Output "MISSING ${Path}: $Line"; $script:Missing = $true; return }
    if ($null -eq $text) {
        [System.IO.File]::WriteAllText($full, '', $utf8)
        Write-Output "CREATED $Path"
        $text = ''
    }
    $prefix = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { "`n" } else { '' }
    [System.IO.File]::AppendAllText($full, "$prefix$Line`n", $utf8)
    Write-Output "APPENDED ${Path}: $Line"
}

Confirm-Dir '.agents/workflow/runs'
Confirm-Copy (Join-Path $templateRoot 'config.json') '.agents/workflow/config.json'
# child_agent.isolate_xdg が true のときだけ XDG 隔離用ディレクトリを作る(読めない場合は false)
$isolateXdg = $false
try {
    $cfg = [System.IO.File]::ReadAllText((Join-Path $root '.agents/workflow/config.json'), $utf8) | ConvertFrom-Json
    if ($cfg.child_agent.isolate_xdg -eq $true) { $isolateXdg = $true }
} catch { $isolateXdg = $false }
if ($isolateXdg) { Confirm-Dir '.agents/workflow/.config' }
Confirm-Copy (Join-Path $templateRoot 'README.md') '.agents/workflow/README.md'

# スクリプト
$sync = Join-Path $templateScripts 'workflow-sync-scripts.ps1'
if ($Check) {
    $syncOut = @(& pwsh -NoProfile -File $sync 2>&1 | ForEach-Object { "$_" })
    if ($syncOut.Count -gt 0) { $syncOut | ForEach-Object { Write-Output $_ } }
    if ($syncOut | Where-Object { $_ -match '^missing' }) { $script:Missing = $true }
} else {
    & pwsh -NoProfile -File $sync -CopyMissing
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("workflow-sync-scripts.ps1 -CopyMissing failed")
        exit 1
    }
}

Confirm-Copy (Join-Path $templates 'AGENTS.md') 'AGENTS.md'

# CLAUDE.md
if (-not (Test-Path CLAUDE.md)) {
    if ($Check) { Write-Output "MISSING CLAUDE.md"; $script:Missing = $true }
    else { [System.IO.File]::WriteAllText((Join-Path $root 'CLAUDE.md'), "@AGENTS.md`n", $utf8); Write-Output "CREATED CLAUDE.md" }
} else {
    $claudeBody = [System.IO.File]::ReadAllText((Join-Path $root 'CLAUDE.md'), $utf8).Replace("`r", '').TrimEnd()
    if ($claudeBody -cne '@AGENTS.md') {
        Add-Decide "claude-md: CLAUDE.md has its own content (move it into AGENTS.md, then make CLAUDE.md the single line @AGENTS.md)"
    }
}

# .claude
$claude = Get-Item .claude -Force -ErrorAction SilentlyContinue
$isLink = $claude -and ($claude.LinkType -in @('SymbolicLink', 'Junction'))
if ($isLink) {
    if (-not (Test-Path .claude)) {
        Add-Decide "claude-link: .claude is a broken link (remove it, then recreate with: New-Item -ItemType Junction -Path .claude -Target .agents)"
    } else {
        $target = @($claude.Target)[0]
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $root $target }
        $want = Join-Path $root '.agents'
        $norm = { param($p) [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
        if (-not (Test-Path $want) -or ((& $norm $target) -ine (& $norm $want))) {
            Add-Decide "claude-link: .claude points to '$target', not .agents (check it, then relink)"
        }
    }
} elseif ($claude) {
    Add-Decide "claude-dir: .claude is a real directory (merge it into .agents, then replace it with a link)"
} else {
    if ($Check) { Write-Output "MISSING .claude"; $script:Missing = $true }
    else {
        $null = New-Item -ItemType Directory -Force .agents
        $linked = $false
        try {
            $null = New-Item -ItemType SymbolicLink -Path .claude -Target .agents -ErrorAction Stop
            $linked = $true
        } catch {
            try {
                $null = New-Item -ItemType Junction -Path .claude -Target (Resolve-Path .agents).Path -ErrorAction Stop
                $linked = $true
            } catch {
                [Console]::Error.WriteLine("Failed to create .claude link: $($_.Exception.Message)")
            }
        }
        if ($linked -and ((Get-Item .claude -Force).LinkType -in @('SymbolicLink', 'Junction'))) {
            Write-Output "CREATED .claude"
        } else {
            Add-Decide "claude-link: could not create .claude (create it with: New-Item -ItemType Junction -Path .claude -Target .agents)"
        }
    }
}

foreach ($line in @('.claude', '.agents/settings.local.json', '.agents/workflow/.config/', '.agents/workflow/runs/',
        '.agents/workflow/archive/', '.agents/scheduled_tasks.lock')) {
    Confirm-Line '.gitignore' $line
}

Confirm-Line '.gitattributes' '.agents/workflow/scripts/*.sh text eol=lf'
Confirm-Line '.gitattributes' '.agents/workflow/scripts/*.py text eol=lf'

# 旧レイアウト
foreach ($old in @('.agents/workflow/.dispatch-run.ps1', '.agents/workflow/.dispatch-run.sh',
        '.agents/workflow/logs', '.agents/workflow/reports', '.agents/workflow/.dispatch-prompt-*.md')) {
    if (Test-Path $old) { Add-Decide "old-layout: $old" }
}

if ($script:Decide) { Write-Output "Next: confirm" } else { Write-Output "Next: continue" }
if ($script:Decide -or $script:Missing) { exit 3 }
exit 0
