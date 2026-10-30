# dispatch-worktree の create・remove・collect(PowerShell版)
. "$PSScriptRoot/lib.ps1"

# $script:Out の最後の行を返す
function Get-LastLine {
    return (@($script:Out -split "`n") | Select-Object -Last 1)
}

# 本体にブランチ <name> があれば $true
function Test-Branch {
    param([string]$Name)
    git -C $script:Proj rev-parse --verify -q "refs/heads/$Name" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Write-Plain {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# 本体に base.txt(2行)を足して履歴に残し、T1 の変更対象を base.txt だけにして create する。worktree のパスを返す
function Initialize-Collect {
    Write-Plain "$script:Proj/base.txt" "line1`nline2`n"
    git -C $script:Proj add base.txt *> $null
    git -C $script:Proj commit -q -m "add base" *> $null
    Set-Tasks @'
## T1: 一番目
- **目的**: a
- **依存**: なし
- **対象**: `base.txt`(変更対象)
'@
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create exit: $($script:Err)"
    return "$script:Proj/.agents/workflow/runs/T1-1/worktree"
}

# 子の本文 $Body を worktree の child.ps1 にして config の command_template に設定し、T1-1 の worktree を作る
function Initialize-WtChild {
    param([string]$Body)
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create exit: $($script:Err)"
    Write-Plain "$script:Proj/.agents/workflow/runs/T1-1/worktree/child.ps1" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'pwsh -NoProfile -File ./child.ps1 "{prompt}"'
    Write-Plain $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Plain "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt`n"
}

$WtReport = 'Write-Output "## 完了報告"; Write-Output "- 変更ファイル: a.txt"; Write-Output "- テスト結果: 全件パス"'

# git のラッパー(git.cmd)を PATH 先頭に置く。GIT_WRAP_FAIL=1 の間、`-c ... worktree add -q -b <branch> <wt> HEAD` は
# ブランチと WT のディレクトリを作ってから exit 128 で終わる。それ以外は本物の git に渡す。引数は GIT_WRAP_LOG に記録する
# (バッチの引数は = でも区切られるため、core.longpaths=true は %2 と %3 に分かれる)
function Enable-GitWrap {
    $script:WrapDir = Join-Path ([System.IO.Path]::GetTempPath()) ("git-wrap-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force $script:WrapDir
    $script:WrapLog = Join-Path $script:WrapDir 'git.log'
    $script:PathBeforeWrap = $env:PATH
    $env:GIT_WRAP_REAL = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $env:GIT_WRAP_LOG = $script:WrapLog
    $cmd = @'
@echo off
echo %*>>"%GIT_WRAP_LOG%"
if "%GIT_WRAP_FAIL%"=="1" if "%4"=="worktree" if "%5"=="add" goto fail
"%GIT_WRAP_REAL%" %*
exit /b %ERRORLEVEL%
:fail
"%GIT_WRAP_REAL%" branch %8 HEAD
mkdir %9
echo fatal: simulated worktree add failure 1>&2
exit /b 128
'@
    [System.IO.File]::WriteAllText((Join-Path $script:WrapDir 'git.cmd'), $cmd)
    $env:PATH = "$($script:WrapDir);$env:PATH"
}

function Disable-GitWrap {
    $env:PATH = $script:PathBeforeWrap
    Remove-Item Env:GIT_WRAP_FAIL, Env:GIT_WRAP_LOG, Env:GIT_WRAP_REAL -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $script:WrapDir -ErrorAction SilentlyContinue
}

Write-Host "test-dispatch-worktree.ps1"

Invoke-TestCase "dispatch-worktree: worktree add が失敗するとブランチ・WT・worktree.txt が残らず exit 30" {
    Enable-GitWrap
    try {
        $run = "$script:Proj/.agents/workflow/runs/T1-1"
        $env:GIT_WRAP_FAIL = '1'
        Invoke-Script dispatch-worktree.ps1 create T1 1
        Remove-Item Env:GIT_WRAP_FAIL
        Assert-Eq 30 $script:Code "worktree add の失敗は exit 30"
        Assert-Eq "Next: escalate reason=worktree" (Get-LastLine) "escalate reason=worktree"
        Add-Result (-not (Test-Branch 'agents-run/T1-1')) "ブランチが残らない"
        Assert-FileAbsent "$run/worktree" "WT が残らない"
        Assert-FileAbsent "$run/worktree.txt" "worktree.txt が残らない"
        Assert-Contains ([System.IO.File]::ReadAllText($script:WrapLog)) "worktree add" "ラッパーが worktree add を受けた"

        Invoke-Script dispatch-worktree.ps1 create T1 1
        Assert-Eq 0 $script:Code "ラッパーを外すと同じ試行で create できる: $($script:Err)"
    } finally { Disable-GitWrap }
}

Invoke-TestCase "dispatch-worktree: 試行 2 の worktree add が失敗すると前の変更が本体に戻る" {
    Enable-GitWrap
    try {
        $run1 = ".agents/workflow/runs/T1-1"
        Invoke-Script dispatch-worktree.ps1 create T1 1
        Assert-Eq 0 $script:Code "create 1 exit: $($script:Err)"
        Write-Plain "$script:Proj/$run1/worktree/a.txt" "hello`n"
        Invoke-Script dispatch-worktree.ps1 collect T1 1
        Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
        Assert-FileExists "$script:Proj/a.txt" "collect で本体に a.txt が当たる"

        $env:GIT_WRAP_FAIL = '1'
        Invoke-Script dispatch-worktree.ps1 create T1 2
        Remove-Item Env:GIT_WRAP_FAIL
        Assert-Eq 30 $script:Code "試行 2 の失敗は exit 30"
        Assert-FileExists "$script:Proj/a.txt" "前の試行の変更が本体に戻る"
        Add-Result (-not (Test-Branch 'agents-run/T1-2')) "試行 2 のブランチが残らない"
    } finally { Disable-GitWrap }
}

Invoke-TestCase "dispatch-worktree: worktree add に -c core.longpaths=true が付く" {
    Enable-GitWrap
    try {
        Invoke-Script dispatch-worktree.ps1 create T1 1
        Assert-Eq 0 $script:Code "create exit: $($script:Err)"
        Assert-Contains ([System.IO.File]::ReadAllText($script:WrapLog)) "-c core.longpaths=true worktree add" "worktree add に -c core.longpaths=true が付く"
    } finally { Disable-GitWrap }
}

Invoke-TestCase "dispatch-worktree: create で worktree・ブランチ・worktree.txt ができる" {
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "最後の行は Next: continue"
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Add-Result (Test-Path -LiteralPath "$run/worktree" -PathType Container) "worktree ができる"
    Add-Result (Test-Branch 'agents-run/T1-1') "ブランチ agents-run/T1-1 ができる"
    Assert-FileExists "$run/worktree.txt" "worktree.txt ができる"
    $lines = @([System.IO.File]::ReadAllText("$run/worktree.txt") -split "`n" | Where-Object { $_ -ne '' })
    Assert-Eq 3 $lines.Count "worktree.txt は3行"
    Add-Result ($lines[0].StartsWith('path ')) "1行目は path"
    Assert-Eq "branch refs/heads/agents-run/T1-1" $lines[1] "2行目は branch"
    $head = "$(git -C $script:Proj rev-parse HEAD)".Trim()
    Assert-Eq "base $head" $lines[2] "3行目は base <HEAD>"
    Add-Result (Test-Path -LiteralPath "$run/worktree/.agents/workflow/runs/T1-1/tmp" -PathType Container) "worktree 内に tmp ができる"
    Assert-Contains $script:Out "Carried: none" "試行 1 は持ち越しなし"

    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 30 $script:Code "2回目は exit 30"
    Assert-Eq "Next: escalate reason=worktree" (Get-LastLine) "2回目は escalate reason=worktree"
}

Invoke-TestCase "dispatch-worktree: remove で worktree とブランチが消える" {
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create exit: $($script:Err)"
    Invoke-Script dispatch-worktree.ps1 remove T1 1
    Assert-Eq 0 $script:Code "remove exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "remove は Next: continue"
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Assert-FileAbsent "$run/worktree" "worktree が消える"
    Assert-FileAbsent "$run/worktree.txt" "worktree.txt が消える"
    Add-Result (-not (Test-Branch 'agents-run/T1-1')) "ブランチが消える"

    Invoke-Script dispatch-worktree.ps1 remove T1 1
    Assert-Eq 0 $script:Code "無くても remove は exit 0"
}

Invoke-TestCase "dispatch-worktree: 試行 2 の create で前の変更を持ち越す" {
    $run1 = ".agents/workflow/runs/T1-1"
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create 1 exit: $($script:Err)"
    [System.IO.File]::WriteAllText("$script:Proj/$run1/worktree/a.txt", "hello`n", (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-FileExists "$script:Proj/a.txt" "collect で本体に a.txt が当たる"
    Assert-FileExists "$script:Proj/$run1/changes.patch" "changes.patch ができる"

    Invoke-Script dispatch-worktree.ps1 create T1 2
    Assert-Eq 0 $script:Code "create 2 exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "最後の行は Next: continue"
    Assert-Contains $script:Out "Carried: $run1/changes.patch" "試行 1 の変更を持ち越す"
    Assert-FileAbsent "$script:Proj/a.txt" "本体から a.txt が取り除かれる"
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-2/worktree/a.txt" "新しい worktree に a.txt がある"
}

Invoke-TestCase "dispatch-worktree: collect で変更が本体に入り worktree が消える" {
    $wt = Initialize-Collect
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$wt/new.txt" "new`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-Eq "Next: review T1" (Get-LastLine) "最後の行は Next: review T1"
    Assert-Eq "line1`nfromwt`n" ([System.IO.File]::ReadAllText("$script:Proj/base.txt") -replace "`r`n", "`n") "既存ファイルの変更が本体に入る"
    Assert-FileExists "$script:Proj/new.txt" "新規ファイルが本体に入る"
    Assert-Contains $script:Out "Undeclared: new.txt" "変更対象に無い new.txt は Undeclared に出る"
    Assert-NotContains $script:Out "Undeclared: base.txt" "base.txt は Undeclared に出ない"
    Assert-FileAbsent $wt "worktree が消える"
    Add-Result (-not (Test-Branch 'agents-run/T1-1')) "ブランチが消える"
}

Invoke-TestCase "dispatch-worktree: collect で本体と衝突すると exit 40 で worktree が残る" {
    $wt = Initialize-Collect
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$script:Proj/base.txt" "line1`nfrommain`n"
    git -C $script:Proj commit -q -a -m "main change" *> $null
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 40 $script:Code "exit 40"
    Assert-Eq "Next: escalate reason=conflict" (Get-LastLine) "escalate reason=conflict"
    Add-Result (Test-Path -LiteralPath $wt -PathType Container) "worktree は残る"
}

Invoke-TestCase "dispatch-worktree: collect が成功すると collected ができる" {
    $wt = Initialize-Collect
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Assert-FileAbsent "$run/collected" "collect 前は collected が無い"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-FileExists "$run/collected" "collect が成功すると collected ができる"
}

Invoke-TestCase "dispatch-worktree: collect の衝突の後の create は前の試行を持ち越さない" {
    $wt = Initialize-Collect
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$script:Proj/base.txt" "line1`nfrommain`n"
    git -C $script:Proj commit -q -a -m "main change" *> $null
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 40 $script:Code "collect は exit 40"
    Assert-FileAbsent "$run/collected" "衝突した collect では collected ができない"

    Invoke-Script dispatch-worktree.ps1 create T1 2
    Assert-Eq 0 $script:Code "create 2 exit: $($script:Err)"
    Assert-Contains $script:Out "Carried: none (not collected:" "取り込まれなかった試行は持ち越さない"
    Assert-Eq "line1`nfrommain`n" ([System.IO.File]::ReadAllText("$script:Proj/base.txt") -replace "`r`n", "`n") "本体の base.txt は変わらない"
    Assert-FileExists "$run/changes.patch" "試行 1 の changes.patch がある"
}

Invoke-TestCase "dispatch-worktree: create で持ち越しが衝突すると exit 40 で WT・ブランチが残らず本体が戻る" {
    $wt = Initialize-Collect
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Write-Plain "$wt/base.txt" "mine`nline2`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-FileExists "$run/collected" "collect で collected ができる"
    Assert-Eq "mine`nline2`n" ([System.IO.File]::ReadAllText("$script:Proj/base.txt") -replace "`r`n", "`n") "本体の1行目は mine"
    Write-Plain "$script:Proj/base.txt" "theirs`nline2`n"
    git -C $script:Proj commit -q -a -m "theirs" *> $null
    Write-Plain "$script:Proj/base.txt" "mine`nline2`n"

    Invoke-Script dispatch-worktree.ps1 create T1 2
    Assert-Eq 40 $script:Code "持ち越しの衝突は exit 40"
    Assert-Eq "Next: escalate reason=conflict" (Get-LastLine) "escalate reason=conflict"
    Add-Result (-not (Test-Branch 'agents-run/T1-2')) "試行 2 のブランチが残らない"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-2/worktree" "試行 2 の WT が残らない"
    Assert-Eq "mine`nline2`n" ([System.IO.File]::ReadAllText("$script:Proj/base.txt") -replace "`r`n", "`n") "本体の1行目が mine に戻る"
}

Invoke-TestCase "dispatch-worktree: abort で worktree・ブランチ・worktree.txt が消える" {
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create exit: $($script:Err)"
    Invoke-Script dispatch-worktree.ps1 abort T1 1
    Assert-Eq 0 $script:Code "abort exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "abort は Next: continue"
    Assert-FileAbsent "$run/worktree" "worktree が消える"
    Assert-FileAbsent "$run/worktree.txt" "worktree.txt が消える"
    Add-Result (-not (Test-Branch 'agents-run/T1-1')) "ブランチが消える"
}

Invoke-TestCase "dispatch-worktree: abort で reverted のパッチが本体に当たり reverted が消える" {
    $run1 = "$script:Proj/.agents/workflow/runs/T1-1"
    $run2 = "$script:Proj/.agents/workflow/runs/T1-2"
    Invoke-Script dispatch-worktree.ps1 create T1 1
    Assert-Eq 0 $script:Code "create 1 exit: $($script:Err)"
    Write-Plain "$run1/worktree/a.txt" "hello`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Invoke-Script dispatch-worktree.ps1 create T1 2
    Assert-Eq 0 $script:Code "create 2 exit: $($script:Err)"
    Assert-FileAbsent "$script:Proj/a.txt" "create で本体から a.txt が取り除かれる"
    Assert-FileExists "$run2/reverted" "reverted ができる"

    Invoke-Script dispatch-worktree.ps1 abort T1 2
    Assert-Eq 0 $script:Code "abort exit: $($script:Err)"
    Assert-Eq "Next: continue" (Get-LastLine) "abort は Next: continue"
    Assert-FileExists "$script:Proj/a.txt" "abort で a.txt が本体に戻る"
    Assert-FileAbsent "$run2/reverted" "reverted が消える"
    Assert-FileAbsent "$run2/worktree" "試行 2 の WT が消える"
    Add-Result (-not (Test-Branch 'agents-run/T1-2')) "試行 2 のブランチが消える"
}

Invoke-TestCase "dispatch-worktree: collect で本体が dirty だと exit 20" {
    $wt = Initialize-Collect
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    Write-Plain "$script:Proj/base.txt" "dirty`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 20 $script:Code "exit 20"
    Assert-Eq "Next: escalate reason=dirty-tree" (Get-LastLine) "escalate reason=dirty-tree"
    Add-Result (Test-Path -LiteralPath $wt -PathType Container) "worktree は残る"
}

Invoke-TestCase "dispatch-worktree: collect で git add が失敗すると exit 30 で worktree が残り、直せば collect できる" {
    $wt = Initialize-Collect
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Write-Plain "$wt/base.txt" "line1`nfromwt`n"
    $gitdir = (git -C $wt rev-parse --absolute-git-dir).Trim()
    Write-Plain "$gitdir/index.lock" ""
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 30 $script:Code "exit 30"
    Assert-Eq "Next: escalate reason=worktree" (Get-LastLine) "escalate reason=worktree"
    Add-Result (Test-Path -LiteralPath $wt -PathType Container) "worktree は残る"
    Add-Result (Test-Branch 'agents-run/T1-1') "ブランチは残る"
    Assert-FileExists "$run/worktree.txt" "worktree.txt は残る"
    Remove-Item -LiteralPath "$gitdir/index.lock" -Force
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "index.lock を消すと collect できる: $($script:Err)"
}

Invoke-TestCase "dispatch-worktree: 子が worktree でコミットした変更が collect のパッチに入る" {
    $wt = Initialize-Collect
    Write-Plain "$wt/a.txt" "hello`n"
    git -C $wt add a.txt *> $null
    git -C $wt commit -q -m "child" *> $null
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "collect exit: $($script:Err)"
    Assert-FileExists "$script:Proj/a.txt" "子がコミットした a.txt が本体に入る"
}

Invoke-TestCase "dispatch-worktree: worktree.txt に base 行が無いと HEAD との差分で collect する" {
    $wt = Initialize-Collect
    $wtTxt = "$script:Proj/.agents/workflow/runs/T1-1/worktree.txt"
    $kept = @([System.IO.File]::ReadAllText($wtTxt) -split "`n" | Where-Object { $_ -ne '' -and $_ -notmatch '^base ' })
    Write-Plain $wtTxt (($kept -join "`n") + "`n")
    Write-Plain "$wt/a.txt" "hello`n"
    Invoke-Script dispatch-worktree.ps1 collect T1 1
    Assert-Eq 0 $script:Code "base 行が無くても collect できる: $($script:Err)"
    Assert-FileExists "$script:Proj/a.txt" "HEAD との差分で a.txt が本体に入る"
}

Invoke-TestCase "dispatch-worktree: worktree の run を dispatch-run で動かし dispatch-check が collect を返す" {
    Initialize-WtChild "Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Assert-Eq "EXIT:0" (Get-Content "$run/done" -Encoding utf8)[0] "done marker"
    Assert-FileExists "$run/worktree/a.txt" "子は worktree の中で a.txt を作る"
    Assert-FileAbsent "$script:Proj/a.txt" "本体の作業ツリーは変わらない"
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 0 $script:Code "check exit: $($script:Err)"
    Assert-Contains $script:Out "Guard: ok" "guard ok"
    Assert-Eq "Next: collect T1" (Get-LastLine) "最後の行は Next: collect T1"
}

Invoke-TestCase "dispatch-worktree: 子の実行中に本体で実行中のタスクの branch・commit をしても tampered にならない" {
    Set-State 'T1:in_progress' 'T2:in_progress'
    Initialize-WtChild "git -C '$script:Proj' branch agents-run/T2-1; git -C '$script:Proj' commit -q --allow-empty -m other; Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Assert-Eq "EXIT:0" (Get-Content "$script:Proj/.agents/workflow/runs/T1-1/done" -Encoding utf8)[0] "done marker"
    Add-Result (Test-Branch 'agents-run/T2-1') "子の実行中に本体で実行中のタスクの run のブランチができた"
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 0 $script:Code "本体の git 変更では tampered にならない: $($script:Out)"
    Assert-NotContains $script:Out "git changed" "git changed は出ない"
    Assert-Eq "Next: collect T1" (Get-LastLine) "最後の行は Next: collect T1"
}

Invoke-TestCase "dispatch-worktree: 子が worktree で commit すると tampered(exit 8)" {
    Initialize-WtChild "Set-Content a.txt hello; git add a.txt; git commit -q -m child; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "worktree で commit すると exit 8"
    Assert-Contains $script:Out "git changed: head" "git changed: head"
}

Invoke-TestCase "dispatch-worktree: 子が worktree で tag を作ると tampered(exit 8)" {
    Initialize-WtChild "Set-Content a.txt hello; git tag t1; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "worktree で tag を作ると exit 8"
    Assert-Contains $script:Out "git changed" "git changed"
}

Invoke-TestCase "dispatch-worktree: 子が本体の state.json の自分のタスクの欄を書き換えると tampered(exit 8)" {
    Set-State 'T1:in_progress' 'T2:pending'
    $sp = "$script:Proj/.agents/workflow/state.json"
    Initialize-WtChild "`$p = '$sp'; [System.IO.File]::WriteAllText(`$p, ([System.IO.File]::ReadAllText(`$p) -replace 'in_progress', 'done')); Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "本体の state.json の自分のタスクの status を書き換えると exit 8"
    Assert-Contains $script:Out "changed: .agents/workflow/state.json" "state.json の changed"
}

Invoke-TestCase "dispatch-worktree: 子が本体の tasks.md を書き換えると tampered(exit 8)" {
    Initialize-WtChild "Add-Content '$script:Proj/.agents/workflow/tasks.md' extra; Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "本体の tasks.md を書き換えると exit 8"
    Assert-Contains $script:Out "changed: .agents/workflow/tasks.md" "tasks.md の changed"
}

Invoke-TestCase "dispatch-worktree: 実行中の親の commit・ほかのタスクの欄・ほかの run のブランチでは tampered にならない" {
    Set-State 'T1:in_progress' 'T2:pending'
    $sp = "$script:Proj/.agents/workflow/state.json"
    Initialize-WtChild "git -C '$script:Proj' commit -q --allow-empty -m parent; `$p = '$sp'; [System.IO.File]::WriteAllText(`$p, ([System.IO.File]::ReadAllText(`$p) -replace 'pending', 'in_progress')); git -C '$script:Proj' branch agents-run/T2-1; Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Add-Result (Test-Branch 'agents-run/T2-1') "子の実行中に本体でほかの run のブランチができた"
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 0 $script:Code "親の作業・ほかのタスクの欄・ほかの run のブランチでは tampered にならない: $($script:Out)"
    Assert-NotContains $script:Out "changed" "changed は出ない"
    Assert-Eq "Next: collect T1" (Get-LastLine) "最後の行は Next: collect T1"
}

# 子の worktree に、本体の state.json の 1 タスクの欄を書き換えるスクリプト setstate.ps1 を置く
# 使い方: pwsh -NoProfile -File setstate.ps1 <state.json> <ID> <status> [<commit>]
function Write-SetStateScript {
    Write-Plain "$script:Proj/.agents/workflow/runs/T1-1/worktree/setstate.ps1" @'
param([string]$Path, [string]$Id, [string]$Status, [string]$Commit = '')
$s = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
foreach ($e in @($s.tasks)) {
    if ("$($e.id)" -eq $Id) {
        $e.status = $Status
        if ($Commit) { $e.commit = $Commit }
    }
}
[System.IO.File]::WriteAllText($Path, ($s | ConvertTo-Json -Depth 10))
'@
}

Invoke-TestCase "dispatch-worktree: 子が本体の state.json でほかのタスクを commit 無しで done にすると tampered(exit 8)" {
    Set-State 'T1:in_progress' 'T2:pending'
    $sp = "$script:Proj/.agents/workflow/state.json"
    Initialize-WtChild "& ./setstate.ps1 '$sp' T2 done; Set-Content a.txt hello; $WtReport"
    Write-SetStateScript
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "ほかのタスクを commit 無しで done にすると exit 8: $($script:Out)"
    Assert-Contains $script:Out "changed: .agents/workflow/state.json (T2)" "state.json (T2) の changed"
}

Invoke-TestCase "dispatch-worktree: 子が起動時に done だったタスクを pending に戻すと tampered(exit 8)" {
    Set-State 'T1:in_progress' 'T2:pending' 'T3:done'
    $sp = "$script:Proj/.agents/workflow/state.json"
    Initialize-WtChild "& ./setstate.ps1 '$sp' T3 pending; Set-Content a.txt hello; $WtReport"
    Write-SetStateScript
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "起動時に done だったタスクを pending に戻すと exit 8: $($script:Out)"
    Assert-Contains $script:Out "changed: .agents/workflow/state.json (T3)" "state.json (T3) の changed"
}

Invoke-TestCase "dispatch-worktree: 実行中に親がほかのタスクを正規に done にしても tampered にならない" {
    Set-State 'T1:in_progress' 'T2:pending'
    $sp = "$script:Proj/.agents/workflow/state.json"
    Initialize-WtChild "git -C '$script:Proj' commit -q --allow-empty -m parent; & ./setstate.ps1 '$sp' T2 in_progress; & ./setstate.ps1 '$sp' T2 in_review; & ./setstate.ps1 '$sp' T2 done (git -C '$script:Proj' rev-parse HEAD); Set-Content a.txt hello; $WtReport"
    Write-SetStateScript
    Invoke-Script dispatch-run.ps1 T1 1
    Assert-Eq "EXIT:0" (Get-Content "$script:Proj/.agents/workflow/runs/T1-1/done" -Encoding utf8)[0] "done marker"
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 0 $script:Code "親の正規の遷移(commit は本体の HEAD の祖先)では tampered にならない: $($script:Out)"
    Assert-NotContains $script:Out "changed" "changed は出ない"
}

Invoke-TestCase "dispatch-worktree: 子が本体で親の作業ブランチを巻き戻すと tampered(exit 8)" {
    git -C $script:Proj commit -q --allow-empty -m p1
    git -C $script:Proj commit -q --allow-empty -m p2
    $pb = "$(git -C $script:Proj symbolic-ref --short HEAD)".Trim()
    Initialize-WtChild "git -C '$script:Proj' update-ref refs/heads/$pb HEAD~1; Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "親の作業ブランチを巻き戻すと exit 8: $($script:Out)"
    Assert-Contains $script:Out "git changed: parent" "git changed: parent"
}

Invoke-TestCase "dispatch-worktree: 子が実行中でないタスクの run のブランチを作ると tampered(exit 8)" {
    Set-State 'T1:in_progress' 'T9:pending'
    Initialize-WtChild "git -C '$script:Proj' branch agents-run/T9-1; Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 8 $script:Code "実行中でないタスクの run のブランチを作ると exit 8: $($script:Out)"
    Assert-Contains $script:Out "git changed: refs" "git changed: refs"
}

Invoke-TestCase "dispatch-worktree: 起動前からある実行中のタスクの run のブランチは tampered にならない" {
    Set-State 'T1:in_progress' 'T2:in_progress'
    git -C $script:Proj branch agents-run/T2-1 *> $null
    Initialize-WtChild "Set-Content a.txt hello; $WtReport"
    Invoke-Script dispatch-run.ps1 T1 1
    Invoke-Script dispatch-check.ps1 T1 1
    Assert-Eq 0 $script:Code "起動前からある実行中のタスクの run のブランチでは tampered にならない: $($script:Out)"
    Assert-NotContains $script:Out "changed" "changed は出ない"
}

Invoke-TestCase "dispatch-worktree: git-state の -OtherRuns は指定した ID の run のブランチだけを除く" {
    $pr = "refs/heads/$("$(git -C $script:Proj symbolic-ref --short HEAD)".Trim())"
    git -C $script:Proj branch agents-run/T1-1 *> $null
    Invoke-Script git-state.ps1 -Run refs/heads/agents-run/T1-1 -Parent $pr -OtherRuns T2
    $base = @($script:Out -split "`n" | Where-Object { $_ -like 'refs *' })[0]
    git -C $script:Proj branch agents-run/T2-1 *> $null
    Invoke-Script git-state.ps1 -Run refs/heads/agents-run/T1-1 -Parent $pr -OtherRuns T2
    $withT2 = @($script:Out -split "`n" | Where-Object { $_ -like 'refs *' })[0]
    Assert-Eq $base $withT2 "-OtherRuns に入っている T2 の run のブランチは除かれる"
    git -C $script:Proj branch agents-run/T9-1 *> $null
    Invoke-Script git-state.ps1 -Run refs/heads/agents-run/T1-1 -Parent $pr -OtherRuns T2
    $withT9 = @($script:Out -split "`n" | Where-Object { $_ -like 'refs *' })[0]
    Add-Result ($base -cne $withT9) "-OtherRuns に無い T9 の run のブランチは除かれない"
}

Show-Summary
