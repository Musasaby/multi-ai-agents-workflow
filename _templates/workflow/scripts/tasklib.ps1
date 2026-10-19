# tasks.md の解析と依存欄・グループの検証(PowerShell版スクリプト共通)。
# state-sync.ps1 / next-task.ps1 / dispatch-prompt-gen.ps1 から dot-source して使う。
# 依存欄の厳密フォーマット: `- **依存**: なし` または `- **依存**: T1, T2`
# グループ区切り行の厳密フォーマット: `<!-- グループ <名前> -->` または
# `<!-- グループ <名前>: <説明> -->`(<名前> は空白と ':' を含まない文字列)

$script:DepLinePattern = '^(\s*-\s+\*\*依存\*\*:)[ \t]*(.*?)[ \t]*$'
$script:DepFormatHint = "expected 'なし' or comma-separated task IDs like 'T1, T2'"
$script:GroupLinePattern = '^<!--\s*グループ\s+([^\s:]+)(?:\s*:\s*(.*?))?\s*-->\s*$'
$script:GroupFieldPattern = '^(\s*-\s+\*\*グループ\*\*:)[ \t]*(.*?)[ \t]*$'
$script:DefaultGroup = ''
$script:ReqSection = '## 要件'
$script:ReqLinePattern = '^- (R\d+):[ \t]*(\S.*?)[ \t]*$'
$script:ReqFieldPattern = '^(\s*-\s+\*\*要件\*\*:)[ \t]*(.*?)[ \t]*$'
$script:ReqFormatHint = "expected 'なし' or comma-separated requirement IDs like 'R1, R2'"

# 改行コードを保持したまま行に分割する(CRLF の tasks.md をそのまま書き戻すため)
function Split-TaskLines {
    param([string]$Content)
    return [regex]::Split($Content, '(?<=\n)') | Where-Object { $_ -ne '' }
}

function Get-LineBody {
    param([string]$Line)
    return $Line.TrimEnd("`r", "`n")
}

# tasks.md を解析し、出現順のタスク一覧(id / title / depRaw / depLine / group / groupRaw)を返す
# group は所属グループ名: タスク見出しより前にある直近のグループ区切りの名前(区切りが
# 1つも無い、または最初の区切りより前のタスクは既定グループ = $script:DefaultGroup '')。
# groupRaw は欄 '- **グループ**: <名前>' の値(欄が無ければ $null)。欄があれば位置より
# 優先する(名前が tasks.md の区切りに存在する場合のみ。不一致の検証は Test-GroupDeps が行う)
function Read-TaskList {
    param([string[]]$Lines)
    $tasks = [ordered]@{}
    $current = $null
    $currentGroup = $script:DefaultGroup
    $declared = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = (Get-LineBody $Lines[$i]).TrimStart([char]0xFEFF)
        if ($line -cmatch $script:GroupLinePattern) {
            $currentGroup = $Matches[1]
            if (-not $declared.Contains($currentGroup)) { $declared.Add($currentGroup) }
            continue
        }
        if ($line.StartsWith('## ')) {
            if ($line -cmatch '^## (T\d+):\s*(.+)') {
                $current = [pscustomobject]@{ id = $Matches[1]; title = $Matches[2].Trim(); depRaw = $null; depLine = -1; group = $currentGroup; groupRaw = $null; reqRaw = $null }
                $tasks[$current.id] = $current
            } else {
                $current = $null
            }
            continue
        }
        if ($null -ne $current -and $null -eq $current.depRaw -and $line -match $script:DepLinePattern) {
            $current.depRaw = $Matches[2]
            $current.depLine = $i
        }
        if ($null -ne $current -and $null -eq $current.groupRaw -and $line -cmatch $script:GroupFieldPattern) {
            $current.groupRaw = $Matches[2]
        }
        if ($null -ne $current -and $null -eq $current.reqRaw -and $line -cmatch $script:ReqFieldPattern) {
            $current.reqRaw = $Matches[2]
        }
    }
    # グループ欄による上書き(欄の名前が区切りに存在する場合のみ)
    foreach ($t in $tasks.Values) {
        if ($null -ne $t.groupRaw -and $declared.Contains($t.groupRaw)) { $t.group = $t.groupRaw }
    }
    return @($tasks.Values)
}

