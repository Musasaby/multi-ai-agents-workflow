# PowerShell セッション内で `& script.ps1` と直接呼んだときにも、成功時に $LASTEXITCODE が 0 になること。
# (exit を呼ばずに終わるスクリプトは $LASTEXITCODE を更新しないため、直前の値や空のまま残る)
# 動的検査は _templates/workflow/scripts/ の直接実行する .ps1(tasklib.ps1 以外)の全 12 本に
# 1 件ずつある。静的検査(最後の行が exit で始まるか)は補助として残す。
. "$PSScriptRoot/lib.ps1"

# スクリプトを同じプロセスで呼び、呼び出し後の $LASTEXITCODE を返す(直前の値は 99 にしておく)
function Invoke-InProcess {
    param([string]$Name, [hashtable]$Params = @{})
    Push-Location $script:Proj
    try {
        $global:LASTEXITCODE = 99
        & "$script:Proj/.agents/workflow/scripts/$Name" @Params *> $null
        return $global:LASTEXITCODE
    } finally {
        Pop-Location
    }
}

Write-Host "test-exitcode.ps1"

Invoke-TestCase "静的検査: 直接実行するスクリプトは exit で終わる" {
    foreach ($f in Get-ChildItem "$script:TemplateScripts/*.ps1") {
        if ($f.Name -eq 'tasklib.ps1') { continue }   # dot-source される部品
        $last = (Get-Content $f.FullName | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1).Trim()
        Add-Result ($last -match '^exit\b') "$($f.Name) ends with '$last' (expected an exit statement)"
    }
}

Invoke-TestCase "dispatch-prompt-gen: 成功時に LASTEXITCODE=0" {
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Set-State 'T1:pending'
    Assert-Eq 0 (Invoke-InProcess dispatch-prompt-gen.ps1 @{ TaskId = 'T1' }) "LASTEXITCODE"
}

Invoke-TestCase "state-sync: 成功時に LASTEXITCODE=0" {
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Assert-Eq 0 (Invoke-InProcess state-sync.ps1 @{ Init = $true; Source = 'test' }) "LASTEXITCODE"
}

Invoke-TestCase "workflow-archive: 成功時に LASTEXITCODE=0" {
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Set-State 'T1:done'
    Assert-Eq 0 (Invoke-InProcess workflow-archive.ps1 @{ Slug = 'test' }) "LASTEXITCODE"
}

Invoke-TestCase "dispatch-run: 成功時に LASTEXITCODE=0" {
    Write-Utf8File "$script:Proj/child.ps1" 'exit 0'
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'pwsh -NoProfile -File ./child.ps1 "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt`n"
    Assert-Eq 0 (Invoke-InProcess dispatch-run.ps1 @{ TaskId = 'T1'; Attempt = 1 }) "LASTEXITCODE"
}

Invoke-TestCase "next-task: 成功時に LASTEXITCODE=0" {
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Set-State 'T1:pending'
    Assert-Eq 0 (Invoke-InProcess next-task.ps1) "LASTEXITCODE"
}

Invoke-TestCase "task-state: 成功時に LASTEXITCODE=0" {
    Set-State 'T1:pending'
    Assert-Eq 0 (Invoke-InProcess task-state.ps1 @{ TaskId = 'T1'; Action = 'start' }) "LASTEXITCODE"
}

Invoke-TestCase "task-commit: 成功時に LASTEXITCODE=0" {
    Push-Location $script:Proj
    git checkout -q -b develop/t 2>$null
    Pop-Location
    Set-State 'T1:in_review'
    $path = "$script:Proj/.agents/workflow/state.json"
    $s = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $s.branch = 'develop/t'
    Write-Utf8File $path (($s | ConvertTo-Json -Depth 10) + "`n")
    Set-GhStubResult -Stdout '[]'
    Write-Utf8File "$script:Proj/a.txt" "a`n"
    Assert-Eq 0 (Invoke-InProcess task-commit.ps1 @{ TaskId = 'T1'; Type = 'feat'; Description = 'x' }) "LASTEXITCODE"
}

Invoke-TestCase "dispatch-check: 成功時に LASTEXITCODE=0" {
    # 正常終了した run(dispatch-run が guard.sha256 を書く)の後の check。子は a.txt を変更し、
    # 完了報告(変更ファイル/テスト結果)を output.log に残す
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Set-State 'T1:in_progress'
    Write-Utf8File "$script:Proj/child.ps1" "Set-Content -Path a.txt -Value x; Write-Output '## 完了報告'; Write-Output '- 変更ファイル: a.txt'; Write-Output '- テスト結果: 全件パス'"
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'pwsh -NoProfile -File ./child.ps1 "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Assert-Eq 0 (Invoke-InProcess dispatch-run.ps1 @{ TaskId = 'T1'; Attempt = 1 }) "run LASTEXITCODE"
    Assert-Eq 0 (Invoke-InProcess dispatch-check.ps1 @{ TaskId = 'T1'; Attempt = 1 }) "check LASTEXITCODE"
}

