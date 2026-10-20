# text-refine(推敲の依頼文の生成, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# テスト用 HOME を作り $env:HOME に設定する(実際のホームの導入状況に左右されないようにする)
function New-TestHome {
    $script:SavedHome = $env:HOME
    $script:TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ("wf-home-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force $script:TestHome
    $env:HOME = $script:TestHome
}

function Remove-TestHome {
    $env:HOME = $script:SavedHome
    if ($script:TestHome) { Remove-Item -Recurse -Force $script:TestHome -ErrorAction SilentlyContinue }
    $script:TestHome = $null
}

# config.json の text_refine を書き換える: Set-Refine $null|'skill' [string[]]targets
function Set-Refine {
    param($Skill, $Targets = $null)
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg.text_refine.skill = $Skill
    if ($null -ne $Targets) { $cfg.text_refine.targets = @($Targets) }
    Write-Utf8File $path ($cfg | ConvertTo-Json -Depth 10)
}

function Write-SkillMd {
    param([string]$Path, [string]$Name)
    Write-Utf8File $Path "---`nname: $Name`n---`n"
}

Write-Host "test-text-refine.ps1"

Invoke-TestCase "text-refine: skill が null なら Refine: off と Next: continue" {
    New-TestHome
    try {
        Set-Refine $null
        Invoke-Script text-refine.ps1 pr_body x.md
        Assert-Eq 0 $script:Code "exit: $($script:Err)"
        Assert-Contains $script:Out "Refine: off" "推敲しない"
        Assert-Contains $script:Out "Next: continue" "続行"
        Assert-NotContains $script:Out "Hint:" "導入が無ければ Hint を出さない"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: 未設定ならエージェントを問わず導入を見つけて知らせる" {
    New-TestHome
    try {
        Set-Refine $null
        Write-SkillMd "$script:Proj/.claude/skills/yomiyasu/SKILL.md" 'yomiyasu'
        Write-SkillMd "$script:TestHome/.config/opencode/skills/yomiyasu/SKILL.md" 'yomiyasu'
        Write-SkillMd "$script:TestHome/.gemini/skills/yomiyasu/SKILL.md" 'yomiyasu'
        Write-SkillMd "$script:Proj/.cursor/skills/yomiyasu/SKILL.md" 'other'
        Write-Utf8File "$script:TestHome/.claude/plugins/installed_plugins.json" '{"version":2,"plugins":{"yomiyasu@yomiyasu":[]}}'
        Invoke-Script text-refine.ps1 pr_body x.md
        Assert-Eq 0 $script:Code "exit: $($script:Err)"
        Assert-Contains $script:Out "Found: .claude/skills/yomiyasu/SKILL.md" "プロジェクトの .claude"
        Assert-Contains $script:Out "Found: ~/.config/opencode/skills/yomiyasu/SKILL.md" "ホームの opencode"
        Assert-Contains $script:Out "Found: ~/.gemini/skills/yomiyasu/SKILL.md" "ホームの gemini"
        Assert-Contains $script:Out "Found: ~/.claude/plugins/installed_plugins.json (yomiyasu@yomiyasu)" "プラグイン"
        Assert-Contains $script:Out "Hint: yomiyasu is installed but text_refine.skill is not set" "Hint"
        Assert-NotContains $script:Out ".cursor/" "別名の skill は対象外"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: 有効なら依頼文と出力パスを出す" {
    New-TestHome
    try {
        Set-Refine 'yomiyasu:yomiyasu'
        Write-Utf8File "$script:Proj/.agents/workflow/runs/refine/pr_body.md" "本文`n"
        Write-Utf8File "$script:Proj/.agents/workflow/runs/refine/pr_body.refined.md" "古い出力`n"
        Invoke-Script text-refine.ps1 pr_body .agents/workflow/runs/refine/pr_body.md
        Assert-Eq 0 $script:Code "exit: $($script:Err)"
        Assert-Contains $script:Out "Refine: yomiyasu:yomiyasu" "skill 名"
        Assert-Contains $script:Out "Output: .agents/workflow/runs/refine/pr_body.refined.md" "出力パス"
        Assert-Contains $script:Out "を yomiyasu:yomiyasu で推敲し、本文だけを" "依頼文"
        Assert-Contains $script:Out "PR説明です" "場面"
        Assert-Contains $script:Out "読者は分野は違うが技術に詳しい人です" "読者"
        Assert-Contains $script:Out "要件一覧とテスト計画の項目" "変えない物"
        Assert-Contains $script:Out "Next: refine" "次の操作"
        Assert-FileAbsent "$script:Proj/.agents/workflow/runs/refine/pr_body.refined.md" "前の出力を消す"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: targets に無い場面は推敲しない" {
    New-TestHome
    try {
        Set-Refine 'yomiyasu' @('pr_body')
        Invoke-Script text-refine.ps1 commit x.md
        Assert-Eq 0 $script:Code "exit: $($script:Err)"
        Assert-Contains $script:Out "Refine: off" "推敲しない"
        Assert-Contains $script:Out "Next: continue" "続行"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: 有効で入力が無ければ exit 1" {
    New-TestHome
    try {
        Set-Refine 'yomiyasu'
        Invoke-Script text-refine.ps1 pr_body no-such-input.md
        Assert-Eq 1 $script:Code "exit 1"
        Assert-Contains $script:Err "not found:" "入力なし"
    } finally { Remove-TestHome }
}

Show-Summary
