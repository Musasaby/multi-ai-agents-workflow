# tasks.md の解析と依存欄の検証(PowerShell版スクリプト共通)。
# state-sync.ps1 / next-task.ps1 / dispatch-prompt-gen.ps1 から dot-source して使う。
# 依存欄の厳密フォーマット: `- **依存**: なし` または `- **依存**: T1, T2`

$script:DepLinePattern = '^(\s*-\s+\*\*依存\*\*:)[ \t]*(.*?)[ \t]*$'
$script:DepFormatHint = "expected 'なし' or comma-separated task IDs like 'T1, T2'"

# 改行コードを保持したまま行に分割する(CRLF の tasks.md をそのまま書き戻すため)
function Split-TaskLines {
    param([string]$Content)
    return [regex]::Split($Content, '(?<=\n)') | Where-Object { $_ -ne '' }
}

function Get-LineBody {
    param([string]$Line)
    return $Line.TrimEnd("`r", "`n")
}

# tasks.md を解析し、出現順のタスク一覧(id / title / depRaw / depLine)を返す
function Read-TaskList {
    param([string[]]$Lines)
    $tasks = [ordered]@{}
    $current = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = (Get-LineBody $Lines[$i]).TrimStart([char]0xFEFF)
        if ($line.StartsWith('## ')) {
            if ($line -cmatch '^## (T\d+):\s*(.+)') {
                $current = [pscustomobject]@{ id = $Matches[1]; title = $Matches[2].Trim(); depRaw = $null; depLine = -1 }
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
    }
    return @($tasks.Values)
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
