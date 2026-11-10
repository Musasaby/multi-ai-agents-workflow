# サブエージェントの run(launcher が subagent): prompt.md の追加の節・dispatch-finish・dispatch-wait。
# run ディレクトリは dispatch-start -SubagentCapable(config.json を subagent: always にして)で準備する。
. "$PSScriptRoot/lib.ps1"

function Invoke-Git {
    Push-Location $script:Proj
    & git @args 2>$null
    Pop-Location
}

$script:Section = '## サブエージェントとして実行する場合の追加の指示'
$script:Report = "作業しました`n## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス`n"

function Set-ChildCfg { param([string]$Key, [string]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

function Set-MaxParallel { param([int]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName max_parallel -NotePropertyValue $Value -Force
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

function Set-StateBranch { param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

# 作業ブランチ・tasks.md・state.json を用意し、subagent always で dispatch-start -SubagentCapable を実行する
function Initialize-SubagentRun { param([int]$MaxParallel = 0)
    Invoke-Git switch -q -c develop/t
    Set-Tasks @'
## T1: 一番目
- **目的**: a
- **依存**: なし

'@
    Set-State 'T1:pending'
    Set-StateBranch develop/t
    Set-GhStubResult -Stdout '[]'
    Set-ChildCfg subagent always
    if ($MaxParallel -gt 0) { Set-MaxParallel $MaxParallel }
    Invoke-Script dispatch-start.ps1 -TaskId T1 -SubagentCapable
}

function Get-RunDir { return "$script:Proj/.agents/workflow/runs/T1-1" }
function Get-LastLine { param([string]$Text) return ($Text -split "`n" | Select-Object -Last 1).Trim() }
function Get-WorktreePath {
    $line = [System.IO.File]::ReadAllLines("$(Get-RunDir)/worktree.txt") | Where-Object { $_ -like 'path *' } | Select-Object -First 1
    return $line.Substring(5).Trim()
}
function Get-SectionTail {
    $prompt = [System.IO.File]::ReadAllText("$(Get-RunDir)/prompt.md")
    $idx = $prompt.LastIndexOf($script:Section)
    if ($idx -lt 0) { return '' }
    return $prompt.Substring($idx + $script:Section.Length)
}

Write-Host "test-dispatch-subagent.ps1"

Invoke-TestCase "subagent: prompt.md の末尾に節があり、プレースホルダが絶対パスに置き換わる" {
    Initialize-SubagentRun
    Assert-Eq 0 $script:Code "start exit code: $($script:Err)"
    $prompt = [System.IO.File]::ReadAllText("$(Get-RunDir)/prompt.md")
    Assert-Contains $prompt $script:Section "節の見出し"
    $tail = Get-SectionTail
    Assert-NotContains $tail '{workdir}' "workdir が置換済み"
    Assert-NotContains $tail '{tmp_dir}' "tmp_dir が置換済み"
    Assert-NotContains $tail '{output_log}' "output_log が置換済み"
    $root = $script:Proj -replace '\\', '/'
    Assert-Contains $tail ('`' + $root + '`') "workdir が利用先の絶対パス"
    Assert-Contains $tail "$root/.agents/workflow/runs/T1-1/tmp" "tmp_dir が絶対パス"
    Assert-Contains $tail "$root/.agents/workflow/runs/T1-1/output.log" "output_log が絶対パス"
    Assert-Contains $tail '.agents/workflow/runs/T1-1/tmp' "tmp_dir の値"
    Assert-Contains $tail '.agents/workflow/runs/T1-1/output.log' "output_log の値"
    Assert-Eq 0 ([regex]::Matches($tail, '\\').Count) "パスが / 区切り"
}

Invoke-TestCase "subagent: max_parallel 2 では {workdir} が worktree のパスになる" {
    Initialize-SubagentRun 2
    Assert-Eq 0 $script:Code "start exit code: $($script:Err)"
    Assert-FileExists "$(Get-RunDir)/worktree.txt" "worktree.txt"
    $wt = (Get-WorktreePath) -replace '\\', '/'
    $tail = Get-SectionTail
    Assert-Contains $tail ('`' + $wt + '`') "workdir が worktree のパス"
    Assert-Contains $tail "$wt/.agents/workflow/runs/T1-1/tmp" "tmp_dir が worktree 配下"
    Assert-NotContains $tail '{workdir}' "workdir が置換済み"
}

Invoke-TestCase "subagent: dispatch-finish は Profile: subagent で Next: review になり report.md を作る" {
    Initialize-SubagentRun
    Assert-Eq 0 $script:Code "start exit code: $($script:Err)"
    Write-Utf8File "$(Get-RunDir)/output.log" $script:Report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-finish.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "finish exit code: $($script:Err)"
    Assert-Contains $script:Out 'Profile: subagent' "Profile"
    Assert-Eq 'Next: review T1' (Get-LastLine $script:Out) "last line"
    Assert-FileExists "$(Get-RunDir)/report.md" "report.md"
    Assert-FileExists "$(Get-RunDir)/done" "done"
}

Invoke-TestCase "subagent: worktree の run の dispatch-finish は Next: collect になる" {
    Initialize-SubagentRun 2
    Assert-Eq 0 $script:Code "start exit code: $($script:Err)"
    $wt = Get-WorktreePath
    Write-Utf8File "$(Get-RunDir)/output.log" $script:Report
    Write-Utf8File "$wt/a.txt" "x`n"
    Invoke-Script dispatch-finish.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "finish exit code: $($script:Err)"
    Assert-Contains $script:Out 'Profile: subagent' "Profile"
    Assert-Eq 'Next: collect T1' (Get-LastLine $script:Out) "last line"
    Assert-FileExists "$(Get-RunDir)/report.md" "report.md"
}

Invoke-TestCase "subagent: output.log が無いと dispatch-finish は exit 1" {
    Initialize-SubagentRun
    Assert-Eq 0 $script:Code "start exit code: $($script:Err)"
    Invoke-Script dispatch-finish.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err 'output.log not found' "stderr"
    Assert-FileAbsent "$(Get-RunDir)/done" "done は作られない"
}

Invoke-TestCase "subagent: dispatch-wait はサブエージェントの run で exit 1" {
    Initialize-SubagentRun
    Assert-Eq 0 $script:Code "start exit code: $($script:Err)"
    Invoke-Script dispatch-wait.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 1 $script:Code "exit code"
    Assert-Contains $script:Err 'subagent run' "stderr"
}

Show-Summary
