# 子エージェントの run 用の git worktree を作る・集める・消す。
# Usage: dispatch-worktree.ps1 -Action <create|collect|remove> -TaskId <ID> -Attempt <N>
#   RUN=.agents/workflow/runs/<TaskId>-<Attempt>、WT=$RUN/worktree、ブランチ=agents-run/<TaskId>-<Attempt>
#   create : WT を HEAD から作る。試行回数が 2 以上なら、前の試行の変更を取り除いてから、
#            新しい WT に 3way で持ち越す。$RUN/worktree.txt(path / branch / base の3行)を書く
#   collect: (未実装)
#   remove : WT とブランチと $RUN/worktree.txt を消す(無くてもエラーにしない)
# exit: 0=成功 / 1=使い方不備 / 20=dirty-tree(前の試行の変更を本体から取り除けない) /
#   30=worktree(WT が既にある・作成に失敗) / 40=conflict(collect)
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(continue / escalate reason=<理由>。
# 使い方不備の exit 1 では出さない)
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][int]$Attempt
)
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt: '$TaskId' '$Attempt'")
    exit 1
}
if ($Action -cnotin @('create', 'collect', 'remove')) {
    [Console]::Error.WriteLine("Invalid action: '$Action' (create|collect|remove)")
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$run = ".agents/workflow/runs/$TaskId-$Attempt"
$wt = "$run/worktree"
$branch = "agents-run/$TaskId-$Attempt"

function Get-AbsPath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))) -replace '\\', '/'
}

# wt の変更(未追跡を含む。.agents/workflow は除く)を out にバイナリ対応のパッチで書く
function New-Patch {
    param([string]$Wt, [string]$Out)
    # git -C は wt に移ってから動くので、--output には本体側の絶対パスを渡す
    $absOut = Get-AbsPath $Out
    git -C $Wt add -A
    git -C $Wt diff --cached --binary "--output=$absOut" HEAD -- . ':(exclude).agents/workflow'
    git -C $Wt reset -q
}

# wt・ブランチ・wt の隣の worktree.txt を消す(無いものは飛ばす)
function Remove-RunWorktree {
    param([string]$Wt, [string]$Branch)
    if (Test-Path -LiteralPath $Wt) {
        git worktree remove --force $Wt
    }
    git rev-parse --verify -q "refs/heads/$Branch" *> $null
    if ($LASTEXITCODE -eq 0) {
        git branch -D -q $Branch
    }
    Remove-Item -LiteralPath (Join-Path (Split-Path $Wt -Parent) 'worktree.txt') -Force -ErrorAction SilentlyContinue
}

if ($Action -ceq 'remove') {
    Remove-RunWorktree $wt $branch
    Write-Output "Next: continue"
    exit 0
}
if ($Action -ceq 'collect') {
    [Console]::Error.WriteLine("collect: not implemented")
    exit 1
}

# --- create ---
if (Test-Path -LiteralPath $wt) {
    [Console]::Error.WriteLine("worktree already exists: $wt")
    Write-Output "Next: escalate reason=worktree"
    exit 30
}

$carry = ''
if ($Attempt -ge 2) {
    $prevN = $Attempt - 1
    $prev = ".agents/workflow/runs/$TaskId-$prevN"
    $prevPatch = "$prev/changes.patch"
    $prevWtPath = ''
    if (Test-Path -LiteralPath "$prev/worktree.txt") {
        foreach ($l in ([System.IO.File]::ReadAllText((Resolve-Path "$prev/worktree.txt"), [System.Text.Encoding]::UTF8) -split "`r?`n")) {
            if ($l.StartsWith('path ')) { $prevWtPath = $l.Substring(5); break }
        }
    }
    if ($prevWtPath -and (Test-Path -LiteralPath $prevWtPath)) {
        New-Patch $prevWtPath $prevPatch
        Remove-RunWorktree "$prev/worktree" "agents-run/$TaskId-$prevN"
    }
    if ((Test-Path -LiteralPath $prevPatch) -and (Get-Item -LiteralPath $prevPatch).Length -gt 0) {
        git apply -R --check $prevPatch *> $null
        if ($LASTEXITCODE -eq 0) {
            git apply -R $prevPatch
        } else {
            git apply --check $prevPatch *> $null
            if ($LASTEXITCODE -ne 0) {
                [Console]::Error.WriteLine("previous attempt's changes can be neither reverted nor applied cleanly: $prevPatch")
                Write-Output "Next: escalate reason=dirty-tree"
                exit 20
            }
        }
        $carry = $prevPatch
    }
}

New-Item -ItemType Directory -Force -Path $run | Out-Null
git worktree add -q -b $branch $wt HEAD
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("git worktree add failed: $wt ($branch)")
    Write-Output "Next: escalate reason=worktree"
    exit 30
}
New-Item -ItemType Directory -Force -Path "$wt/.agents/workflow/runs/$TaskId-$Attempt/tmp" | Out-Null

$base = (git rev-parse HEAD)
$lines = @("path $(Get-AbsPath $wt)", "branch refs/heads/$branch", "base $base")
[System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "$run/worktree.txt"), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

if ($carry) {
    git -C $wt apply --3way (Get-AbsPath $carry)
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Carried: $carry"
    } else {
        Write-Output "Carried: conflict $carry"
    }
} else {
    Write-Output "Carried: none"
}

Write-Output "Worktree: $wt"
Write-Output "Branch: $branch"
Write-Output "Next: continue"
exit 0
