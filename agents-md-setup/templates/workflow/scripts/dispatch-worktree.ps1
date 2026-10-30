# 子エージェントの run 用の git worktree を作る・集める・消す。
# Usage: dispatch-worktree.ps1 -Action <create|collect|remove> -TaskId <ID> -Attempt <N>
#   RUN=.agents/workflow/runs/<TaskId>-<Attempt>、WT=$RUN/worktree、ブランチ=agents-run/<TaskId>-<Attempt>
#   create : WT を HEAD から作る。試行回数が 2 以上なら、前の試行の変更を取り除いてから、
#            新しい WT に 3way で持ち越す(前の試行に $RUN/collected が無ければ取り除かず持ち越さない)。
#            取り除いたら $RUN/reverted に前のパッチのパスを書く。$RUN/worktree.txt(path / branch / base の3行)を書く
#   collect: WT の変更を $RUN/changes.patch にして本体へ git apply し、空の $RUN/collected を作って WT を消す。
#            tasks.md の changed に無いファイルは `Undeclared: <path>` で出す
#   remove : WT とブランチと $RUN/worktree.txt を消す(無くてもエラーにしない)
# exit: 0=成功 / 1=使い方不備 / 20=dirty-tree(前の試行の変更を本体から取り除けない・collect では本体の作業ツリーが clean でない) /
#   30=worktree(WT が既にある・作成に失敗・パッチを作る git の失敗・collect では worktree.txt または WT のディレクトリが無い) /
#   40=conflict(collect。git apply の失敗を含む / create の持ち越しの衝突)
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

# run ディレクトリの worktree.txt の base の値を返す(行が無ければ HEAD)
function Get-RunBase {
    param([string]$RunDir)
    if (Test-Path -LiteralPath "$RunDir/worktree.txt") {
        foreach ($l in ([System.IO.File]::ReadAllText((Resolve-Path "$RunDir/worktree.txt"), [System.Text.Encoding]::UTF8) -split "`r?`n")) {
            if ($l.StartsWith('base ') -and $l.Substring(5).Trim()) { return $l.Substring(5).Trim() }
        }
    }
    return 'HEAD'
}

# wt の変更(未追跡を含む。.agents/workflow は除く)の base との差分を out にバイナリ対応のパッチで書く。
# 成功したら $true、git が1つでも失敗したら $false
function New-Patch {
    param([string]$Wt, [string]$Out, [string]$Base)
    # git -C は wt に移ってから動くので、--output には本体側の絶対パスを渡す
    $absOut = Get-AbsPath $Out
    git -C $Wt -c core.longpaths=true add -A
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("git add failed in $Wt")
        return $false
    }
    git -C $Wt -c core.longpaths=true diff --cached --binary --no-renames "--output=$absOut" $Base -- . ':(exclude).agents/workflow'
    if ($LASTEXITCODE -ne 0) {
        git -C $Wt -c core.longpaths=true reset -q *> $null
        [Console]::Error.WriteLine("git diff failed in $Wt")
        return $false
    }
    git -C $Wt -c core.longpaths=true reset -q
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("git reset failed in $Wt")
        return $false
    }
    return $true
}

# wt・ブランチ・wt の隣の worktree.txt を消す(無いものは飛ばす)
function Remove-RunWorktree {
    param([string]$Wt, [string]$Branch)
    if (Test-Path -LiteralPath $Wt) {
        git -c core.longpaths=true worktree remove --force $Wt
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
    $wtPath = ''
    if (Test-Path -LiteralPath "$run/worktree.txt") {
        foreach ($l in ([System.IO.File]::ReadAllText((Resolve-Path "$run/worktree.txt"), [System.Text.Encoding]::UTF8) -split "`r?`n")) {
            if ($l.StartsWith('path ')) { $wtPath = $l.Substring(5); break }
        }
    }
    if (-not $wtPath -or -not (Test-Path -LiteralPath $wtPath)) {
        [Console]::Error.WriteLine("worktree not found: $run")
        Write-Output "Next: escalate reason=worktree"
        exit 30
    }
    $dirty = @(git status --porcelain -- . ':(exclude).agents/workflow')
    if ($dirty.Count -gt 0) {
        [Console]::Error.WriteLine("main working tree is not clean:")
        [Console]::Error.WriteLine(($dirty -join "`n"))
        Write-Output "Next: escalate reason=dirty-tree"
        exit 20
    }

    Remove-Item -LiteralPath "$run/collected" -Force -ErrorAction SilentlyContinue
    $patch = "$run/changes.patch"
    if (-not (New-Patch $wtPath $patch (Get-RunBase $run))) {
        [Console]::Error.WriteLine("failed to make the patch from the worktree: $wtPath")
        Write-Output "Next: escalate reason=worktree"
        exit 30
    }
    $hasPatch = (Test-Path -LiteralPath $patch) -and (Get-Item -LiteralPath $patch).Length -gt 0
    $changedFiles = @()
    if ($hasPatch) {
        $changedFiles = @(git -c core.quotepath=false apply --numstat (Get-AbsPath $patch) | ForEach-Object { ($_ -split "`t", 3)[2] } | Where-Object { $_ })
    }

    # tasks.md の対象タスクが宣言した変更対象(changed)
    $declared = @()
    if (Test-Path -LiteralPath '.agents/workflow/tasks.md') {
        . "$PSScriptRoot/tasklib.ps1"
        $taskLines = @(Split-TaskLines ([System.IO.File]::ReadAllText((Get-AbsPath '.agents/workflow/tasks.md'), [System.Text.Encoding]::UTF8)))
        $self = @(Read-TaskList $taskLines) | Where-Object { $_.id -ceq $TaskId } | Select-Object -First 1
        if ($self) { $declared = @($self.changed) }
    }
    $undeclared = $false
    foreach ($f in $changedFiles) {
        if ($declared -cnotcontains $f) {
            Write-Output "Undeclared: $f"
            $undeclared = $true
        }
    }
    if (-not $undeclared) { Write-Output "Undeclared: none" }

    if (-not $hasPatch) {
        Write-Output "Applied: 0 files"
    } else {
        $checkOut = git apply --check $patch 2>&1
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine(($checkOut | ForEach-Object { "$_" }) -join "`n")
            Write-Output "Next: escalate reason=conflict"
            exit 40
        }
        $applyOut = git apply $patch 2>&1
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine(($applyOut | ForEach-Object { "$_" }) -join "`n")
            Write-Output "Next: escalate reason=conflict"
            exit 40
        }
        Write-Output "Applied: $($changedFiles.Count) files"
    }

    [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "$run/collected"), '', (New-Object System.Text.UTF8Encoding($false)))
    Remove-RunWorktree $wt $branch
    Write-Output "Patch: $patch"
    Write-Output "Next: review $TaskId"
    exit 0
}