# tasks.md 上に出現するグループの順序を返す。
# 戻り値は [既定グループ(''), 区切り名...] の配列(区切り名は最初に出現した順、重複なし)
function Get-GroupOrder {
    param([string[]]$Lines)
    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add($script:DefaultGroup)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = (Get-LineBody $Lines[$i]).TrimStart([char]0xFEFF)
        if ($line -cmatch $script:GroupLinePattern -and -not $names.Contains($Matches[1])) {
            $names.Add($Matches[1])
        }
    }
    return @($names)
}

# グループ欄と、依存先が後のグループに属する依存を検証する。エラーはまとめて例外にする。
# GroupOrder は Get-GroupOrder の戻り値(先頭が既定グループ '')。依存先が自分より後の
# グループに属する依存は、そのタスクが永久に実行できないため例外にする
function Test-GroupDeps {
    param($Tasks, [string[]]$GroupOrder)
    # グループ名は大文字小文字を区別する(POSIX 版と同じ。@{} は区別しないため Dictionary を使う)
    $idx = [System.Collections.Generic.Dictionary[string, int]]::new()
    for ($i = 0; $i -lt $GroupOrder.Count; $i++) {
        if (-not $idx.ContainsKey($GroupOrder[$i])) { $idx[$GroupOrder[$i]] = $i }
    }
    $groupOf = @{}
    foreach ($t in $Tasks) { $groupOf[$t.id] = $t.group }
    $errors = @()
    foreach ($t in $Tasks) {
        if ($null -ne $t.groupRaw) {
            if ($t.groupRaw -eq '') {
                $errors += "$($t.id): group field ('- **グループ**: ...') is empty"
                continue
            }
            if (-not $idx.ContainsKey($t.groupRaw)) {
                $errors += "$($t.id): unknown group '$($t.groupRaw)' (not declared by any '<!-- グループ <名前> -->' line in tasks.md)"
                continue
            }
        }
        try { $deps = @(Get-TaskDeps $t) } catch { continue }  # 依存欄の不備は Resolve-TaskDeps が報告する
        $myIdx = if ($idx.ContainsKey($t.group)) { $idx[$t.group] } else { 0 }
        foreach ($d in $deps) {
            if (-not $groupOf.ContainsKey($d)) { continue }  # 存在しない依存先は Resolve-TaskDeps が報告する
            $dIdx = if ($idx.ContainsKey($groupOf[$d])) { $idx[$groupOf[$d]] } else { 0 }
            if ($dIdx -gt $myIdx) {
                $errors += "Later-group dependency: $($t.id) (group '$($groupOf[$t.id])') depends on $d (group '$($groupOf[$d])'); a task must not depend on a task in a later group"
            }
        }
    }
    if ($errors.Count -gt 0) { throw ($errors -join "`n") }
}

# '## 要件' 節を解析し [pscustomobject]@{ hasSection; items(id / text) } を返す。
# 形式違反の行・重複ID・要件が0件の節は例外(エラーはすべて集める)
function Read-Requirements {
    param([string[]]$Lines)
    $hasSection = $false
    $inSection = $false
    $reqs = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.List[string]]::new()
    $errors = @()
    foreach ($raw in $Lines) {
        $line = (Get-LineBody $raw).TrimStart([char]0xFEFF).TrimEnd()
        if ($line.StartsWith('#')) {
            $inSection = ($line -ceq $script:ReqSection)
            if ($inSection) { $hasSection = $true }
            continue
        }
        if (-not $inSection) { continue }
        if ($line -cmatch $script:ReqLinePattern) {
            $rid = $Matches[1]
            if ($seen.Contains($rid)) {
                $errors += "Duplicate requirement ID: $rid"
            } else {
                $seen.Add($rid)
                $reqs.Add([pscustomobject]@{ id = $rid; text = $Matches[2] })
            }
        } elseif ($line.StartsWith('- ')) {
            $errors += "Malformed requirement line: '$line' (expected '- R<n>: <text>')"
        }
    }
    if ($hasSection -and $reqs.Count -eq 0 -and $errors.Count -eq 0) {
        $errors += "'## 要件' section has no requirements"
    }
    if ($errors.Count -gt 0) { throw ($errors -join "`n") }
    return [pscustomobject]@{ hasSection = $hasSection; items = @($reqs) }
}

