# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# exit(複数に当たる場合は上にあるものを優先する):
#   8=管理ファイルの改ざん(prompt.md・state.json・tasks.md・config.json が dispatch-run の起動時から
#     変わった/消えた、guard.sha256・output.log・git-state.txt が無い、output.log が実行中に
#     切り詰められた、本物のリポジトリの git 状態(HEAD・ブランチ・参照・設定)が変わった)
#   4=異常終了(非0・signal・crashed)
#   6=権限拒否で中断(output.log に子CLIの権限拒否の記録がある)
#   5=完了報告が無い・無効(最後の `## 完了報告` の後にツール実行の記録が続く、必須項目が無い・テンプレートのまま)
#   7=変更0件(完了報告はあるが作業ツリーに変更が無い。PR 作成の run(pr-*)では判定しない)
#   0=正常終了かつ完了報告あり / 1=done マーカーが無い・使い方不備
# Windows にはシグナルの仕組みが無いため、dispatch-run.ps1 は signal:* を書き出さない
# (強制終了は通常の非0終了として記録される)。POSIX 版が書き出した done も同じ規則で判定する。
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
# パスや埋め込みに使うため、タスクIDと試行回数の形式を検証する
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt: '$TaskId' '$Attempt'")
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$tailLines = 30
$runDir = ".agents/workflow/runs/$TaskId-$Attempt"
$donePath = "$runDir/done"
$logPath = "$runDir/output.log"
$guardPath = "$runDir/guard.sha256"

if (-not (Test-Path $donePath)) {
    [Console]::Error.WriteLine("done marker not found: $donePath (child agent has not finished yet)")
    exit 1
}

# ReadAllText は BOM を除去する(Windows PowerShell 5.1 の Out-File は BOM を付ける)
$doneLines = [System.IO.File]::ReadAllText((Resolve-Path $donePath), [System.Text.Encoding]::UTF8) -split "`r?`n"
$exitValue = ''
$endValue = ''
foreach ($line in $doneLines) {
    if (-not $exitValue -and $line.StartsWith('EXIT:')) { $exitValue = $line.Substring(5) }
    if (-not $endValue -and $line.StartsWith('END:')) { $endValue = $line.Substring(4) }
}

$kind = switch -Regex ($exitValue) {
    '^0$' { 'ok'; break }
    '^signal:' { 'signal'; break }
    '^crashed:' { 'crashed'; break }
    '^$' { 'unknown'; break }
    default { 'nonzero' }
}

