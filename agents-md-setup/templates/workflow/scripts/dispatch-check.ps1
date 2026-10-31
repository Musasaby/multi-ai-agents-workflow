# 子エージェントの完了検知後に毎回実行し、終了状態と成果物の有無を機械的に判定する。
# exit(複数に当たる場合は上にあるものを優先する):
#   8=管理ファイルの改ざん(prompt.md・state.json・tasks.md・config.json が dispatch-run の起動時から
#     変わった/消えた、guard.sha256・output.log・git-state.txt が無い、output.log が実行中に
#     切り詰められた、本物のリポジトリの git 状態(HEAD・ブランチ・参照・設定)が変わった)
#   4=異常終了(非0・signal・crashed・idle-timeout)
#   6=権限拒否で中断(output.log にプロファイルの権限拒否の記録がある)、または、ツール実行の記録に
#     プロジェクト外(/tmp・ホームディレクトリ等)へのアクセスがある
#   5=完了報告が無い・無効(最後の `## 完了報告` の後にツール実行の記録が続く、必須項目が無い・テンプレートのまま)。
#     最後のツール実行の後に出力が無い場合は、その旨を理由に書く
#   7=変更0件(完了報告はあるが作業ツリーに変更が無い。PR 作成の run(pr-*)では判定しない)
#   0=正常終了かつ完了報告あり / 2=done マーカーが無い(まだ実行中) / 1=使い方不備
# stdout の最後の行には次のアクションを示す `Next:` 行を出す(wait / review <TaskId> / collect <TaskId>(worktree の run で正常のとき)/
# escalate reason=<理由>。使い方不備の exit 1 では出さない)
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
    Write-Output "Next: wait"
    exit 2
}

