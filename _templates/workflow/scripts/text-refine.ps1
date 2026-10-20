# yomiyasu(文章推敲 skill)への依頼文を config.json の text_refine から機械生成する(推敲そのものは親が行う)。
# 引数: <target> <input> [-Check]
#       target は summary / confirm / commit / pr_body / task_done のいずれか
#       -Check は推敲済みファイルに対する yomiyasu の記録を探し、判断が要る候補を出す
# stdout: 推敲しないとき "Refine: off"、(skill 未設定なら導入検出の "Found: <場所>" と "Hint: ..."、)"Next: continue"。
#       推敲するとき "Refine: <skill>"、"Output: <出力パス>"、"Request: <依頼文>"、"Next: refine"
#       -Check のとき: 推敲しない/yomiyasu 以外なら "Refine: off"/"Refine: <skill>"+"Check: skipped"、"Next: continue"。
#       yomiyasu なら "Refine: <skill>"、"Output: <出力パス>"、"Record: <記録>"、"Candidates: N"、"Candidate: <キー> <抜粋>"...。
#       判断が全部あれば "Next: continue" と "Text:" 以降に推敲済みの本文、足りなければ "Undecided: <キー>" と "Next: decide-candidates"、
#       確かめられなければ "Unchecked: <理由>" と "Next: escalate reason=refine-unchecked"
# exit: 0=出力あり / 1=使い方・入力不備 / 2=-Check で判断待ちの候補あり / 3=-Check で確かめられない
param([string]$Target, [string]$InputPath, [switch]$Check)

$Usage = 'Usage: text-refine.ps1 <summary|confirm|commit|pr_body|task_done> <input> [-Check]'

if ($args.Count -gt 0 -or -not $PSBoundParameters.ContainsKey('Target') -or -not $PSBoundParameters.ContainsKey('InputPath')) {
    [Console]::Error.WriteLine($Usage)
    exit 1
}
if (@('summary', 'confirm', 'commit', 'pr_body', 'task_done') -cnotcontains $Target) {
    [Console]::Error.WriteLine($Usage)
    exit 1
}

Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = (Get-Location).Path
$ConfigPath = "$Root/.agents/workflow/config.json"
$HomeDir = if ($env:HOME) { $env:HOME } else { $HOME }

$DefaultTargets = @('summary', 'confirm', 'commit', 'pr_body', 'task_done')
$Readers = @{
    'expert'   = '同じ分野の専門家'
    'informed' = '分野は違うが技術に詳しい人'
    'general'  = '専門知識のない人'
}
$Kinds = @{
    'summary'   = 'ワークフローの完了をユーザーに伝える報告です'
    'task_done' = 'タスク1件の完了をユーザーに伝える報告です'
    'confirm'   = 'ユーザーに判断を求める確認の依頼です'
    'commit'    = 'コミットメッセージの説明の1行です'
    'pr_body'   = 'PR説明です'
}
$KeepBase = 'コマンド・パス・タスクID・コミットハッシュ・URL・括弧書きの補足'
$ThreeParts = '、「状況・起きたこと・次にすること」の3つのまとまりとその順番'
$KeepExtra = @{
    'summary'   = $ThreeParts
    'task_done' = $ThreeParts
    'confirm'   = $ThreeParts
    'commit'    = '、1行のまま改行しないこと'
    'pr_body'   = '、見出しと節の順番、要件一覧とテスト計画の項目'
}

