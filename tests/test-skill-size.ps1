# skill-size.ps1 が壊れた references の参照とサイズ超過で失敗し、正しい参照では成功すること。
# ダミーの skill を一時ディレクトリに作り、-Root で検査対象を切り替えて確かめる。
. "$PSScriptRoot/lib.ps1"

# $script:Proj の下にダミー skill を作る。$Skill は agent-x/SKILL.md の本文
function New-DummySkill {
    param([string]$Skill)
    $dir = Join-Path $script:Proj 'agent-x'
    New-Item -ItemType Directory -Path (Join-Path $dir 'references') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), $Skill)
    [System.IO.File]::WriteAllText((Join-Path $dir 'references/ok.md'), "# ok`n")
}

# skill-size.ps1 を -Root 付きで実行し、出力と exit code を返す
function Invoke-SkillSize {
    param([string[]]$Extra = @())
    $out = & pwsh -NoProfile -File "$PSScriptRoot/skill-size.ps1" -Root $script:Proj @Extra 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

Write-Host "test-skill-size.ps1"

Invoke-TestCase "正しい参照だけなら成功する" {
    New-DummySkill "# x`n`n詳細は ``references/ok.md`` と [x](references/ok.md#a) を読む。`n"
    $r = Invoke-SkillSize
    Assert-Eq 0 $r.Code "exit code"
    Assert-Contains $r.Out 'SKILL SIZE OK' "OK を出す"
}

Invoke-TestCase "バッククォートの壊れた参照で失敗する" {
    New-DummySkill "# x`n`n詳細は ``references/no-such.md`` を読む。`n"
    $r = Invoke-SkillSize
    Assert-Eq 1 $r.Code "exit code"
    Assert-Contains $r.Out 'FAIL: broken reference agent-x/SKILL.md -> agent-x/references/no-such.md' "壊れた参照を報告する"
}

Invoke-TestCase "Markdown リンクの壊れた参照で失敗する" {
    New-DummySkill "# x`n`n詳細は [x](../agent-y/references/no-such.md#a) を読む。`n"
    $r = Invoke-SkillSize
    Assert-Eq 1 $r.Code "exit code"
    $line = @($r.Out -split "`r?`n" | Where-Object { $_ -like 'FAIL: broken reference*' }) -join "`n"
    Assert-Contains $line 'agent-y/references/no-such.md' "壊れたリンク先を報告する"
}

Invoke-TestCase "FileLimit を超えると失敗する" {
    New-DummySkill "# x`n`n詳細は ``references/ok.md`` を読む。`n"
    $r = Invoke-SkillSize @('-FileLimit', '10')
    Assert-Eq 1 $r.Code "exit code"
    Assert-Contains $r.Out 'FAIL: agent-x/SKILL.md' "サイズ超過を報告する"
}

Invoke-TestCase "frontmatter の description に ': ' があり引用符が無いと失敗する" {
    New-DummySkill "---`nname: agent-x`ndescription: 例: x`n---`n`n# x`n"
    $r = Invoke-SkillSize
    Assert-Eq 1 $r.Code "exit code"
    Assert-Contains $r.Out 'FAIL: frontmatter description of agent-x/SKILL.md must be quoted' "引用符の欠落を報告する"
}

Invoke-TestCase "frontmatter の description を二重引用符で囲めば成功する" {
    New-DummySkill "---`nname: agent-x`ndescription: `"例: x`"`n---`n`n# x`n"
    $r = Invoke-SkillSize
    Assert-Eq 0 $r.Code "exit code"
    Assert-Contains $r.Out 'SKILL SIZE OK' "OK を出す"
}

Show-Summary