# --- 子CLIプロファイルの解決(config.json の child_agent.profile。検知のパターンを決める) ---
# 解決できない(未定義の profile・定義ファイルが読めない)場合は、Next: 行を出さずに exit 1 で終わる
. "$PSScriptRoot/childprofile.ps1"
try {
    $childProfile = Get-ChildProfile -Root (Get-Location).Path
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$disabledChecks = @()
if (-not $childProfile.PermissionDeniedPattern) { $disabledChecks += 'permission-denied' }
if (-not $childProfile.ToolCallPattern) { $disabledChecks += 'outside-access' }
if (-not $childProfile.ToolActivityPattern) { $disabledChecks += 'tool-activity' }
if (-not $childProfile.ProviderErrorPattern) { $disabledChecks += 'provider-error' }

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
    '^idle-timeout$' { 'idle-timeout'; break }
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

function Get-StateEntryText {
    param([string]$TaskId)
    try {
        $st = Get-Content -LiteralPath '.agents/workflow/state.json' -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($st.tasks)) {
            if ("$($e.id)" -ne $TaskId) { continue }
            $parts = foreach ($k in @('commit', 'retries', 'status')) {
                $v = $e.$k
                if ($null -eq $v) { $j = 'null' }
                elseif ($v -is [string]) { $j = '"' + ($v.Replace('\', '\\').Replace('"', '\"')) + '"' }
                elseif ($v -is [bool]) { $j = $v.ToString().ToLowerInvariant() }
                else { $j = "$v" }
                '"' + $k + '": ' + $j
            }
            return '{' + ($parts -join ', ') + '}'
        }
    } catch {}
    return '-'
}
function Get-OtherRunIds {
    param([string]$TaskId)
    try {
        $st = Get-Content -LiteralPath '.agents/workflow/state.json' -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = foreach ($e in @($st.tasks)) {
            if ("$($e.id)" -ne $TaskId -and "$($e.status)" -in @('in_progress', 'in_review')) { "$($e.id)" }
        }
        return (@($ids) -join ',')
    } catch {}
    return ''
}
# worktree の run は、本体の state.json の自分のタスクの欄が起動時から変わっていないかも確かめる
if (Test-Path -LiteralPath "$runDir/worktree.txt") {
    $entryPath = "$runDir/state-entry.txt"
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        $guardIssues += 'state-entry.txt not found'
    } else {
        $recordedEntry = ([System.IO.File]::ReadAllText((Resolve-Path $entryPath), [System.Text.Encoding]::UTF8) -split "`r?`n")[0]
        if ((Get-StateEntryText $TaskId) -ne $recordedEntry) {
            $guardIssues += "changed: .agents/workflow/state.json ($TaskId)"
        }
    }
    # 自分以外のタスクの欄は、親の正規の遷移(task-state・state-sync --insert)だけを許す
    $tasksPath = "$runDir/state-tasks.json"
    if (-not (Test-Path -LiteralPath $tasksPath -PathType Leaf)) {
        $guardIssues += 'state-tasks.json not found'
    } else {
        $before = $null
        try {
            $before = @([System.IO.File]::ReadAllText((Resolve-Path $tasksPath), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        } catch {}
        $nowMap = @{}
        try {
            $stNow = Get-Content -LiteralPath '.agents/workflow/state.json' -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            foreach ($e in @($stNow.tasks)) { $nowMap["$($e.id)"] = $e }
        } catch {}
        if ($null -eq $before) {
            $guardIssues += "changed: .agents/workflow/state.json ($TaskId)"
        } else {
            $badTasks = @()
            $beforeIds = @{}
            foreach ($b in $before) {
                if ($null -eq $b) { continue }
                $tid = "$($b.id)"
                $beforeIds[$tid] = $true
                if ($tid -eq $TaskId) { continue }
                $n = $nowMap[$tid]
                if ($null -eq $n) { $badTasks += $tid; continue }
                if ("$($b.status)" -eq 'done') {
                    if ("$($n.status)" -ne 'done' -or "$($n.commit)" -ne "$($b.commit)") { $badTasks += $tid }
                } elseif ("$($n.status)" -eq 'done') {
                    $c = "$($n.commit)"
                    $isAnc = $false
                    if ($c) {
                        & git merge-base --is-ancestor $c HEAD 2> $null
                        $isAnc = ($LASTEXITCODE -eq 0)
                    }
                    if (-not $isAnc) { $badTasks += $tid }
                }
            }
            foreach ($tid in $nowMap.Keys) {
                if (-not $beforeIds.ContainsKey($tid) -and "$($nowMap[$tid].status)" -ne 'pending') { $badTasks += $tid }
            }
            foreach ($tid in $badTasks) { $guardIssues += "changed: .agents/workflow/state.json ($tid)" }
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
# worktree.txt がある run(dispatch-worktree create 済み)は、worktree の中で git-state -Run <branch> -Parent <親の作業ブランチ> を
# 実行した値で比べ、変更の取得も worktree の中で行う($wtDir が空でなければ worktree の run)
$wtDir = ''
$wtBranch = ''
$wtMissing = $false
$wtTxt = "$runDir/worktree.txt"
if (Test-Path $wtTxt -PathType Leaf) {
    foreach ($wl in @([System.IO.File]::ReadAllText((Resolve-Path $wtTxt), [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        if (-not $wtDir -and $wl.StartsWith('path ')) { $wtDir = $wl.Substring(5) }
        if (-not $wtBranch -and $wl.StartsWith('branch ')) { $wtBranch = $wl.Substring(7) }
    }
    if (-not $wtDir -or -not (Test-Path $wtDir -PathType Container)) {
        $wtMissing = $true
        $guardIssues += "worktree not found: $wtDir"
    }
}
$gitStatePath = "$runDir/git-state.txt"
if (-not (Test-Path $gitStatePath)) {
    $guardIssues += 'git-state.txt not found (deleted, or the run was not started by dispatch-run)'
} elseif ($wtMissing) {
    # worktree が無いので比べない(Guard には worktree not found を出している)
} else {
    $recordedState = ConvertTo-StateMap @([System.IO.File]::ReadAllText((Resolve-Path $gitStatePath), [System.Text.Encoding]::UTF8) -split "`r?`n")
    # git-state.ps1 の stderr は捨てる(失敗時は空出力になり、全項目が変わったと判定される)
    if ($wtDir) {
        $parentRef = "$(& git symbolic-ref -q HEAD 2> $null)".Trim()
        if (-not $parentRef) { $parentRef = '-' }
        $otherRuns = Get-OtherRunIds $TaskId
        Push-Location $wtDir
        try { $currentState = ConvertTo-StateMap @(& pwsh -NoProfile -File "$PSScriptRoot/git-state.ps1" -Run $wtBranch -Parent $parentRef -OtherRuns $otherRuns 2> $null) }
        finally { Pop-Location }
        # 親の作業ブランチが、起動時の参照名のまま、記録した値から進む方向にだけ動いたかを確かめる
        $parentHeadPath = "$runDir/parent-head.txt"
        if (-not (Test-Path -LiteralPath $parentHeadPath -PathType Leaf)) {
            $guardIssues += 'parent-head.txt not found'
        } else {
            $phLines = [System.IO.File]::ReadAllText((Resolve-Path $parentHeadPath), [System.Text.Encoding]::UTF8) -split "`r?`n"
            $recParentRef = "$($phLines[0])"
            $recParentSha = "$($phLines[1])"
            $curParentSha = "$(& git rev-parse --verify -q HEAD 2> $null)".Trim()
            if (-not $curParentSha) { $curParentSha = '-' }
            $parentBad = $false
            if ($recParentRef -cne $parentRef) { $parentBad = $true }
            elseif ($recParentSha -cne $curParentSha) {
                if ($recParentSha -eq '-' -or $curParentSha -eq '-') { $parentBad = $true }
                else {
                    $null = & git merge-base --is-ancestor $recParentSha $curParentSha 2> $null
                    if ($LASTEXITCODE -ne 0) { $parentBad = $true }
                }
            }
            if ($parentBad) { $guardIssues += 'git changed: parent' }
        }
    } else {
        $currentState = ConvertTo-StateMap @(& pwsh -NoProfile -File "$PSScriptRoot/git-state.ps1" 2> $null)
    }
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
# プロファイルの permission_denied_pattern に一致する行だけを対象にする(auto / opencode では
# 行頭の `! permission requested: ...; auto-rejecting`。子がスクリプトやテストを表示した出力の中の
# 同じ文字列には反応しない)。空なら検査しない
$deniedLines = @()
if ($childProfile.PermissionDeniedPattern) {
    $deniedLines = @($cleanLines | Where-Object { $_ -cmatch $childProfile.PermissionDeniedPattern })
}

# ツール実行の記録: プロファイルの tool_activity_pattern に一致する行に限る(auto / opencode では
# 色付きのマーカー行(`ESC[0m$ ESC[0m...` 等)と stream-json の `[tool_use]` / `[tool_result]` 行。
# 報告本文の `→ 要確認` や `$ npm test` は対象外。空なら記録は無いものとして扱う)
$toolFlags = @($rawLines | ForEach-Object { [bool]($childProfile.ToolActivityPattern -and ($_ -cmatch $childProfile.ToolActivityPattern)) })

# --- プロジェクト外(/tmp・ホームディレクトリ等)へのアクセスの検出 ---
# 権限を拒否されずに成功したプロジェクト外アクセス(例: bash -c "... > /tmp/x.log"、cat ~/x.log)を検出する。
# 対象はツール実行の記録行だけ(プロファイルの tool_call_pattern。auto / opencode では色付きマーカー行
# ($ / → / ← / ✱ / ✗ / ⚙ で始まるもの。! は権限拒否の行なので除く)と stream-json の [tool_use] 行)。
# ツールの出力(色なしの行・[tool_result] 行)や完了報告の本文には反応しない。パターンが空なら検査しない。
# 判定は ANSI エスケープを除いた行に対して行う。
# 条件の正規表現は $outsidePattern と $homePattern にまとめる(条件を足したくなったらここへ追記する)。
# $homePattern はホームディレクトリ(~/・$HOME・${HOME}・$env:USERPROFILE・%USERPROFILE% 等)と
# Windows のユーザー一時ディレクトリ(AppData の Temp)への参照(大文字小文字を区別しない)。
# $env:TEMP・%TEMP%・$TMPDIR は dispatch-run によりプロジェクト内を指すため検出しない
$outsidePattern = '(^|[ \t"''=(<>])/(var/)?tmp([/ \t"'');]|$)'
$homePattern = '(?i)(^|[ \t"''=(<>])~/|\$(\{home\}|home(?![a-z0-9_])|env:(home|userprofile)(?![a-z0-9_]))|%userprofile%|appdata[\\/]local[\\/]temp'
$outsideLines = @()
for ($i = 0; $i -lt $rawLines.Count; $i++) {
    $isToolExec = $childProfile.ToolCallPattern -and ($rawLines[$i] -cmatch $childProfile.ToolCallPattern)
    if ($isToolExec -and (($cleanLines[$i] -cmatch $outsidePattern) -or ($cleanLines[$i] -match $homePattern))) { $outsideLines += $cleanLines[$i] }
}

# --- 子CLI自身のログのエラー検出(利用上限・エンドポイント障害などの切り分け用) ---
# config.json の child_agent.cli_log(子CLI自身のログファイルのパス。先頭の ~/ はホームディレクトリ)
# を読む(ConvertFrom-Json が読めない・cli_log が無い場合は未設定扱い)。末尾 200 行のうち ERROR を
# 含む行の最後の 5 行と、プロバイダー起因かどうか(プロファイルの provider_error_pattern を小文字にした
# 行に当てる。auto / opencode では利用上限・レート制限・エンドポイント障害・429。
# 429 の前後に英数字を許さないのは .429Z のようなタイムスタンプや16進の ID に一致させないため。
# パターンが空のプロファイルでは判定しない)を出力に表示するだけなので、判定(Verdict・exit code)には影響しない
$cliLog = ''
try {
    $cfg = Get-Content '.agents/workflow/config.json' -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    $cliLog = "$($cfg.child_agent.cli_log)"
} catch {
    $cliLog = ''
}
$providerError = 'unknown'
$cliLogLines = @()
if ($cliLog -ne '') {
    $cliLogPath = if ($cliLog.StartsWith('~/')) { Join-Path $HOME $cliLog.Substring(2) } else { $cliLog }
    if (-not (Test-Path -LiteralPath $cliLogPath -PathType Leaf)) {
        $cliLog = "$cliLog (not found)"
    } else {
        $providerError = 'no'
        $cliLogLines = @(Get-Content -LiteralPath $cliLogPath -Tail 200 -Encoding utf8 | Where-Object { $_ -cmatch 'ERROR' } | Select-Object -Last 5)
        if ($childProfile.ProviderErrorPattern) {
            foreach ($line in $cliLogLines) {
                if ($line.ToLowerInvariant() -cmatch $childProfile.ProviderErrorPattern) {
                    $providerError = 'yes'; break
                }
            }
        }
    }
}

# --- 完了報告の判定 ---
# 最後に出現する `## 完了報告` だけを対象にし、その後にツール実行の記録が続く場合は無効とする
# (子がテンプレートやドキュメントを表示しただけの行に一致させないため)。必須項目は
# 通常のタスクが「変更ファイル」「テスト結果」、PR 作成の run(pr-*)が「PR URL」。
# 必須項目行の区切りは半角 `:` と全角 `：` のどちらでもよい。
# 値が同じ行に無い場合は、次の行からのインデントされた箇条書きを値とみなす。
function Get-ReportResult {
    param([string[]]$Lines, [bool[]]$ToolFlags, [string[]]$Required)
    $last = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^## 完了報告[ \t]*$') { $last = $i } }
    if ($last -lt 0) {
        # 最後の空でない行がツール実行の記録なら、子はその後に何も出力せずに終わった
        # (#50: 推論だけで出力トークン上限に達すると、opencode はエラーにせず exit 0 で終わる)
        for ($i = $Lines.Count - 1; $i -ge 0; $i--) { if ($Lines[$i] -match '[^ \t]') { break } }
        if ($i -ge 0 -and $ToolFlags[$i]) { return 'missing (no output after the last tool call; the model may have hit the output token limit)' }
        return 'missing'
    }
    for ($i = $last + 1; $i -lt $Lines.Count; $i++) {
        if ($ToolFlags[$i]) { return "invalid (tool activity after the report at line $($i + 1))" }
    }
    $end = $Lines.Count - 1
    for ($i = $last + 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^## ') { $end = $i - 1; break } }
    foreach ($field in $Required) {
        # 区切りは半角 `:` と全角 `：` のどちらも受け付ける(#55: 日本語で応答する子は全角で書くことがある)
        $prefixes = @("- ${field}:", "- ${field}：")
        $found = $false
        for ($i = $last + 1; $i -le $end; $i++) {
            $prefix = $null
            foreach ($p in $prefixes) { if ($Lines[$i].StartsWith($p, [System.StringComparison]::Ordinal)) { $prefix = $p; break } }
            if ($null -eq $prefix) { continue }
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

# worktree の run は worktree の中で変更を取る(worktree が無いときは本体で取る)
$gitArgs = if ($wtDir -and -not $wtMissing) { @('-C', $wtDir) } else { @() }
$changes = @(git @gitArgs status --porcelain | Where-Object { $_ })
$changeCount = $changes.Count

if ($guardIssues.Count -gt 0) {
    $verdict = 'tampered'; $code = 8
} elseif ($kind -ne 'ok') {
    $verdict = 'abnormal-exit'; $code = 4
} elseif ($deniedLines.Count -gt 0) {
    $verdict = 'permission-denied'; $code = 6
} elseif ($outsideLines.Count -gt 0) {
    $verdict = 'outside-access'; $code = 6
} elseif ($reportResult -ne 'found') {
    $verdict = 'no-report'; $code = 5
} elseif (-not $isPr -and $changeCount -eq 0) {
    $verdict = 'no-changes'; $code = 7
} else {
    $verdict = 'ok'; $code = 0
}

# --- 完了報告の report.md への書き出し($code が 0・7 = 完了報告が有効で改ざん・異常終了が無いとき) ---
# ブロックの範囲は Get-ReportResult と同じ: 最後の `## 完了報告` 行から、その後の最初の `## ` 行の
# 直前(無ければ末尾)まで。ANSI エスケープを除いた行で範囲を判定して書き出し、ブロック末尾の空行は
# 除く(最後に改行を1つだけ付ける)。既にあれば上書きしない(同じ run を再判定しても内容は同じため)
$reportPath = "$runDir/report.md"
$reportSaved = $false
if ($code -eq 0 -or $code -eq 7) {
    if (Test-Path $reportPath -PathType Leaf) {
        $reportSaved = $true
    } else {
        $last = -1
        for ($i = 0; $i -lt $cleanLines.Count; $i++) { if ($cleanLines[$i] -match '^## 完了報告[ \t]*$') { $last = $i } }
        $reportBody = ''
        if ($last -ge 0) {
            $end = $cleanLines.Count - 1
            for ($i = $last + 1; $i -lt $cleanLines.Count; $i++) { if ($cleanLines[$i] -match '^## ') { $end = $i - 1; break } }
            while ($end -gt $last -and $cleanLines[$end] -match '^[ \t]*$') { $end-- }
            if ($end -ge $last) { $reportBody = ($cleanLines[$last..$end] -join "`n") }
        }
        if ($reportBody -ne '') {
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) $reportPath), ($reportBody + "`n"), (New-Object System.Text.UTF8Encoding $false))
            $reportSaved = $true
        }
    }
}

Write-Output "Run: $TaskId-$Attempt"
Write-Output "Exit: $exitValue (kind: $kind)"
Write-Output "End: $endValue"
Write-Output "Profile: $($childProfile.Name)"
Write-Output "Disabled checks: $(if ($disabledChecks.Count -gt 0) { $disabledChecks -join ', ' } else { 'none' })"
if ($guardIssues.Count -gt 0) {
    Write-Output "Guard: NG"
    $guardIssues | ForEach-Object { Write-Output "  $_" }
} else {
    Write-Output "Guard: ok"
}
if (-not $childProfile.PermissionDeniedPattern) {
    Write-Output "Permission denied: disabled (profile: $($childProfile.Name))"
} elseif ($deniedLines.Count -gt 0) {
    Write-Output "Permission denied: yes"
    $deniedLines | ForEach-Object { Write-Output "  $_" }
} else {
    Write-Output "Permission denied: no"
}
if (-not $childProfile.ToolCallPattern) {
    Write-Output "Outside access: disabled (profile: $($childProfile.Name))"
} elseif ($outsideLines.Count -gt 0) {
    Write-Output "Outside access: yes"
    $outsideLines | ForEach-Object { Write-Output "  $_" }
} else {
    Write-Output "Outside access: no"
}
Write-Output "CLI log: $(if ($cliLog) { $cliLog } else { '(not configured)' })"
if ($cliLogLines.Count -gt 0) {
    $cliLogLines | ForEach-Object { Write-Output "  $_" }
}
if (-not $childProfile.ProviderErrorPattern) {
    Write-Output "Provider error: disabled (profile: $($childProfile.Name))"
} else {
    Write-Output "Provider error: $providerError"
}
Write-Output "Completion report: $reportResult"
if ($reportSaved) {
    Write-Output "Report: $reportPath"
}
Write-Output "Changes: $changeCount"
Write-Output "Verdict: $verdict"
Write-Output "--- git status --porcelain"
git @gitArgs status --porcelain
Write-Output "--- git diff --stat"
git @gitArgs diff --stat
Write-Output "--- output.log (last $tailLines lines)"
if (Test-Path $logPath) {
    # 切り詰められた output.log(先頭の NUL)がそのまま出力されるため行ごとに除く(sh 版と揃える)
    Get-Content $logPath -Tail $tailLines -Encoding utf8 | ForEach-Object { $_.Replace([string][char]0, '') }
} else {
    Write-Output "(output.log not found)"
}

# --- 次のアクションの判定(stdout の最後の行に出す) ---
# PR 作成の run(pr-*)はレビューしない。PR を検証して報告し、マージを待つ
$next = switch ($code) {
    0 {
        if ($isPr) { 'wait-merge' }
        elseif ($wtDir) { "collect $TaskId" }
        else { "review $TaskId" }
        break
    }
    8 { 'escalate reason=tampered'; break }
    4 {
        if ($providerError -eq 'yes') { 'escalate reason=provider-error' }
        elseif ($kind -eq 'idle-timeout') { 'escalate reason=idle-timeout' }
        else { 'escalate reason=abnormal-exit' }
        break
    }
    6 {
        if ($verdict -eq 'permission-denied') { 'escalate reason=permission-denied' }
        else { 'escalate reason=outside-access' }
        break
    }
    5 {
        if ($reportResult.StartsWith('missing (no output after the last tool call')) { 'escalate reason=token-limit' }
        else { 'escalate reason=no-report' }
        break
    }
    7 { 'escalate reason=no-changes'; break }
}
Write-Output "Next: $next"

exit $code
