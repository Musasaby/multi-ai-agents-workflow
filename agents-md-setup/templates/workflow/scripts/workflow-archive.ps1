param(
    [Parameter(Position = 0)]
    [string]$Slug,
    [switch]$Force
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# workflow 状態(tasks.md / state.json / runs/ / comprehension/)を archive/ へ移動する。
# Usage: workflow-archive.ps1 <スラッグ> [-Force]
# 判定順と exit code は workflow-archive.sh と同じ:
#   1=使い方不備 / 2=PR OPEN / 3=PR CLOSED / 4=gh で判定不能 /
#   5=PR 未作成でブランチに未マージのコミットがある(比較先が無い場合も含む)。
# 止めるとき(2 / 3 / 4 / 5)は何も移動せず、stdout の最後の行に "Next:" 行を出す。

function Fail {
    param([string]$Message, [int]$Code = 1, [string]$Next = '')
    if ($Next) { Write-Output $Next }
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

if (-not $Slug) {
    Fail "使い方: workflow-archive.ps1 <スラッグ> [-Force]"
}

if ($Slug -match '[\\/]' -or $Slug -match '\.\.') {
    Fail "スラッグにパス区切りや '..' を含めることはできません: $Slug"
}

$Root = Get-Location
$WorkflowDir = "$Root/.agents/workflow"
$StatePath = "$WorkflowDir/state.json"
$ConfigPath = "$WorkflowDir/config.json"

if (-not (Test-Path $WorkflowDir)) {
    Fail "workflow ディレクトリが見つかりません: $WorkflowDir"
}

$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$ArchiveDir = "$WorkflowDir/archive/$Timestamp-$Slug"

$Targets = @('tasks.md', 'state.json', 'runs', 'comprehension')
$Existing = @()
foreach ($name in $Targets) {
    $path = "$WorkflowDir/$name"
    if (Test-Path $path) {
        $Existing += $name
    }
}

if ($Existing.Count -eq 0) {
    Fail "移動対象がありません(tasks.md / state.json / runs/ / comprehension/ のいずれも存在しません)"
}

# PR の状態を確かめる。止めるときは exit し、アーカイブしてよいときはそのまま戻る
function Test-PrState {
    $stateBranch = Get-JsonField $StatePath 'branch'
    $baseBranch = Get-JsonField $ConfigPath 'base_branch'
    if (-not $stateBranch -or $stateBranch -eq 'main' -or ($baseBranch -and $stateBranch -eq $baseBranch)) {
        return
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Fail "gh not found: cannot check the PR state of '$stateBranch' (use -Force to archive anyway)" 4 'Next: escalate reason=gh-unavailable'
    }

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        try {
            $ghOut = & gh pr view $stateBranch --json state,url 2> $errFile
            $ghCode = $LASTEXITCODE
        } catch {
            Fail "gh could not be executed: $($_.Exception.Message)" 4 'Next: escalate reason=gh-unavailable'
        }
        if ($ghCode -ne 0) {
            $ghErr = [System.IO.File]::ReadAllText($errFile)
            if ($ghErr -match '(?i)no pull request') {
                # PR 未作成: ブランチに比較先へ入っていないコミットがあれば、まだサイクルが終わっていないとみなす
                & git rev-parse --verify --quiet "refs/heads/$stateBranch" *> $null
                if ($LASTEXITCODE -ne 0) { return }   # ローカルにブランチが無い(失う作業が無い)
                $base = if ($baseBranch) { $baseBranch } else { 'main' }
                $baseRef = ''
                & git rev-parse --verify --quiet "refs/heads/$base" *> $null
                if ($LASTEXITCODE -eq 0) {
                    $baseRef = "refs/heads/$base"
                } else {
                    & git rev-parse --verify --quiet "refs/remotes/origin/$base" *> $null
                    if ($LASTEXITCODE -eq 0) { $baseRef = "refs/remotes/origin/$base" }
                }
                if ($baseRef) {
                    $count = [int]((& git rev-list --count "$baseRef..refs/heads/$stateBranch") -join '').Trim()
                    if ($count -eq 0) { return }
                    Write-Output 'NO_PR'
                    Fail "$count commit(s) on '$stateBranch' are not in '$base' and no PR exists (create the PR and add tasks to the current cycle, or use -Force to archive anyway)" 5 'Next: escalate reason=pr-not-created'
                }
                Write-Output 'NO_PR'
                Fail "'$base' not found: cannot check whether '$stateBranch' is merged (use -Force to archive anyway)" 5 'Next: escalate reason=pr-not-created'
            }
            Fail "gh pr view failed (exit $ghCode): $ghErr" 4 'Next: escalate reason=gh-unavailable'
        }
        $ghJson = (@($ghOut) -join "`n").Trim()
        try {
            $pr = $ghJson | ConvertFrom-Json
        } catch {
            Fail "Failed to parse gh pr view output (expected JSON with 'state'): $ghJson" 4 'Next: escalate reason=gh-unavailable'
        }
        $prState = "$($pr.state)"
        $prUrl = "$($pr.url)"

        if ($prState -ceq 'MERGED') { return }
        if ($prState -ceq 'OPEN') {
            Write-Output "OPEN $prUrl"
            Fail "PR for '$stateBranch' is not merged yet (add tasks to the current cycle instead, or use -Force to archive anyway)" 2 'Next: escalate reason=pr-open'
        }
        if ($prState -ceq 'CLOSED') {
            Write-Output "CLOSED $prUrl"
            Fail "PR for '$stateBranch' is CLOSED without merging (use -Force to archive anyway)" 3 'Next: escalate reason=pr-closed'
        }
        Fail "Unexpected PR state: '$prState'"
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $Force) { Test-PrState }

# runs/*/worktree.txt がある run の worktree とブランチを消す(失敗しても続ける)
function Remove-RunWorktrees {
    foreach ($txt in @(Get-ChildItem "$WorkflowDir/runs/*/worktree.txt" -ErrorAction SilentlyContinue)) {
        $lines = @(Get-Content $txt.FullName -Encoding UTF8)
        $wt = ''
        $branch = ''
        foreach ($line in $lines) {
            if (-not $wt -and $line -match '^path (.+)$') { $wt = $Matches[1].Trim() }
            if (-not $branch -and $line -match '^branch (.+)$') { $branch = $Matches[1].Trim() }
        }
        $branch = $branch -replace '^refs/heads/', ''
        if (-not $branch) { $branch = "agents-run/$($txt.Directory.Name)" }
        if ($wt -and (Test-Path $wt)) {
            & git worktree remove --force $wt 2>&1 | ForEach-Object { [Console]::Error.WriteLine("$_") }
            if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("worktree の削除に失敗しました: $wt") }
        }
        & git rev-parse --verify -q "refs/heads/$branch" *> $null
        if ($LASTEXITCODE -eq 0) {
            & git branch -D -q $branch 2>&1 | ForEach-Object { [Console]::Error.WriteLine("$_") }
            if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("ブランチの削除に失敗しました: $branch") }
        }
    }
}

Remove-RunWorktrees

New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null

foreach ($name in $Existing) {
    Move-Item -Path "$WorkflowDir/$name" -Destination "$ArchiveDir/$name"
}

& git worktree prune 2>&1 | ForEach-Object { [Console]::Error.WriteLine("$_") }

Write-Output "Archived: $ArchiveDir ($($Existing -join ', '))"
exit 0
