# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# exit(複数に当たる場合は上にあるものを優先する):
#   8=管理ファイルの改ざん(prompt.md・state.json・tasks.md・config.json が dispatch-run の起動時から
#     変わった/消えた、guard.sha256・output.log が無い、output.log が実行中に切り詰められた)
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
$logBytes = $null
if (-not (Test-Path $logPath)) {
    $guardIssues += "deleted: $logPath"
} else {
    $logBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $logPath).Path)
    # 書き込み中のファイルを `: >` 等で空にすると、書き込み位置より前が NUL で埋まる
    if ([Array]::IndexOf($logBytes, [byte]0) -ge 0) { $guardIssues += "truncated during the run (NUL bytes): $logPath" }
}

# --- ログの正規化(NUL・ANSI エスケープ・CR を除く) ---
$cleanLines = @()
if ($null -ne $logBytes) {
    $text = [System.Text.Encoding]::UTF8.GetString($logBytes) -replace "`0", ''
    $text = $text -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
    $cleanLines = @($text -split "`r?`n")
}

# --- 権限拒否の検出(opencode: "auto-rejecting" / "rejected permission") ---
$deniedLines = @($cleanLines | Where-Object { $_ -match 'auto-rejecting|rejected permission' })

# --- 完了報告の判定 ---
# 最後に出現する `## 完了報告` だけを対象にし、その後にツール実行の記録が続く場合は無効とする
# (子がテンプレートやドキュメントを表示しただけの行に一致させないため)。必須項目は
# 通常のタスクが「変更ファイル」「テスト結果」、PR 作成の run(pr-*)が「PR URL」。
# 値が同じ行に無い場合は、次の行からのインデントされた箇条書きを値とみなす。
$isPr = $TaskId.StartsWith('pr-')
$required = if ($isPr) { @('PR URL') } else { @('変更ファイル', 'テスト結果') }
function Get-ReportResult {
    param([string[]]$Lines, [string[]]$Required)
    $last = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^## 完了報告[ \t]*$') { $last = $i } }
    if ($last -lt 0) { return 'missing' }
    for ($i = $last + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^(\$|→|←|✱|✗|⚙|!) ' -or $Lines[$i] -match '^\[tool_(use|result)\]') {
            return "invalid (tool activity after the report at line $($i + 1))"
        }
    }
    $end = $Lines.Count - 1
    for ($i = $last + 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^## ') { $end = $i - 1; break } }
    foreach ($field in $Required) {
        $prefix = "- ${field}:"
        $found = $false
        for ($i = $last + 1; $i -le $end; $i++) {
            if (-not $Lines[$i].StartsWith($prefix)) { continue }
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
$reportResult = Get-ReportResult $cleanLines $required

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
    Get-Content $logPath -Tail $tailLines -Encoding utf8
} else {
    Write-Output "(output.log not found)"
}

exit $code
