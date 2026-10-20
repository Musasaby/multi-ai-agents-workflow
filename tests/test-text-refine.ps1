# text-refine(推敲の依頼文の生成, PowerShell版)
. "$PSScriptRoot/lib.ps1"
$env:YOMIYASU_STATE_DIR = $null

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

# yomiyasu の記録を書く: Write-Record <run> <created_at> <final_file> <findings> <meaning_risks>
function Write-Record {
    param([string]$Run, [string]$Created, [string]$Final, $Findings, $Risks)
    $dir = "$script:Proj/.yomiyasu/runs/$Run"
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Final).Hash.ToLowerInvariant()
    $rec = [ordered]@{
        format     = 'yomiyasu-check-record'
        run_id     = $Run
        attempt    = 1
        created_at = $Created
        inputs     = [ordered]@{ final = [ordered]@{ sha256 = $hash } }
        checks     = @(
            [ordered]@{ name = 'lint'; status = 'ran'; report = "runs/$Run/attempt-1.lint.json" },
            [ordered]@{ name = 'diff'; status = 'ran'; report = "runs/$Run/attempt-1.diff.json" }
        )
    }
    Write-Utf8File "$dir/attempt-1.json" ($rec | ConvertTo-Json -Depth 10)
    Write-Utf8File "$dir/attempt-1.lint.json" ([ordered]@{ findings = @($Findings) } | ConvertTo-Json -Depth 10)
    Write-Utf8File "$dir/attempt-1.diff.json" ([ordered]@{ meaning_risks = @($Risks) } | ConvertTo-Json -Depth 10)
}

# -Check 用の入力と推敲済みファイルを置く
function Initialize-Check {
    New-TestHome
    Set-Refine 'yomiyasu'
    $script:Refined = '.agents/workflow/runs/refine/pr_body.refined.md'
    $script:InputF = '.agents/workflow/runs/refine/pr_body.md'
    $script:Decisions = "$script:Proj/.agents/workflow/runs/refine/pr_body.decisions.md"
    Write-Utf8File "$script:Proj/$script:InputF" "元`n"
    Write-Utf8File "$script:Proj/$script:Refined" "推敲済みの本文`n2行目`n"
}

$Lint1 = @([ordered]@{ rule = 'excess_list'; line = 1; snippet = '- 項目' })
$Risk1 = @([ordered]@{ kind = 'protected'; subkind = 'inline_code'; new_line = 4; new = '`code`' })

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
        Write-Utf8File "$script:Proj/.agents/workflow/runs/refine/pr_body.decisions.md" "古い判断`n"
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
        Assert-FileAbsent "$script:Proj/.agents/workflow/runs/refine/pr_body.decisions.md" "前の判断を消す"
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

Invoke-TestCase "text-refine: チェックは推敲しないときと yomiyasu 以外のとき確かめずに続ける" {
    New-TestHome
    try {
        Set-Refine $null
        Invoke-Script text-refine.ps1 pr_body x.md -Check
        Assert-Eq 0 $script:Code "exit: $($script:Err)"
        Assert-Contains $script:Out "Refine: off" "推敲しない"
        Assert-Contains $script:Out "Next: continue" "続行"
        Set-Refine 'other'
        Invoke-Script text-refine.ps1 pr_body x.md -Check
        Assert-Eq 0 $script:Code "exit: $($script:Err)"
        Assert-Contains $script:Out "Check: skipped" "確かめない"
        Assert-Contains $script:Out "Next: continue" "続行"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: チェックは記録が無いか最終稿のハッシュが合わなければ止める" {
    Initialize-Check
    try {
        Remove-Item "$script:Proj/$script:Refined"
        Invoke-Script text-refine.ps1 pr_body $script:InputF -Check
        Assert-Eq 3 $script:Code "exit 3"
        Assert-Contains $script:Out "Unchecked: output not found" "推敲済みが無い"
        Write-Utf8File "$script:Proj/$script:Refined" "推敲済みの本文`n2行目`n"
        Write-Utf8File "$script:Proj/other.md" "別の内容`n"
        Write-Record r1 '2026-01-01T00:00:00Z' "$script:Proj/other.md" @() @()
        Invoke-Script text-refine.ps1 pr_body $script:InputF -Check
        Assert-Eq 3 $script:Code "exit 3"
        Assert-Contains $script:Out "Unchecked: no record for sha256:" "ハッシュが合わない"
        Assert-Contains $script:Out "Next: escalate reason=refine-unchecked" "エスカレーション"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: チェックは候補の判断が無ければ判断を求める" {
    Initialize-Check
    try {
        Write-Record r1 '2026-01-01T00:00:00Z' "$script:Proj/$script:Refined" $Lint1 $Risk1
        Invoke-Script text-refine.ps1 pr_body $script:InputF -Check
        Assert-Eq 2 $script:Code "exit 2: $($script:Err)"
        Assert-Contains $script:Out "Candidates: 2" "候補数"
        Assert-Contains $script:Out "Candidate: L1 excess_list " "lint の候補"
        Assert-Contains $script:Out "Candidate: L4 meaning_risk:inline_code " "意味の候補"
        Assert-Contains $script:Out "Undecided: L1 excess_list" "未判断"
        Assert-Contains $script:Out "Next: decide-candidates" "判断を求める"
        Write-Utf8File $script:Decisions "L1 excess_list: 残す`n"
        Invoke-Script text-refine.ps1 pr_body $script:InputF -Check
        Assert-Eq 2 $script:Code "exit 2: $($script:Err)"
        Assert-NotContains $script:Out "Undecided: L1 excess_list" "判断済みは出さない"
        Assert-Contains $script:Out "Undecided: L4 meaning_risk:inline_code" "残りの未判断"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: チェックは全候補の判断があれば本文を出して続ける" {
    Initialize-Check
    try {
        Write-Record r1 '2026-01-01T00:00:00Z' "$script:Proj/$script:Refined" $Lint1 $Risk1
        Write-Utf8File $script:Decisions "L1 excess_list`nL4 meaning_risk:inline_code`n"
        Invoke-Script text-refine.ps1 pr_body $script:InputF -Check
        Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
        Assert-Contains $script:Out "Next: continue" "続行"
        Assert-Contains $script:Out "Text:`n推敲済みの本文`n2行目" "本文を出す"
    } finally { Remove-TestHome }
}

Invoke-TestCase "text-refine: チェックは同じ最終稿の最新の記録を使う" {
    Initialize-Check
    try {
        Write-Record old '2026-01-01T00:00:00Z' "$script:Proj/$script:Refined" $Lint1 @()
        Write-Record new '2026-02-01T00:00:00Z' "$script:Proj/$script:Refined" @() @()
        Invoke-Script text-refine.ps1 pr_body $script:InputF -Check
        Assert-Eq 0 $script:Code "exit 0: $($script:Err)"
        Assert-Contains $script:Out "Record: runs/new/attempt-1.json" "新しい記録"
        Assert-Contains $script:Out "Candidates: 0" "候補なし"
        Assert-Contains $script:Out "Next: continue" "続行"
    } finally { Remove-TestHome }
}

Show-Summary
