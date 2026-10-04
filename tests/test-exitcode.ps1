# PowerShell セッション内で `& script.ps1` と直接呼んだときにも、成功時に $LASTEXITCODE が 0 になること。
# (exit を呼ばずに終わるスクリプトは $LASTEXITCODE を更新しないため、直前の値や空のまま残る)
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

Show-Summary