function Read-JsonFile([string]$Path) {
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

# 設定の読み込み(ファイル・キーが無い・読めなければ skill=null 扱い)
$cfg = $null
$loaded = Read-JsonFile $ConfigPath
if ($loaded -is [System.Management.Automation.PSCustomObject] -and
    $loaded.text_refine -is [System.Management.Automation.PSCustomObject]) {
    $cfg = $loaded.text_refine
}

$skill = if ($cfg) { $cfg.skill } else { $null }
$targets = if ($cfg -and $cfg.targets -is [array]) { @($cfg.targets) } else { $DefaultTargets }
$reader = if ($cfg) { $cfg.reader } else { $null }
if (-not ($reader -is [string] -and (@('expert', 'informed', 'general') -ccontains $reader))) { $reader = 'informed' }

$skillSet = ($skill -is [string]) -and ($skill.Trim() -ne '')

function Get-DirNames([string]$Path) {
    $names = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return $names
}

function Test-Yomiyasu([string]$SkillMd) {
    if (-not (Test-Path -LiteralPath $SkillMd -PathType Leaf)) { return $false }
    try {
        $text = [System.IO.File]::ReadAllText($SkillMd, [System.Text.Encoding]::UTF8)
    } catch {
        return $false
    }
    $lines = @($text -split "\r\n|\n|\r")
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return $false }
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line.Trim() -eq '---') { break }
        if ($line -cmatch '^name:\s*["'']?yomiyasu["'']?\s*$') { return $true }
    }
    return $false
}

function Find-Yomiyasu {
    $found = New-Object System.Collections.Generic.List[string]

    $check = {
        param([string]$BaseDir, [string]$LabelPrefix, [string]$Rel)
        if (Test-Yomiyasu "$BaseDir/skills/yomiyasu/SKILL.md") {
            $sep = if ($Rel) { '/' } else { '' }
            $label = "$LabelPrefix$Rel${sep}skills/yomiyasu/SKILL.md"
            if (-not $found.Contains($label)) { $found.Add($label) }
        }
    }

    # プロジェクト
    & $check $Root '' ''
    foreach ($d1 in (Get-DirNames $Root)) {
        if ($d1 -ceq '.git' -or $d1 -ceq 'node_modules') { continue }
        $d1Path = "$Root/$d1"
        & $check $d1Path '' $d1
        if ($d1.StartsWith('.')) {
            foreach ($d2 in (Get-DirNames $d1Path)) {
                & $check "$d1Path/$d2" '' "$d1/$d2"
            }
        }
    }

    # ホーム
    foreach ($d1 in (Get-DirNames $HomeDir)) {
        if (-not $d1.StartsWith('.')) { continue }
        $d1Path = "$HomeDir/$d1"
        & $check $d1Path '~/' $d1
        foreach ($d2 in (Get-DirNames $d1Path)) {
            $d2Path = "$d1Path/$d2"
            & $check $d2Path '~/' "$d1/$d2"
            foreach ($d3 in (Get-DirNames $d2Path)) {
                & $check "$d2Path/$d3" '~/' "$d1/$d2/$d3"
            }
        }
    }

    # Claude Code のプラグイン
    $pluginsJson = Read-JsonFile "$HomeDir/.claude/plugins/installed_plugins.json"
    if ($pluginsJson -is [System.Management.Automation.PSCustomObject] -and
        $pluginsJson.plugins -is [System.Management.Automation.PSCustomObject]) {
        foreach ($key in @($pluginsJson.plugins.PSObject.Properties.Name)) {
            if ($key.StartsWith('yomiyasu@', [StringComparison]::Ordinal)) {
                $label = "~/.claude/plugins/installed_plugins.json ($key)"
                if (-not $found.Contains($label)) { $found.Add($label) }
            }
        }
    }
    return @($found)
}

if (-not $skillSet -or ($targets -cnotcontains $Target)) {
    Write-Output 'Refine: off'
    if (-not $skillSet -and -not $Check) {
        $foundList = @(Find-Yomiyasu)
        foreach ($place in $foundList) { Write-Output "Found: $place" }
        if ($foundList.Count -gt 0) {
            Write-Output 'Hint: yomiyasu is installed but text_refine.skill is not set'
        }
    }
    Write-Output 'Next: continue'
    exit 0
}