# --- create ---
if (Test-Path -LiteralPath $wt) {
    [Console]::Error.WriteLine("worktree already exists: $wt")
    Write-Output "Next: escalate reason=worktree"
    exit 30
}

$carry = ''
$reverted = $false
$notCollected = ''
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
    $prevHasWt = $false
    if ($prevWtPath -and (Test-Path -LiteralPath $prevWtPath)) {
        $prevHasWt = $true
        if (-not (New-Patch $prevWtPath $prevPatch (Get-RunBase $prev))) {
            [Console]::Error.WriteLine("failed to make the patch from the previous worktree: $prevWtPath")
            Write-Output "Next: escalate reason=worktree"
            exit 30
        }
    }
    if (Test-Path -LiteralPath "$prev/collected") {
        if ((Test-Path -LiteralPath $prevPatch) -and (Get-Item -LiteralPath $prevPatch).Length -gt 0) {
            git apply -R --check $prevPatch *> $null
            if ($LASTEXITCODE -eq 0) {
                git apply -R $prevPatch
                $reverted = $true
                New-Item -ItemType Directory -Force -Path $run | Out-Null
                [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "$run/reverted"), "$prevPatch`n", (New-Object System.Text.UTF8Encoding($false)))
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
    } elseif (Test-Path -LiteralPath $prevPatch) {
        $notCollected = $prevPatch
    }
    if ($prevHasWt) {
        Remove-RunWorktree "$prev/worktree" "agents-run/$TaskId-$prevN"
    }
}

New-Item -ItemType Directory -Force -Path $run | Out-Null
$addOut = git -c core.longpaths=true worktree add -q -b $branch $wt HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    # 作りかけの WT・ブランチ・worktree.txt を消し、取り除いた前の試行の変更は本体に戻す
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
    git rev-parse --verify -q "refs/heads/$branch" *> $null
    if ($LASTEXITCODE -eq 0) {
        git branch -D -q $branch
    }
    git worktree prune
    Remove-Item -LiteralPath "$run/worktree.txt" -Force -ErrorAction SilentlyContinue
    if ($reverted) {
        git apply $prevPatch
        Remove-Item -LiteralPath "$run/reverted" -Force -ErrorAction SilentlyContinue
    }
    [Console]::Error.WriteLine("git worktree add failed: $wt ($branch)")
    $lastLine = @($addOut | ForEach-Object { "$_".TrimEnd("`r") } | Where-Object { $_ }) | Select-Object -Last 1
    if ($lastLine) { [Console]::Error.WriteLine($lastLine) }
    Write-Output "Next: escalate reason=worktree"
    exit 30
}
New-Item -ItemType Directory -Force -Path "$wt/.agents/workflow/runs/$TaskId-$Attempt/tmp" | Out-Null

$base = (git rev-parse HEAD)
$lines = @("path $(Get-AbsPath $wt)", "branch refs/heads/$branch", "base $base")
[System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "$run/worktree.txt"), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

if ($carry) {
    git -C $wt -c core.longpaths=true apply --3way (Get-AbsPath $carry)
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Carried: $carry"
    } else {
        Remove-RunWorktree $wt $branch
        if ($reverted) {
            git apply $carry
            Remove-Item -LiteralPath "$run/reverted" -Force -ErrorAction SilentlyContinue
        }
        [Console]::Error.WriteLine("carrying the previous attempt's changes conflicted: $carry")
        Write-Output "Next: escalate reason=conflict"
        exit 40
    }
} elseif ($notCollected) {
    Write-Output "Carried: none (not collected: $notCollected)"
} else {
    Write-Output "Carried: none"
}

Write-Output "Worktree: $wt"
Write-Output "Branch: $branch"
Write-Output "Next: continue"
exit 0
