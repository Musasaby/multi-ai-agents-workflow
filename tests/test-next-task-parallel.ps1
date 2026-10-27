# next-task: max_parallel が 2 以上のときの並列選択(PowerShell版)
. "$PSScriptRoot/lib.ps1"

# config.json に max_parallel を足す
function Set-MaxParallel {
    param([int]$Value)
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName max_parallel -NotePropertyValue $Value -Force
    Write-Utf8File $path ($cfg | ConvertTo-Json -Depth 10)
}

# 依存なしの T1・T2 を、変更対象 $A・$B で書く
function Set-TwoTasks {
    param([string]$A, [string]$B)
    Set-Tasks @"
# タスク一覧: test

## T1: 一番目
- **目的**: a
- **対象**: ``$A``(変更対象)
- **依存**: なし

## T2: 二番目
- **目的**: b
- **対象**: ``$B``(変更対象)
- **依存**: なし
"@
}

function Get-LastLine { return ($script:Out -split "`n")[-1] }

Invoke-TestCase "parallel: 変更対象が重ならなければ両方dispatch" {
    Set-TwoTasks 'src/a.txt' 'src/b.txt'
    Set-State 'T1:pending' 'T2:pending'
    Set-MaxParallel 3
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq 'Next: dispatch T1 T2' (Get-LastLine) "both tasks are chosen"
}

Invoke-TestCase "parallel: 変更対象が重なれば先頭だけdispatch" {
    Set-TwoTasks 'src/a.txt' 'src/a.txt'
    Set-State 'T1:pending' 'T2:pending'
    Set-MaxParallel 3
    Invoke-Script next-task.ps1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Eq 'Next: dispatch T1' (Get-LastLine) "only the first task is chosen"
}

Invoke-TestCase "parallel: 空きが無ければwait(exit 5)" {
    Set-TwoTasks 'src/a.txt' 'src/b.txt'
    Set-State 'T1:in_progress' 'T2:in_progress'
    Set-MaxParallel 2
    Invoke-Script next-task.ps1
    Assert-Eq 5 $script:Code "exit code: $($script:Err)"
    Assert-Eq 'Next: wait T1 T2' (Get-LastLine) "waits for running tasks"
}

Invoke-TestCase "parallel: README.md を含むタスクは実行中があると選ばれない" {
    Set-TwoTasks 'src/a.txt' 'README.md'
    Set-State 'T1:in_progress' 'T2:pending'
    Set-MaxParallel 3
    Invoke-Script next-task.ps1
    Assert-Eq 5 $script:Code "exit code: $($script:Err)"
    Assert-Eq 'Next: wait T1' (Get-LastLine) "README.md task is not chosen while another is running"
}

Show-Summary