# 要件節とタスクの要件欄を検証し、対応表(label / tasks を持つ要素の配列)を返す。
# ラベルは要件の記述順の 'R<n>'、最後に要件欄が 'なし' のタスクがあれば 'なし'。
# 節も欄も無ければ空。エラーはすべて集めて例外にする
function Test-Requirements {
    param($Tasks, [string[]]$Lines)
    $errors = @()
    $hasSection = $false
    $reqs = @()
    try {
        $parsed = Read-Requirements $Lines
        $hasSection = $parsed.hasSection
        $reqs = @($parsed.items)
    } catch {
        $errors += $_.Exception.Message
        $hasSection = $true
    }
    $ids = [System.Collections.Generic.List[string]]::new()
    $covered = [System.Collections.Generic.Dictionary[string, object]]::new()
    foreach ($r in $reqs) {
        $ids.Add($r.id)
        $covered[$r.id] = [System.Collections.Generic.List[string]]::new()
    }
    $noneTasks = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Tasks) {
        $tid = $t.id
        $raw = $t.reqRaw
        if (-not $hasSection) {
            if ($null -ne $raw) {
                $errors += "${tid}: requirement field is used but tasks.md has no '## 要件' section"
            }
            continue
        }
        if ($null -eq $raw) {
            $errors += "${tid}: requirement line ('- **要件**: ...') is missing"
            continue
        }
        if ($raw -ceq 'なし') {
            $noneTasks.Add($tid)
            continue
        }
        $refs = [System.Collections.Generic.List[string]]::new()
        foreach ($token in ($raw -split ',')) {
            $token = $token.Trim()
            if ($token -cnotmatch '^R\d+$') {
                $errors += "Invalid requirement in ${tid}: '$token' ($script:ReqFormatHint)"
            } elseif (-not $ids.Contains($token)) {
                if ($reqs.Count -gt 0) {
                    $errors += "${tid}: refers to unknown requirement '$token' (not found in '## 要件')"
                }
            } elseif (-not $refs.Contains($token)) {
                $refs.Add($token)
            }
        }
        foreach ($rid in $refs) { $covered[$rid].Add($tid) }
    }
    foreach ($rid in $ids) {
        if ($covered[$rid].Count -eq 0) {
            $errors += "Uncovered requirement: $rid (no task refers to it; assign it to a task or move it to '## 対象外')"
        }
    }
    if ($errors.Count -gt 0) { throw ($errors -join "`n") }
    $table = @()
    foreach ($rid in $ids) { $table += [pscustomobject]@{ label = $rid; tasks = @($covered[$rid]) } }
    if ($noneTasks.Count -gt 0) { $table += [pscustomobject]@{ label = 'なし'; tasks = @($noneTasks) } }
    return $table
}

# 要件ごとのタスクの状態行(文字列の配列)。節も欄も無ければ空配列。不正なら Test-Requirements の例外をそのまま上げる。
# $StateTasks は ConvertFrom-Json した state.json の .tasks
function Get-RequirementStatusLines {
    param($Tasks, [string[]]$Lines, $StateTasks)
    $table = @(Test-Requirements $Tasks $Lines)
    if ($table.Count -eq 0) { return @() }
    $texts = @{}
    foreach ($r in (Read-Requirements $Lines).items) { $texts[$r.id] = $r.text }
    $byId = @{}
    foreach ($s in @($StateTasks)) { $byId[$s.id] = $s }
    $label = {
        param($tid)
        $st = $byId[$tid]
        if ($null -eq $st) { return "$tid(missing)" }
        $status = if ($null -eq $st.status) { 'None' } else { [string]$st.status }
        if ($status -eq 'done' -and $st.commit) {
            $c = [string]$st.commit
            return "$tid(done $($c.Substring(0, [Math]::Min(7, $c.Length))))"
        }
        return "$tid($status)"
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $counts = @{ done = 0; partial = 0; pending = 0 }
    foreach ($row in $table) {
        $labels = (@($row.tasks) | ForEach-Object { & $label $_ }) -join ', '
        if ($row.label -ceq 'なし') {
            $out.Add("Requirement なし: $labels")
            continue
        }
        $nDone = 0
        foreach ($tid in $row.tasks) {
            if ($byId.ContainsKey($tid) -and $byId[$tid].status -eq 'done') { $nDone++ }
        }
        $state = if ($nDone -eq @($row.tasks).Count) { 'done' } elseif ($nDone -gt 0) { 'partial' } else { 'pending' }
        $counts[$state]++
        $out.Add("Requirement $($row.label) [$state]: $labels | $($texts[$row.label])")
    }
    $out.Add("Summary: done=$($counts.done) partial=$($counts.partial) pending=$($counts.pending)")
    return $out.ToArray()
}

# PR 本文用の要件一覧の行(文字列の配列)。PR のタスクを含む要件だけ、要件の記述順。該当なしなら空配列
function Get-PrRequirementLines {
    param($Tasks, [string[]]$Lines, [string[]]$PrTaskIds)
    $table = @(Test-Requirements $Tasks $Lines)
    if ($table.Count -eq 0) { return @() }
    $texts = @{}
    foreach ($r in (Read-Requirements $Lines).items) { $texts[$r.id] = $r.text }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $table) {
        if ($row.label -ceq 'なし') { continue }
        $mine = @($row.tasks | Where-Object { $PrTaskIds -contains $_ })
        if ($mine.Count -eq 0) { continue }
        $others = @($row.tasks | Where-Object { $PrTaskIds -notcontains $_ })
        $s = "- $($row.label): $($texts[$row.label])(この PR: $($mine -join ', ')"
        if ($others.Count -gt 0) { $s += " / 他の PR: $($others -join ', ')" }
        $out.Add($s + ')')
    }
    return $out.ToArray()
}

