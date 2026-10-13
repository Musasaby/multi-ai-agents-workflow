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
                $current = [pscustomobject]@{ id = $Matches[1]; title = $Matches[2].Trim(); depRaw = $null; depLine = -1; group = $currentGroup; groupRaw = $null }
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
