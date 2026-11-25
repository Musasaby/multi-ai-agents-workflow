# dispatch-prompt-gen -Review(レビュー用プロンプトの機械生成, PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Set-ReviewTasks {
    Set-Tasks "## T1: レビュー対象のタスク`n- **依存**: なし`n"
}

# comprehension_check を有効にする
function Enable-ComprehensionCheck {
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cc = [ordered]@{ enabled = $true; questions_per_task = 2 }
    $cfg | Add-Member -NotePropertyName comprehension_check -NotePropertyValue $cc -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

# 完了報告を echo するスタブの子で review の run を dispatch-run に作らせる
function Set-ReviewChild {
    param([string]$Body)
    Write-Utf8File "$script:Proj/review-child.ps1" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.PSObject.Properties.Remove('review')
    $cfg | Add-Member -NotePropertyName review -NotePropertyValue ([pscustomobject]@{ command_template = 'pwsh -NoProfile -File ./review-child.ps1 "{prompt}"' })
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

function New-ReviewRun {
    param([string]$Report, [string]$Extra = '')
    $body = (@($Report -split "`n") | ForEach-Object { "Write-Output '" + ($_ -replace "'", "''") + "'" }) -join "`n"
    $body += "`n"
    if ($Extra) { $body += $Extra + "`n" }
    Set-ReviewChild $body
    Write-Utf8File "$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md" "prompt`n"
    Invoke-Script dispatch-run.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
}

# 子が本体の state.json の 1 タスクの欄を書き換えるためのスクリプトを置く
# 使い方(子から): pwsh -NoProfile -File ./setstate.ps1 <state.json> <ID> <status> [<retries>]
function Set-ChildStateScript {
    $body = @'
param([string]$Path, [string]$Id, [string]$Status, [int]$Retries = -1)
$s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
foreach ($e in $s.tasks) {
    if ("$($e.id)" -eq $Id) {
        $e.status = $Status
        if ($Retries -ge 0) { $e.retries = $Retries }
    }
}
[System.IO.File]::WriteAllText($Path, ($s | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
'@
    Write-Utf8File "$script:Proj/setstate.ps1" $body
}

Write-Host "test-review.ps1"

Invoke-TestCase "review のプロンプトを生成する" {
    Set-ReviewTasks
    Set-Report -TaskId 'T1' -Attempt 1
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "RunId: review-T1" "run id"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md")
    Assert-Contains $prompt "レビュー対象のタスク" "task title"
    Assert-Contains $prompt ".agents/workflow/runs/T1-1/report.md" "report path"
    Assert-Contains $prompt ".agents/workflow/runs/T1-2/fix-notes.md" "fix notes path"
    Assert-Contains $prompt "質問ファイルは作らない" "comprehension disabled instruction"
}

Invoke-TestCase "worktree の run のレビューは絶対パスと追加の節を入れる" {
    Set-ReviewTasks
    Set-Report -TaskId 'T1' -Attempt 1
    $wt = "$script:Proj/wt".Replace('\', '/')
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/runs/review-T1-1"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/review-T1-1/worktree.txt" "path $wt`nbranch refs/heads/agents-run/T1-1`nbase HEAD`n"
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md")
    $mainRoot = "$script:Proj".Replace('\', '/')
    Assert-Contains $prompt "## worktree でレビューする場合の追加の指示" "worktree section"
    Assert-Contains $prompt $wt "worktree path"
    Assert-Contains $prompt "$mainRoot/.agents/workflow/runs/T1-2/fix-notes.md" "fix notes path"
    Assert-Contains $prompt "$mainRoot/.agents/workflow/runs/T1-1/report.md" "report path"
    Assert-NotContains $prompt "{workdir}" "workdir placeholder replaced"
    Assert-NotContains $prompt "{main_root}" "main_root placeholder replaced"
}

Invoke-TestCase "report.md が無いと exit 2" {
    Set-ReviewTasks
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 2 $script:Code "missing report -> exit 2"
}

Invoke-TestCase "review: 長いタスクの節でもプロンプトを生成する" {
    $body = "## T1: レビュー対象のタスク`n- **目的**: " + [string]::new('x', 140000) + "`nEND-OF-TASK-SECTION`n- **依存**: なし`n"
    [System.IO.File]::WriteAllText("$script:Proj/.agents/workflow/tasks.md", $body, [System.Text.UTF8Encoding]::new($false))
    Set-Report -TaskId 'T1' -Attempt 1
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md")
    Assert-Contains $prompt "END-OF-TASK-SECTION" "task section end"
}

Invoke-TestCase "理解確認が有効なら質問ファイルの指示を入れる" {
    Set-ReviewTasks
    Set-Report -TaskId 'T1' -Attempt 1
    Enable-ComprehensionCheck
    Invoke-Script dispatch-prompt-gen.ps1 '-Review' '-TaskId' 'T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/prompt.md")
    Assert-Contains $prompt ".agents/workflow/comprehension/T1.md" "question file path"
    Assert-Contains $prompt "2 問" "question count"
}

Invoke-TestCase "合格なら commit を出す" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Next: commit T1" "next commit"
    Assert-Contains $script:Out "Review summary: 問題なし" "review summary"
}

Invoke-TestCase "type が決まった値なら Review type に出す" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- type: feat`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Review type: feat" "review type"
    Assert-Eq "Next: commit T1" (($script:Out -split "`n")[-1]).Trim() "last line"
}

Invoke-TestCase "type が無い・決まった値でなければ Review type は invalid" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "missing type -> exit 0: $($script:Err)"
    Assert-Contains $script:Out "Review type: invalid" "missing type -> invalid"
    Assert-Eq "Next: commit T1" (($script:Out -split "`n")[-1]).Trim() "last line"

    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- type: bogus`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "bogus type -> exit 0: $($script:Err)"
    Assert-Contains $script:Out "Review type: invalid" "bogus type -> invalid"
    Assert-Eq "Next: commit T1" (($script:Out -split "`n")[-1]).Trim() "last line"
}

Invoke-TestCase "不合格で fix-notes があれば retry を出す" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: fail`n- 指摘: a.txt の修正`n- 要約: 修正が必要`n- fix-notes: あり`n- 理解確認: 対象外" `
        "New-Item -ItemType Directory -Force '.agents/workflow/runs/T1-2' | Out-Null; Set-Content -Path '.agents/workflow/runs/T1-2/fix-notes.md' -Value '修正点'"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "Next: retry T1" "next retry"
}

Invoke-TestCase "不合格で fix-notes が無ければ no-report" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: fail`n- 指摘: a.txt の修正`n- 要約: 修正が必要`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 5 $script:Code "missing fix-notes -> exit 5"
    Assert-Contains $script:Out "fix-notes not found" "fix-notes not found"
}

Invoke-TestCase "Verdict が pass/fail 以外なら no-report" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: ok`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 5 $script:Code "invalid verdict -> exit 5"
    Assert-Contains $script:Out "Verdict must be pass or fail" "invalid verdict message"
}

Invoke-TestCase "レビューの run が作業ツリーを変えたら tampered" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外" `
        "Set-Content -Path a.txt -Value 'changed'"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 8 $script:Code "main tree changed -> exit 8"
    Assert-Contains $script:Out "changed: main worktree: a.txt" "changed main worktree"
}