# 依存欄を検証してタスクIDの配列を返す。不正なら例外を投げる
function Get-TaskDeps {
    param($Task)
    $id = $Task.id
    if ($null -eq $Task.depRaw) { throw "${id}: dependency line ('- **依存**: ...') is missing" }
    if ($Task.depRaw -eq 'なし') { return @() }
    $deps = [System.Collections.Generic.List[string]]::new()
    foreach ($token in ($Task.depRaw -split ',')) {
        $token = $token.Trim()
        if ($token -cnotmatch '^T\d+$') {
            throw "Invalid dependency in ${id}: '$token' ($script:DepFormatHint; write notes in the 目的 field, not in 依存)"
        }
        if ($token -eq $id) { throw "${id}: depends on itself" }
        if (-not $deps.Contains($token)) { $deps.Add($token) }
    }
    return @($deps)
}

# 全タスクの依存欄を検証し、id → 依存配列 のハッシュを返す。エラーはまとめて例外にする
function Resolve-TaskDeps {
    param($Tasks, [switch]$CheckCycles)
    $ids = @{}
    foreach ($t in $Tasks) { $ids[$t.id] = $true }
    $graph = [ordered]@{}
    $errors = @()
    foreach ($t in $Tasks) {
        try {
            $deps = Get-TaskDeps $t
        } catch {
            $errors += $_.Exception.Message
            continue
        }
        foreach ($d in $deps) {
            if (-not $ids.ContainsKey($d)) { $errors += "$($t.id): depends on unknown task '$d' (not found in tasks.md)" }
        }
        $graph[$t.id] = $deps
    }
    if ($errors.Count -gt 0) { throw ($errors -join "`n") }
    if ($CheckCycles) {
        $cycle = Find-DepCycle $graph
        if ($cycle) { throw "Dependency cycle detected: $($cycle -join ' -> ')" }
    }
    return $graph
}

function Find-DepCycle {
    param($Graph)
    $color = @{}
    foreach ($k in $Graph.Keys) { $color[$k] = 0 }
    $stack = [System.Collections.Generic.List[string]]::new()
    $visit = $null
    $visit = {
        param($tid)
        $color[$tid] = 1
        $stack.Add($tid)
        foreach ($d in $Graph[$tid]) {
            if ($color[$d] -eq 1) {
                $start = $stack.IndexOf($d)
                return @($stack.GetRange($start, $stack.Count - $start)) + $d
            }
            if ($color[$d] -eq 0) {
                $found = & $visit $d
                if ($found) { return $found }
            }
        }
        $stack.RemoveAt($stack.Count - 1)
        $color[$tid] = 2
        return $null
    }
    foreach ($k in @($Graph.Keys)) {
        if ($color[$k] -eq 0) {
            $found = & $visit $k
            if ($found) { return $found }
        }
    }
    return $null
}

function Format-TaskDeps {
    param([string[]]$Deps)
    if ($Deps.Count -eq 0) { return 'なし' }
    return ($Deps -join ', ')
}

# Lines 上の Task の依存行を Deps で書き換える(行頭インデント・改行コードは保持)。
# Lines は呼び出し元の配列をその場で書き換えるため、型指定しない(型変換でコピーされるのを防ぐ)
function Set-TaskDepLine {
    param($Lines, $Task, [string[]]$Deps)
    $i = $Task.depLine
    $raw = $Lines[$i]
    $body = Get-LineBody $raw
    $eol = $raw.Substring($body.Length)
    [void]($body -match $script:DepLinePattern)
    $Lines[$i] = "$($Matches[1]) $(Format-TaskDeps $Deps)$eol"
}
