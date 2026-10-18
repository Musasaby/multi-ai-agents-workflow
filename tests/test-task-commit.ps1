# #58: task-commit(本体コミット・状態更新・状態ファイルのコミット, PowerShell版)。
# gh は lib.ps1 のスタブで差し替え、コミットの内容・state.json の更新・失敗時に何も変わらないことを検証する。
. "$PSScriptRoot/lib.ps1"

function Invoke-Git {
    Push-Location $script:Proj
    try { & git @args 2>$null } finally { Pop-Location }
}

# 作業ブランチ develop/t に切り替え、state.json の T1 を in_review・branch を develop/t にする
function Initialize-Review {
    Invoke-Git checkout -q -b develop/t
    Set-State 'T1:in_review'
    $path = "$script:Proj/.agents/workflow/state.json"
    $s = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $s.branch = 'develop/t'
    Write-Utf8File $path (($s | ConvertTo-Json -Depth 10) + "`n")
    Set-GhStubResult -Stdout '[]'
}

function Get-CommitCount { return [int](Invoke-Git rev-list --count HEAD) }

Write-Host "test-task-commit.ps1"

Invoke-TestCase "commit: 本体をコミットし done とハッシュを記録する" {
    Initialize-Review
    Write-Utf8File "$script:Proj/a.txt" "a`n"
    Invoke-Script task-commit.ps1 -TaskId T1 -Type feat -Description "説明"
    Assert-Eq 0 $script:Code "exit code: $script:Err"
    $msg = (@(Invoke-Git log -1 --format=%B) -join "`n")
    $head = (Invoke-Git rev-parse HEAD)
    Assert-Contains $msg "feat: 説明" "subject"
    Assert-Contains $msg "Task: T1 (test)" "task trailer"
    $t = Get-StateTask T1
    Assert-Eq "done" $t.status "T1 is done"
    Assert-Eq $head $t.commit "commit hash recorded"
    Assert-Eq "Next: continue" ($script:Out -split "`n" | Select-Object -Last 1) "last line is the Next: line"
}

Invoke-TestCase "commit: .agents を追跡しないリポジトリでは状態コミットをしない" {
    Initialize-Review
    Write-Utf8File "$script:Proj/a.txt" "a`n"
    $before = Get-CommitCount
    Invoke-Script task-commit.ps1 -TaskId T1 -Type fix -Description "説明"
    Assert-Eq 0 $script:Code "exit code: $script:Err"
    Assert-Contains $script:Out "State commit: none" "no state commit"
    Assert-Eq ($before + 1) (Get-CommitCount) "only the body commit was added"
}

Invoke-TestCase "commit: 状態ファイルを追跡するリポジトリでは chore コミットを作る" {
    Write-Utf8File "$script:Proj/.gitignore" ".agents/workflow/runs/`n"
    Initialize-Review
    Set-Tasks "## T1: test`n"
    Invoke-Git add .gitignore .agents/workflow/state.json .agents/workflow/tasks.md
    Invoke-Git commit -q -m "chore: state"
    Write-Utf8File "$script:Proj/a.txt" "a`n"
    Invoke-Script task-commit.ps1 -TaskId T1 -Type feat -Description "説明"
    Assert-Eq 0 $script:Code "exit code: $script:Err"
    Assert-Eq "chore: T1 の進捗状態を更新" (Invoke-Git log -1 --format=%s) "state commit subject"
    Assert-Contains ((Invoke-Git show --name-only --format= HEAD) -join "`n") ".agents/workflow/state.json" "state.json in state commit"
    Assert-Eq "feat: 説明" (Invoke-Git log -1 --format=%s HEAD~1) "body commit before it"
    Assert-NotContains ((Invoke-Git show --name-only --format= HEAD~1) -join "`n") ".agents/" "body commit has no .agents"
    Assert-NotContains $script:Out "State commit: none" "state commit reported"
}

Invoke-TestCase "commit: 変更が無ければ exit 20" {
    Initialize-Review
    $beforeState = Get-StateText
    $beforeHead = Invoke-Git rev-parse HEAD
    Invoke-Script task-commit.ps1 -TaskId T1 -Type feat -Description "説明"
    Assert-Eq 20 $script:Code "exit code: $script:Err"
    Assert-Eq "Next: escalate reason=no-changes" ($script:Out -split "`n" | Select-Object -Last 1) "last line is the Next: line"
    Assert-Eq "in_review" (Get-StateTask T1).status "T1 stays in_review"
    Assert-Eq $beforeState (Get-StateText) "state.json unchanged"
    Assert-Eq $beforeHead (Invoke-Git rev-parse HEAD) "HEAD unchanged"
}

Invoke-TestCase "commit: main 上なら exit 12 でコミットしない" {
    Set-State 'T1:in_review'
    Set-GhStubResult -Stdout '[]'
    Write-Utf8File "$script:Proj/a.txt" "a`n"
    $beforeState = Get-StateText
    $beforeHead = Invoke-Git rev-parse HEAD
    Invoke-Script task-commit.ps1 -TaskId T1 -Type feat -Description "説明"
    Assert-Eq 12 $script:Code "exit code: $script:Err"
    Assert-Eq "in_review" (Get-StateTask T1).status "T1 stays in_review"
    Assert-Eq $beforeState (Get-StateText) "state.json unchanged"
    Assert-Eq $beforeHead (Invoke-Git rev-parse HEAD) "HEAD unchanged"
}

Show-Summary