Invoke-TestCase "レビューの run の子がほかのタスクの欄を変えても tampered にならない" {
    Set-ReviewTasks
    Set-State 'T1:in_progress' 'T2:pending'
    Set-ChildStateScript
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外" `
        "& pwsh -NoProfile -File ./setstate.ps1 .agents/workflow/state.json T2 in_progress"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "ほかのタスクの欄を変えても tampered にならない: $($script:Out)"
    Assert-NotContains $script:Out "changed" "changed は出ない"
    Assert-Eq "Next: commit T1" (($script:Out -split "`n")[-1]).Trim() "最後の行は Next: commit T1"
}

Invoke-TestCase "レビューの run の子が対象タスクの retries を変えると tampered" {
    Set-ReviewTasks
    Set-State 'T1:in_progress' 'T2:pending'
    Set-ChildStateScript
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外" `
        "& pwsh -NoProfile -File ./setstate.ps1 .agents/workflow/state.json T1 in_progress 5"
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 8 $script:Code "対象タスクの retries を変えると exit 8: $($script:Out)"
    Assert-Contains $script:Out "changed: .agents/workflow/state.json (T1)" "state.json (T1) の changed"
}

Invoke-TestCase "レビューの run の子に PYTHONDONTWRITEBYTECODE=1 が渡る" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外" `
        'Write-Output "PYC=$env:PYTHONDONTWRITEBYTECODE"'
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $log = [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/review-T1-1/output.log")
    Assert-Contains $log "PYC=1" "PYTHONDONTWRITEBYTECODE=1 が子に渡る"
}

Invoke-TestCase "レビューの run の後に本体を更新したファイルは modified after the run ended" {
    Set-ReviewTasks
    New-ReviewRun "## 完了報告`n- Verdict: pass`n- 指摘: なし`n- 要約: 問題なし`n- fix-notes: なし`n- 理解確認: 対象外"
    Write-Utf8File "$script:Proj/late.txt" "late`n"
    (Get-Item "$script:Proj/late.txt").LastWriteTime = (Get-Date).AddSeconds(60)
    Invoke-Script dispatch-check.ps1 '-TaskId' 'review-T1' '-Attempt' '1'
    Assert-Eq 8 $script:Code "終了後の変更 -> exit 8"
    Assert-Contains $script:Out "changed: main worktree: late.txt (modified after the run ended)" "modified after the run ended"
}

Show-Summary