Invoke-TestCase "dispatch-wait: 成功時に LASTEXITCODE=0" {
    # T13 のケース1と同じ run(EXIT:0・完了報告あり・a.txt の変更あり)。guard.sha256 と
    # git-state.txt は dispatch-run と同じ形式で書く(test-dispatch-wait.ps1 と同じ作り方)
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Set-State 'T1:in_progress'
    $run = "$script:Proj/.agents/workflow/runs/T1-1"
    Write-Utf8File "$run/prompt.md" "prompt`n"
    Write-Utf8File "$run/done" "EXIT:0`nEND:2026-01-01T00:00:00+09:00`n"
    Write-Utf8File "$run/output.log" "作業しました`n## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス`n"
    Push-Location $script:Proj
    $guard = foreach ($f in @('.agents/workflow/runs/T1-1/prompt.md', '.agents/workflow/state.json', '.agents/workflow/tasks.md', '.agents/workflow/config.json')) {
        $h = if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() } else { '-' }
        "$h  $f"
    }
    $gitState = @(& pwsh -NoProfile -File .agents/workflow/scripts/git-state.ps1)
    Pop-Location
    Write-Utf8File "$run/guard.sha256" (($guard -join "`n") + "`n")
    Write-Utf8File "$run/git-state.txt" (($gitState -join "`n") + "`n")
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Assert-Eq 0 (Invoke-InProcess dispatch-wait.ps1 @{ TaskId = 'T1' }) "LASTEXITCODE"
}

Invoke-TestCase "dispatch-start: 成功時に LASTEXITCODE=0" {
    # test-dispatch-start.ps1 のケース1と同じ準備。起動した子の done を待ってから終える
    Push-Location $script:Proj
    try { git switch -q -c develop/t 2>$null } finally { Pop-Location }
    Set-Tasks "## T1: a`n- **依存**: なし`n"
    Set-State 'T1:pending'
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = 'develop/t'
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
    Set-GhStubResult -Stdout '[]'
    Write-Utf8File "$script:Proj/.agents/child.sh" "#!/bin/bash`necho child`n"
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'bash ./.agents/child.sh "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Assert-Eq 0 (Invoke-InProcess dispatch-start.ps1 @{ TaskId = 'T1' }) "LASTEXITCODE"
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path "$script:Proj/.agents/workflow/runs/T1-1/done") { break }
        Start-Sleep -Milliseconds 500
    }
}

Invoke-TestCase "branch-check: 成功時に LASTEXITCODE=0" {
    # develop/x 上に切り替え、gh スタブが [] を出力して exit 0(マージ済み PR なし)の成功経路
    Push-Location $script:Proj
    try { git checkout -q -b develop/x 2>$null } finally { Pop-Location }
    Set-GhStubResult -Stdout '[]'
    Assert-Eq 0 (Invoke-InProcess branch-check.ps1) "LASTEXITCODE"
}

# グループ P(T1)・A(T2, T3)。既定グループにタスクは無い(test-group-advance.ps1 と同じ)
$paTasks = @'
<!-- グループ P -->

## T1: Pの処理
- **目的**: p
- **依存**: なし

<!-- グループ A -->

## T2: Aの処理
- **目的**: a
- **依存**: T1

## T3: Aの処理2
- **目的**: b
- **依存**: T2
'@

function Set-StateBranch { param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

Invoke-TestCase "group-advance: 成功時に LASTEXITCODE=0" {
    # origin(bare)付きのリポジトリに develop/g1 ブランチを用意し(test-group-advance.ps1 の
    # Initialize-AdvanceProject と同じ)、MERGED の PR で develop/g2 に進める成功経路
    Push-Location $script:Proj
    try {
        git init -q --bare -b main .agents/remote.git 2>$null
        git remote add origin .agents/remote.git
        Set-Content a.txt 'a'; git add a.txt; git commit -q -m "init main"
        git push -q -u origin main 2>$null
        git checkout -q -b develop/g1 2>$null
        Set-Content b.txt 'b'; git add b.txt; git commit -q -m "feat: g1"
    } finally {
        Pop-Location
    }
    Set-Tasks $paTasks
    Set-State 'T1:done' 'T2:pending' 'T3:pending'
    Set-StateGroup P
    Set-StateBranch develop/g1
    Set-GhStubResult -Stdout '{"state":"MERGED","url":"https://example.com/pr/1"}'
    Assert-Eq 0 (Invoke-InProcess group-advance.ps1 @{ Branch = 'develop/g2' }) "LASTEXITCODE"
}

Invoke-TestCase "upstream-issue: 成功時に LASTEXITCODE=0" {
    # -DryRun を付けない検索でも、gh スタブが issue なし([])で成功すれば exit $LASTEXITCODE = 0
    Set-GhStubResult -Stdout '[]'
    Assert-Eq 0 (Invoke-InProcess upstream-issue.ps1 @{ Search = 'signal 241' }) "LASTEXITCODE"
}

Invoke-TestCase "workflow-sync-scripts: 成功時に LASTEXITCODE=0" {
    # このスクリプトはテンプレート側のコピー(.agents/skills/_templates/workflow/scripts/)から
    # 実行する仕様(.agents/workflow/scripts/ からの実行は exit 1)。全ファイルが同期済みの
    # 構成を用意し、Invoke-InProcess にテンプレート側の相対パスを渡す
    $tpl = "$script:Proj/.agents/skills/_templates/workflow"
    $null = New-Item -ItemType Directory -Force "$tpl/scripts"
    Copy-Item "$script:TemplateScripts/*" "$tpl/scripts/"
    Copy-Item "$script:RepoRoot/_templates/workflow/README.md" "$tpl/README.md"
    Copy-Item "$script:RepoRoot/_templates/workflow/README.md" "$script:Proj/.agents/workflow/README.md"
    Assert-Eq 0 (Invoke-InProcess '../../skills/_templates/workflow/scripts/workflow-sync-scripts.ps1') "LASTEXITCODE"
}

Show-Summary