# 拡張子の手前に .refined / .decisions を入れる(os.path.splitext と同じ規則: 先頭のドットだけの名前は拡張子なし)
$sepIdx = [Math]::Max($InputPath.LastIndexOf('/'), $InputPath.LastIndexOf('\'))
$fileName = $InputPath.Substring($sepIdx + 1)
$dotIdx = $fileName.LastIndexOf('.')
if ($dotIdx -gt 0 -and $fileName.Substring(0, $dotIdx).Trim('.') -ne '') {
    $splitAt = $sepIdx + 1 + $dotIdx
} else {
    $splitAt = $InputPath.Length
}
$OutputPath = $InputPath.Substring(0, $splitAt) + '.refined' + $InputPath.Substring($splitAt)
$DecisionsPath = $InputPath.Substring(0, $splitAt) + '.decisions' + $InputPath.Substring($splitAt)

function Exit-Unchecked([string]$Reason) {
    Write-Output "Unchecked: $Reason"
    Write-Output 'Next: escalate reason=refine-unchecked'
    exit 3
}

function Test-Int($v) { return (($v -is [int]) -or ($v -is [long])) }

function Get-Prop($Obj, [string]$Name) {
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $p = $Obj.PSObject.Properties[$Name]
        if ($p) { return , $p.Value }
    }
    return , $null
}

function Get-Excerpt($s) {
    $t = if ($s -is [string]) { $s } else { '' }
    $t = ($t -replace '\s+', ' ').Trim()
    $runes = @($t.EnumerateRunes())
    if ($runes.Count -ge 41) {
        return (-join ($runes[0..39] | ForEach-Object { $_.ToString() })) + '…'
    }
    return $t
}

function Test-Truthy($v) { return ($null -ne $v -and "$v" -ne '') }

# checks から name が一致し status が ran のものの report を読む。無ければ $null、読めなければ @{ Data = $null }
function Find-Report($Rec, [string]$Name) {
    $checks = Get-Prop $Rec 'checks'
    if (-not ($checks -is [array])) { return $null }
    foreach ($c in $checks) {
        if ($c -is [System.Management.Automation.PSCustomObject] -and
            (Get-Prop $c 'name') -ceq $Name -and (Get-Prop $c 'status') -ceq 'ran') {
            $rp = Get-Prop $c 'report'
            if (-not ($rp -is [string])) { return @{ Data = $null } }
            $data = Read-JsonFile (Join-Path $StateDir $rp)
            if ($data -is [System.Management.Automation.PSCustomObject]) { return @{ Data = $data } }
            return @{ Data = $null }
        }
    }
    return $null
}

function Invoke-Check {
    if (@('yomiyasu', 'yomiyasu:yomiyasu') -cnotcontains $skill.Trim()) {
        Write-Output "Refine: $skill"
        Write-Output 'Check: skipped'
        Write-Output 'Next: continue'
        exit 0
    }
    Write-Output "Refine: $skill"
    Write-Output "Output: $OutputPath"
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Exit-Unchecked 'output not found' }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash.ToLowerInvariant()

    $best = $null
    $bestFile = $null
    $bestCreated = $null
    $bestAttempt = 0
    $recFiles = @(Get-ChildItem -Path "$StateDir/runs/*/attempt-*.json" -File -ErrorAction SilentlyContinue)
    foreach ($file in $recFiles) {
        $rec = Read-JsonFile $file.FullName
        if ((Get-Prop $rec 'format') -cne 'yomiyasu-check-record') { continue }
        $final = Get-Prop (Get-Prop $rec 'inputs') 'final'
        if ((Get-Prop $final 'sha256') -cne $hash) { continue }
        $created = Get-Prop $rec 'created_at'
        $attempt = Get-Prop $rec 'attempt'
        if ($created -is [datetime]) { $created = $created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        if (-not ($created -is [string]) -or -not (Test-Int $attempt)) { continue }
        $newer = $false
        if ($null -eq $best) {
            $newer = $true
        } else {
            $cmp = [string]::CompareOrdinal($created, $bestCreated)
            $newer = ($cmp -gt 0) -or ($cmp -eq 0 -and $attempt -gt $bestAttempt)
        }
        if ($newer) {
            $best = $rec; $bestFile = $file; $bestCreated = $created; $bestAttempt = $attempt
        }
    }
    if ($null -eq $best) { Exit-Unchecked ('no record for sha256:' + $hash.Substring(0, 12)) }
    Write-Output ('Record: runs/' + $bestFile.Directory.Name + '/' + $bestFile.Name)

    $lint = Find-Report $best 'lint'
    if ($null -eq $lint -or $null -eq $lint.Data -or -not ((Get-Prop $lint.Data 'findings') -is [array])) {
        Exit-Unchecked 'lint report missing'
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($fd in (Get-Prop $lint.Data 'findings')) {
        if (-not ($fd -is [System.Management.Automation.PSCustomObject])) { continue }
        $line = Get-Prop $fd 'line'
        $lineText = if (Test-Int $line) { "$line" } else { '-' }
        $rule = Get-Prop $fd 'rule'
        $ruleText = if ($null -eq $rule) { 'None' } else { "$rule" }
        $candidates.Add(@{ Key = "L$lineText $ruleText"; Excerpt = (Get-Excerpt (Get-Prop $fd 'snippet')) })
    }
    $diff = Find-Report $best 'diff'
    if ($null -ne $diff -and $null -eq $diff.Data) { Exit-Unchecked 'diff report missing' }
    if ($null -ne $diff) {
        $risks = Get-Prop $diff.Data 'meaning_risks'
        if ($risks -is [array]) {
            foreach ($r in $risks) {
                if (-not ($r -is [System.Management.Automation.PSCustomObject])) { continue }
                $line = Get-Prop $r 'new_line'
                if (-not (Test-Int $line)) { $line = Get-Prop $r 'old_line' }
                $lineText = if (Test-Int $line) { "$line" } else { '-' }
                $sub = Get-Prop $r 'subkind'
                if (-not (Test-Truthy $sub)) { $sub = Get-Prop $r 'kind' }
                $subText = if ($null -eq $sub) { 'None' } else { "$sub" }
                $text = Get-Prop $r 'new'
                if (-not (Test-Truthy $text)) { $text = Get-Prop $r 'old' }
                $candidates.Add(@{ Key = "L$lineText meaning_risk:$subText"; Excerpt = (Get-Excerpt $text) })
            }
        }
    }
    Write-Output "Candidates: $($candidates.Count)"
    foreach ($c in $candidates) { Write-Output ("Candidate: $($c.Key) $($c.Excerpt)") }
    if ($candidates.Count -gt 0) {
        Write-Output "Decisions: $DecisionsPath"
        $decided = ''
        try { $decided = [System.IO.File]::ReadAllText($DecisionsPath, [System.Text.Encoding]::UTF8) } catch { $decided = '' }
        $undecided = @($candidates | Where-Object { -not $decided.Contains($_.Key) })
        foreach ($u in $undecided) { Write-Output "Undecided: $($u.Key)" }
        if ($undecided.Count -gt 0) {
            Write-Output 'Next: decide-candidates'
            exit 2
        }
    }
    Write-Output 'Next: continue'
    Write-Output 'Text:'
    $body = [System.IO.File]::ReadAllText($OutputPath, [System.Text.Encoding]::UTF8)
    Write-Output $body.TrimEnd([char[]]@("`r", "`n"))
    exit 0
}

$StateDir = if ($env:YOMIYASU_STATE_DIR) { $env:YOMIYASU_STATE_DIR } else { "$Root/.yomiyasu" }

if ($Check) { Invoke-Check }

if (-not $InputPath -or -not (Test-Path -LiteralPath $InputPath)) {
    [Console]::Error.WriteLine("not found: $InputPath")
    exit 1
}

foreach ($stale in @($OutputPath, $DecisionsPath)) {
    if (Test-Path -LiteralPath $stale) {
        Remove-Item -LiteralPath $stale -Force
    }
}

$keep = $KeepBase + $KeepExtra[$Target]
$request = "$InputPath を $skill で推敲し、本文だけを $OutputPath に書いてください。$($Kinds[$Target])。読者は$($Readers[$reader])です。" +
    "質問はせず、意味・条件・数値を変えないでください。次のものは変えないでください: $keep。"

Write-Output "Refine: $skill"
Write-Output "Output: $OutputPath"
Write-Output "Request: $request"
Write-Output 'Next: refine'
exit 0