# --- 管理ファイルの改ざん検知(dispatch-run が起動時に記録した guard.sha256 と比べる) ---
function Get-Sha256OrDash {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    return '-'
}
$guardIssues = @()
if (-not (Test-Path $guardPath)) {
    $guardIssues += 'guard.sha256 not found (deleted, or the run was not started by dispatch-run)'
} else {
    foreach ($line in ([System.IO.File]::ReadAllText((Resolve-Path $guardPath), [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        if ($line -notmatch '^(\S+)\s+(.+)$') { continue }
        $expected = $Matches[1]; $path = $Matches[2]
        $actual = Get-Sha256OrDash $path
        if ($actual -ne $expected) {
            if ($actual -eq '-') { $guardIssues += "deleted: $path" } else { $guardIssues += "changed: $path" }
        }
    }
}

# --- 本物のリポジトリの git 状態の検証(dispatch-run が起動時に git-state.txt に記録した値と比べる) ---
# タスク種別の判定(完了報告の必須項目と変更0件の判定で使う)は、ここでも $isPr を使うため
# この位置に置いている。PR 作成の run(タスクIDが pr- で始まる)は config を比べない
# (子が git push -u で .git/config を正当に変えるため)
$isPr = $TaskId.StartsWith('pr-')
$required = if ($isPr) { @('PR URL') } else { @('変更ファイル', 'テスト結果') }
# 各行を `-split ' ', 2` で名前と値に分けてハッシュテーブルに入れてから項目ごとに比べる
function ConvertTo-StateMap {
    param([string[]]$Lines)
    $map = @{}
    foreach ($line in $Lines) {
        $line = "$line".TrimEnd("`r")
        if (-not $line) { continue }
        $name, $value = $line -split ' ', 2
        $map["$name"] = "$value"
    }
    return $map
}
$gitStatePath = "$runDir/git-state.txt"
if (-not (Test-Path $gitStatePath)) {
    $guardIssues += 'git-state.txt not found (deleted, or the run was not started by dispatch-run)'
} else {
    $recordedState = ConvertTo-StateMap @([System.IO.File]::ReadAllText((Resolve-Path $gitStatePath), [System.Text.Encoding]::UTF8) -split "`r?`n")
    # git-state.ps1 の stderr は捨てる(失敗時は空出力になり、全項目が変わったと判定される)
    $currentState = ConvertTo-StateMap @(& pwsh -NoProfile -File "$PSScriptRoot/git-state.ps1" 2> $null)
    foreach ($name in @('head', 'branch', 'refs', 'config')) {
        if ($isPr -and $name -eq 'config') { continue }
        if ("$($recordedState[$name])" -ne "$($currentState[$name])") {
            $guardIssues += "git changed: $name"
        }
    }
}
$logText = $null
if (-not (Test-Path $logPath)) {
    $guardIssues += "deleted: $logPath"
} else {
    $logBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $logPath).Path)
    # Windows PowerShell 5.1 の `*>` は UTF-16LE(BOM FF FE)で書くため、BOM を見てデコードする
    if ($logBytes.Length -ge 2 -and $logBytes[0] -eq 0xFF -and $logBytes[1] -eq 0xFE) {
        $logText = [System.Text.Encoding]::Unicode.GetString($logBytes, 2, $logBytes.Length - 2)
    } else {
        $logText = [System.Text.Encoding]::UTF8.GetString($logBytes)
    }
    # 書き込み中のファイルを `: >` 等で空にすると、書き込み位置より前が NUL で埋まる(デコード後に判定する)
    if ($logText.Contains([string][char]0)) { $guardIssues += "truncated during the run (NUL bytes): $logPath" }
}

# --- ログの正規化(NUL・CR を除く。ANSI エスケープは行ごとに扱う) ---
$esc = [string][char]27
$ansiRe = [regex]::Escape($esc) + '\[[0-9;]*[A-Za-z]'
$rawLines = @()
$cleanLines = @()
if ($null -ne $logText) {
    $rawLines = @(($logText -replace "`0", '') -split "`r?`n")
    $cleanLines = @($rawLines | ForEach-Object { $_ -replace $ansiRe, '' })
}

# --- 権限拒否の検出 ---
# opencode が拒否を記録する行(行頭の `! permission requested: ...; auto-rejecting`)だけに一致させる
# (子がスクリプトやテストを表示した出力の中の同じ文字列には反応しない)
$deniedLines = @($cleanLines | Where-Object { $_ -match '^! permission requested: .*auto-rejecting' })

# ツール実行の記録: opencode が色付きで出すマーカー行(`ESC[0m$ ESC[0m...` 等)と
# stream-json の `[tool_use]` / `[tool_result]` 行に限る(報告本文の `→ 要確認` や `$ npm test` は対象外)
$toolRe = '^' + [regex]::Escape($esc) + '\[[0-9;]*m(\$|→|←|✱|✗|⚙|!) ' + [regex]::Escape($esc) + '\[[0-9;]*m'
$toolFlags = @($rawLines | ForEach-Object { ($_ -match $toolRe) -or ($_ -match '^\[tool_(use|result)\]') })

# --- 完了報告の判定 ---
# 最後に出現する `## 完了報告` だけを対象にし、その後にツール実行の記録が続く場合は無効とする
# (子がテンプレートやドキュメントを表示しただけの行に一致させないため)。必須項目は
# 通常のタスクが「変更ファイル」「テスト結果」、PR 作成の run(pr-*)が「PR URL」。
# 値が同じ行に無い場合は、次の行からのインデントされた箇条書きを値とみなす。
function Get-ReportResult {
    param([string[]]$Lines, [bool[]]$ToolFlags, [string[]]$Required)
    $last = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^## 完了報告[ \t]*$') { $last = $i } }
    if ($last -lt 0) { return 'missing' }
    for ($i = $last + 1; $i -lt $Lines.Count; $i++) {
        if ($ToolFlags[$i]) { return "invalid (tool activity after the report at line $($i + 1))" }
    }
    $end = $Lines.Count - 1
    for ($i = $last + 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^## ') { $end = $i - 1; break } }
    foreach ($field in $Required) {
        $prefix = "- ${field}:"
        $found = $false
        for ($i = $last + 1; $i -le $end; $i++) {
            if (-not $Lines[$i].StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
            $value = $Lines[$i].Substring($prefix.Length).Trim()
            if ($value -eq '' -and $i -lt $end -and $Lines[$i + 1] -match '^[ \t]+[^ \t]') { $value = '(list)' }
            if ($value -eq '') { return "invalid (empty field: $field)" }
            if ($value -match '^<[^>]*>$') { return "invalid (template placeholder: $field)" }
            $found = $true; break
        }
        if (-not $found) { return "invalid (missing field: $field)" }
    }
    return 'found'
}
$reportResult = Get-ReportResult $cleanLines $toolFlags $required

$changes = @(git status --porcelain | Where-Object { $_ })
$changeCount = $changes.Count

if ($guardIssues.Count -gt 0) {
    $verdict = 'tampered'; $code = 8
} elseif ($kind -ne 'ok') {
    $verdict = 'abnormal-exit'; $code = 4
} elseif ($deniedLines.Count -gt 0) {
    $verdict = 'permission-denied'; $code = 6
} elseif ($reportResult -ne 'found') {
    $verdict = 'no-report'; $code = 5
} elseif (-not $isPr -and $changeCount -eq 0) {
    $verdict = 'no-changes'; $code = 7
} else {
    $verdict = 'ok'; $code = 0
}

Write-Output "Run: $TaskId-$Attempt"
Write-Output "Exit: $exitValue (kind: $kind)"
Write-Output "End: $endValue"
if ($guardIssues.Count -gt 0) {
    Write-Output "Guard: NG"
    $guardIssues | ForEach-Object { Write-Output "  $_" }
} else {
    Write-Output "Guard: ok"
}
if ($deniedLines.Count -gt 0) {
    Write-Output "Permission denied: yes"
    $deniedLines | ForEach-Object { Write-Output "  $_" }
} else {
    Write-Output "Permission denied: no"
}
Write-Output "Completion report: $reportResult"
Write-Output "Changes: $changeCount"
Write-Output "Verdict: $verdict"
Write-Output "--- git status --porcelain"
git status --porcelain
Write-Output "--- git diff --stat"
git diff --stat
Write-Output "--- output.log (last $tailLines lines)"
if (Test-Path $logPath) {
    # 切り詰められた output.log(先頭の NUL)がそのまま出力されるため行ごとに除く(sh 版と揃える)
    Get-Content $logPath -Tail $tailLines -Encoding utf8 | ForEach-Object { $_.Replace([string][char]0, '') }
} else {
    Write-Output "(output.log not found)"
}

exit $code
