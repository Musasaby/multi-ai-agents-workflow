# 1グループ分のタスクを、タスクの起動からレビュー・collect・品質ゲート・コミットまで進める。
# 進行中(in_progress / in_review)のタスクを run-phase の段階に応じて1つずつ
# 進め、next-task で空きの分だけ新しいタスクを起動する。-MaxWait 秒に達するか、グループが
# 終わるか、止まるまで動く(常駐はしない。呼び直せば state.json と runs/ から続きを再開する)。
# Usage: workflow-run.ps1 [-MaxWait <秒>] [-Interval <秒>]
#   -MaxWait の既定は 480(1回の呼び出しで進める上限。0 は上限なし) /
#   -Interval の既定は 15(状態を確かめ直す間隔)
# exit: 0 = グループが終わった(Next: group-advance / Next: finish。next-task の結果)
#       1 = 使い方の誤り、または state.json が無い(Next: 行は出さない)
#       2 = -MaxWait に達した(Next: wait)
#       3 = 止まった(Next: escalate reason=<理由>。段階が manual のときだけ Next: review <ID>)
#       4 = 使える条件を満たさない(Next: escalate reason=runner-unsupported)
#       5 = 別の workflow-run が実行中(Next: escalate reason=already-running)
# 使える条件: config.json の review.mode が dispatch、review.command_template が空でない、
#   max_parallel が 2 以上の整数。どれかを満たさなければ stderr に理由を出して exit 4 する。
# stdout の行(詳細は runs/workflow-run/last-output.log):
#   Started: <ID>-<N>            実装の run を起動した
#   Checked: <ID>-<N>            実装の run が dispatch-check を通った
#   Review started: <ID>-<N>     レビューの run を起動した
#   Review: <ID>-<N> <pass|fail> レビューの run の結果
#   Collected: <ID>-<N>          実装の run を取り込んだ
#   Undeclared: <ID> <パス>      変更対象に宣言していないファイル
#   Gate warning: <ID> <ステップ> 非 blocking の品質ゲートが失敗した
#   Done: <ID> <ハッシュ7桁> retries=<n>  コミットした
#   Retry: <ID> <n>/<上限> (review|quality-gate)  やり直しを起動した
#   Redo: <ID>-<N> (conflict)    衝突のため最新の HEAD からやり直す試行を起動した
#   Stopped: <ID> reason=<理由>  止まった(タスクIDが無ければ -)
#   Finished: <Next の値>        グループが終わった
#   In flight: <ID>-<N> <段階>   実行中のタスク(記録には書かない)
#   Detail: <last-output.log のパス>  止まったときの詳細(記録には書かない)
# Started:・Checked:・Review started:・Review:・Collected:・Undeclared:・Gate warning:・Done:・
# Retry:・Redo:・Stopped:・Finished: は runs/workflow-run/progress.log にも時刻付きで書く。
# 止まる理由には review-invalid(レビューの完了報告が無効・異常終了・時間超過など)・
#   conflict(collect の衝突)・quality-gate-error(品質ゲートの異常終了)・
#   retry-limit(やり直しの上限超過)・commit-format(type か要約が不正)・
#   task-state(状態遷移の失敗)がある。
# ロック: runs/workflow-run/lock/pid に自分の PID を書き、実行する。ロックがあり、そのプロセスが
#   生きていれば exit 5、死んでいれば引き継ぐ。終了時にロックを消す処理は finally で行う。
param(
    [int]$MaxWait = 480,
    [int]$Interval = 15,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Usage = 'Usage: workflow-run.ps1 [-MaxWait <秒>] [-Interval <秒>]'

if ($MaxWait -lt 0 -or $Interval -lt 0 -or ($null -ne $Rest -and $Rest.Count -gt 0)) {
    [Console]::Error.WriteLine($Usage)
    exit 1
}

$script:ScriptDir = $PSScriptRoot
Set-Location $script:ScriptDir\..\..\..
# .NET のファイル API は Set-Location では変わらないカレントディレクトリを使う
[Environment]::CurrentDirectory = (Get-Location).Path

$StatePath = '.agents/workflow/state.json'
$ConfigPath = '.agents/workflow/config.json'
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    [Console]::Error.WriteLine("state.json not found: $StatePath")
    exit 1
}

# null を <absent>、それ以外をそのまま文字列にする(使える条件の stderr 用)
function Format-Value {
    param($Value)
    if ($null -eq $Value) { return '<absent>' }
    return "$Value"
}

# 使える条件(config.json)をロックの前に確かめる。満たさなければ理由を返す(空文字列なら満たす)
function Get-Unsupported {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return 'config.json cannot be read: ' + $_.Exception.Message
    }
    $review = $cfg.review
    if ($review -isnot [System.Management.Automation.PSCustomObject]) { $review = $null }
    $mode = if ($null -ne $review) { $review.mode } else { $null }
    if ($mode -cne 'dispatch') {
        return "review.mode is not 'dispatch' (review.mode: $(Format-Value $mode))"
    }
    if ([string]::IsNullOrEmpty([string]$review.command_template)) {
        return 'review.command_template is empty'
    }
    $mp = $cfg.max_parallel
    $isInteger = ($mp -is [int]) -or ($mp -is [long]) -or ($mp -is [int16]) -or ($mp -is [byte])
    if (-not $isInteger -or $mp -lt 2) {
        return "max_parallel must be an integer >= 2 (max_parallel: $(Format-Value $mp))"
    }
    return ''
}

$unsupported = Get-Unsupported
if ($unsupported -ne '') {
    [Console]::Error.WriteLine($unsupported)
    Write-Output 'Next: escalate reason=runner-unsupported'
    exit 4
}

$Runs = '.agents/workflow/runs'
$RunnerDir = "$Runs/workflow-run"
$LockDir = "$RunnerDir/lock"
$Progress = "$RunnerDir/progress.log"
$Last = "$RunnerDir/last-output.log"

$null = New-Item -ItemType Directory -Force $RunnerDir

# ロックを取る。生きているプロセスのロックがあれば exit 5、死んでいれば引き継ぐ
if (Test-Path -LiteralPath $LockDir -PathType Container) {
    $oldPid = 0
    if (Test-Path -LiteralPath "$LockDir/pid" -PathType Leaf) {
        $oldPidText = ''
        try { $oldPidText = (Get-Content -LiteralPath "$LockDir/pid" -Raw -ErrorAction Stop).Trim() } catch { }
        if ($oldPidText -cmatch '^[0-9]+$') { $oldPid = [int]$oldPidText }
    }
    if ($oldPid -gt 0 -and $null -ne (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("workflow-run is already running (pid $oldPid)")
        Write-Output 'Next: escalate reason=already-running'
        exit 5
    }
    Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $LockDir) { Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue }
try {
    $null = New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop
} catch {
    exit 1
}
[System.IO.File]::WriteAllText("$LockDir/pid", "$PID`n", [System.Text.UTF8Encoding]::new($false))

# BOM なし UTF-8・改行 LF で書く(progress.log と last-output.log の形式)
function Write-LfFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

# stdout に出し、progress.log にも時刻付きで書く
function Emit {
    param([string]$Message)
    Write-Output $Message
    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    [System.IO.File]::AppendAllText($Progress, "$stamp $Message`n", [System.Text.UTF8Encoding]::new($false))
}

# last-output.log から最後の `Next: ` 行の値を出す(無ければ空)
function Get-LastNext {
    if (-not (Test-Path -LiteralPath $Last -PathType Leaf)) { return '' }
    $line = Get-Content -LiteralPath $Last -Encoding utf8 | Where-Object { $_ -like 'Next: *' } | Select-Object -Last 1
    if ($null -eq $line) { return '' }
    return $line.Substring(6)
}

# スクリプトを呼び、出力を last-output.log に書く。CallCode に exit code、CallNext に
# 最後の `Next: ` 行の値を入れる
function Invoke-Step {
    param([string]$Name, [string[]]$Arguments = @())
    $lines = @()
    if ($Arguments.Count -gt 0) {
        $lines = @(& pwsh -NoProfile -File "$script:ScriptDir/$Name" @Arguments 2>&1 | ForEach-Object { "$_" })
    } else {
        $lines = @(& pwsh -NoProfile -File "$script:ScriptDir/$Name" 2>&1 | ForEach-Object { "$_" })
    }
    $script:CallCode = $LASTEXITCODE
    $text = ($lines -join "`n")
    if ($lines.Count -gt 0) { $text += "`n" }
    Write-LfFile $Last $text
    $script:CallNext = Get-LastNext
}

# CallNext が `escalate reason=X` なら X、そうでなければ $Default を出す
function Get-NextReason {
    param([string]$Default)
    if ($script:CallNext -like 'escalate reason=*') { return $script:CallNext.Substring(16) }
    return $Default
}

# state.json のタスク $TaskId のキー $Key の値を出す(無ければ空)
function Get-StateField {
    param([string]$TaskId, [string]$Key)
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
    $task = @($state.tasks) | Where-Object { $_.id -ceq $TaskId } | Select-Object -First 1
    if (-not $task) { return '' }
    $value = $task.$Key
    if ($null -eq $value) { return '' }
    if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
    return "$value"
}

# status が in_progress / in_review のタスクIDを state.json の順に出す
function Get-ActiveIds {
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
    return @(@($state.tasks) | Where-Object { $_.status -in @('in_progress', 'in_review') } | ForEach-Object { $_.id })
}

# run-phase の `Phase: ` の後ろ("<段階> <N>")を出す
function Get-Phase {
    param([string]$TaskId)
    $line = @(& pwsh -NoProfile -File "$script:ScriptDir/run-phase.ps1" $TaskId 2>$null |
        Where-Object { $_ -like 'Phase: *' } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return [pscustomobject]@{ Phase = ''; N = 0 } }
    $parts = $line[0].Substring(7).Trim() -split '\s+'
    $n = 0
    if ($parts.Count -gt 1) { $n = [int]$parts[1] }
    return [pscustomobject]@{ Phase = $parts[0]; N = $n }
}

# 実行中のタスクを `In flight: <ID>-<N> <段階>` で出す(記録には書かない)
function Write-InFlight {
    foreach ($id in @(Get-ActiveIds)) {
        $phase = Get-Phase $id
        Write-Output "In flight: $id-$($phase.N) $($phase.Phase)"
    }
}

# 止まる。TaskId が無ければ -。LastLine の既定は `Next: escalate reason=<理由>`
function Stop-Run {
    param([string]$TaskId = '-', [string]$Reason, [string]$LastLine = '')
    Emit "Stopped: $TaskId reason=$Reason"
    Write-Output "Detail: $Last"
    Write-InFlight
    if ($LastLine -ne '') { Write-Output $LastLine } else { Write-Output "Next: escalate reason=$Reason" }
    $script:ExitCode = 3
    throw $script:StopMarker
}

# 実装の run を起動する
function Start-Task {
    param([string]$TaskId, [int]$Attempt)
    Invoke-Step -Name 'dispatch-start.ps1' -Arguments @('-TaskId', $TaskId, '-Attempt', "$Attempt")
    if ($script:CallCode -eq 0 -and $script:CallNext -ceq 'wait') {
        Emit "Started: $TaskId-$Attempt"
    } else {
        Stop-Run -TaskId $TaskId -Reason (Get-NextReason 'dispatch-start')
    }
}

# 実装の run の完了を1回だけ確かめる
function Wait-Impl {
    param([string]$TaskId, [int]$Attempt)
    Invoke-Step -Name 'dispatch-wait.ps1' -Arguments @('-TaskId', $TaskId, '-Attempt', "$Attempt", '-MaxWait', '0')
    switch ($script:CallCode) {
        2 { return }                                                     # 実行中
        0 {
            if ($script:CallNext -ceq "collect $TaskId") {
                Write-LfFile "$Runs/$TaskId-$Attempt/checked" ''
                Emit "Checked: $TaskId-$Attempt"
            } else {
                Stop-Run -TaskId $TaskId -Reason 'not-worktree'           # worktree の run ではない
            }
        }
        default { Stop-Run -TaskId $TaskId -Reason (Get-NextReason 'dispatch-check') }
    }
}

# レビューの run を起動する
function Start-Review {
    param([string]$TaskId, [int]$Attempt)
    Invoke-Step -Name 'dispatch-start.ps1' -Arguments @('-Review', '-TaskId', $TaskId, '-Attempt', "$Attempt")
    if ($script:CallCode -eq 0 -and $script:CallNext -ceq 'wait') {
        Emit "Review started: $TaskId-$Attempt"
    } else {
        Stop-Run -TaskId $TaskId -Reason (Get-NextReason 'review-start')
    }
}

# last-output.log から `<見出し>: ` で始まる最後の行の値を出す(例: 見出し "Review type")
function Get-LastField {
    param([string]$Heading)
    if (-not (Test-Path -LiteralPath $Last -PathType Leaf)) { return '' }
    $line = Get-Content -LiteralPath $Last -Encoding utf8 |
        Where-Object { $_.StartsWith("${Heading}: ") } | Select-Object -Last 1
    if ($null -eq $line) { return '' }
    return $line.Substring($Heading.Length + 2)
}

# レビューの run の完了を1回だけ確かめる
function Wait-Review {
    param([string]$TaskId, [int]$Attempt)
    $vfile = "$Runs/review-$TaskId-$Attempt/verdict"
    Invoke-Step -Name 'dispatch-wait.ps1' -Arguments @('-TaskId', "review-$TaskId", '-Attempt', "$Attempt", '-MaxWait', '0')
    if ($script:CallCode -eq 2) { return }
    if ($script:CallCode -eq 0 -and $script:CallNext -ceq "commit $TaskId") {
        $type = Get-LastField 'Review type'
        $summary = Get-LastField 'Review summary'
        Write-LfFile $vfile "pass`n$type`n$summary`n"
        Emit "Review: $TaskId-$Attempt pass"
    } elseif ($script:CallCode -eq 0 -and $script:CallNext -ceq "retry $TaskId") {
        Write-LfFile $vfile "fail`n"
        Emit "Review: $TaskId-$Attempt fail"
    } else {
        Stop-Run -TaskId $TaskId -Reason 'review-invalid'      # 完了報告が無効・異常終了・時間超過など
    }
}

# config.json の最上位のキー $Key の値を出す(bool は true/false、文字列・数値はそのまま、無ければ空)
function Get-CfgValue {
    param([string]$Key)
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return ''
    }
    if ($null -eq $cfg.PSObject.Properties[$Key]) { return '' }
    $value = $cfg.$Key
    if ($null -eq $value) { return '' }
    if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
    return "$value"
}

# 品質ゲートの方式を出す: quality_gate があれば steps、無くて test_command が空でなければ test、どちらも無ければ none
function Get-GateMode {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return 'none'
    }
    if ($null -ne $cfg.PSObject.Properties['quality_gate']) { return 'steps' }
    $testCommand = if ($null -ne $cfg.PSObject.Properties['test_command']) { [string]$cfg.test_command } else { '' }
    if ($testCommand.Trim() -ne '') { return 'test' }
    return 'none'
}

# やり直しの上限(config.json の max_fix_retries。無ければ 2。task-state.ps1 と同じ読み方)
$script:MaxFixRetries = Get-CfgValue 'max_fix_retries'
if ($script:MaxFixRetries -notmatch '^[0-9]+$') { $script:MaxFixRetries = '2' }
$script:MaxFixRetries = [int]$script:MaxFixRetries

# 合格した run を取り込み、レビュー役の type と要約でコミットする
function Invoke-Collect {
    param([string]$TaskId, [int]$Attempt)
    Invoke-Step -Name 'dispatch-worktree.ps1' -Arguments @('collect', $TaskId, "$Attempt")
    switch ($script:CallCode) {
        0 {
            foreach ($line in @(Get-Content -LiteralPath $Last -Encoding utf8)) {
                if ($line.StartsWith('Undeclared: ')) {
                    $path = $line.Substring(12)
                    if ($path -cne 'none') { Emit "Undeclared: $TaskId $path" }
                }
            }
            Invoke-Step -Name 'task-state.ps1' -Arguments @($TaskId, 'review')
            if ($script:CallCode -ne 0) { Stop-Run -TaskId $TaskId -Reason 'task-state' }
            Emit "Collected: $TaskId-$Attempt"
            Invoke-GateAndCommit -TaskId $TaskId -Attempt $Attempt
        }
        40 { Invoke-RedoAfterConflict -TaskId $TaskId -Attempt $Attempt }   # collect の衝突。最新の HEAD からやり直す
        default { Stop-Run -TaskId $TaskId -Reason (Get-NextReason 'collect') }   # dirty-tree・worktree
    }
}

# 品質ゲートを通し、コミットする(状態は in_review で、変更は本体にある)
function Invoke-GateAndCommit {
    param([string]$TaskId, [int]$Attempt)
    $vfile = "$Runs/review-$TaskId-$Attempt/verdict"
    $lines = if (Test-Path -LiteralPath $vfile -PathType Leaf) { @(Get-Content -LiteralPath $vfile -Encoding utf8) } else { @() }
    $type = if ($lines.Count -ge 2) { $lines[1] -replace "`r", '' } else { '' }
    $summary = if ($lines.Count -ge 3) { $lines[2] -replace "`r", '' } else { '' }
    if ((Get-CfgValue 'verify_before_commit') -ceq 'true') {
        switch (Get-GateMode) {
            'steps' {
                Invoke-Step -Name 'quality-gate.ps1' -Arguments @('-OutDir', "$Runs/$TaskId-$Attempt/gate")
                switch ($script:CallCode) {
                    0 {
                        foreach ($line in @(Get-Content -LiteralPath $Last -Encoding utf8)) {
                            if ($line -cmatch '^FAIL ([^ ]+) \(non-blocking\)') {
                                Emit "Gate warning: $TaskId $($Matches[1])"
                            }
                        }
                    }
                    3 { }                                              # 実行するステップが無い
                    2 { Invoke-RetryAfterGate -TaskId $TaskId -Attempt $Attempt; return }   # FAIL。fix-notes.md を書いてやり直す
                    default { Stop-Run -TaskId $TaskId -Reason 'quality-gate-error' }
                }
            }
            'test' {
                $gateDir = "$Runs/$TaskId-$Attempt/gate"
                $null = New-Item -ItemType Directory -Force -Path $gateDir
                $log = "$gateDir/test_command.log"
                $null | & pwsh -NoProfile -Command (Get-CfgValue 'test_command') *> $log
                if ($LASTEXITCODE -ne 0) {
                    Copy-Item -LiteralPath $log -Destination $Last -Force
                    Invoke-RetryAfterGate -TaskId $TaskId -Attempt $Attempt
                    return                                              # FAIL。fix-notes.md を書いてやり直す
                }
            }
        }
    }
    if (@('feat', 'fix', 'refactor', 'docs', 'test', 'chore', 'perf', 'ci') -cnotcontains $type) {
        Stop-Run -TaskId $TaskId -Reason 'commit-format'
    }
    if ($summary -ceq '' -or $summary -ceq '(list)') { Stop-Run -TaskId $TaskId -Reason 'commit-format' }
    Invoke-Step -Name 'task-commit.ps1' -Arguments @('-TaskId', $TaskId, '-Type', $type, '-Description', $summary)
    if ($script:CallCode -ne 0 -or $script:CallNext -cne 'continue') {
        Stop-Run -TaskId $TaskId -Reason (Get-NextReason 'commit')
    }
    $hash = ''
    foreach ($line in @(Get-Content -LiteralPath $Last -Encoding utf8)) {
        if ($line -cmatch '^Committed: ([0-9a-f]+) ') { $hash = $Matches[1] }
    }
    Emit "Done: $TaskId $hash retries=$(Get-StateField $TaskId 'retries')"
}

# 段階 retry(レビュー不合格)。fix-notes.md はレビュー役が書いている
function Invoke-Retry {
    param([string]$TaskId, [int]$Attempt)
    $retries = Get-StateField $TaskId 'retries'
    if ($retries -eq '') { $retries = '0' }
    if ((Get-StateField $TaskId 'status') -ceq 'in_progress') {
        if ([int]$retries -ge $script:MaxFixRetries) {
            # 上限。親が今の手順(agent-review-commit §4 の上限超過)で続けられるよう、collect して in_review にしてから止まる
            Invoke-Step -Name 'dispatch-worktree.ps1' -Arguments @('collect', $TaskId, "$Attempt")
            if ($script:CallCode -ne 0) { Stop-Run -TaskId $TaskId -Reason (Get-NextReason 'collect') }
            Invoke-Step -Name 'task-state.ps1' -Arguments @($TaskId, 'review')
            Stop-Run -TaskId $TaskId -Reason 'retry-limit'
        }
        Write-LfFile "$Runs/$TaskId-$Attempt/carry" ''
        Invoke-Step -Name 'task-state.ps1' -Arguments @($TaskId, 'review')
        if ($script:CallCode -ne 0) { Stop-Run -TaskId $TaskId -Reason 'task-state' }
    }
    Invoke-Step -Name 'task-state.ps1' -Arguments @($TaskId, 'retry')
    if ($script:CallCode -eq 4) { Stop-Run -TaskId $TaskId -Reason 'retry-limit' }
    if ($script:CallCode -ne 0) { Stop-Run -TaskId $TaskId -Reason 'task-state' }
    Write-LfFile "$Runs/$TaskId-$Attempt/superseded" ''
    Emit "Retry: $TaskId $([int]$retries + 1)/$script:MaxFixRetries (review)"
    Start-Task -TaskId $TaskId -Attempt ($Attempt + 1)
}

# 品質ゲートが FAIL。last-output.log に品質ゲート(または test_command)の出力がある
function Invoke-RetryAfterGate {
    param([string]$TaskId, [int]$Attempt)
    $next = $Attempt + 1
    $retries = Get-StateField $TaskId 'retries'
    if ($retries -eq '') { $retries = '0' }
    $dir = "$Runs/$TaskId-$next"
    $null = New-Item -ItemType Directory -Force $dir
    $body = @()
    if (Test-Path -LiteralPath $Last -PathType Leaf) {
        $body = @(Get-Content -LiteralPath $Last -Encoding utf8 |
            Where-Object { $_ -notmatch '^Next: ' } | Select-Object -Last 80)
    }
    $lines = @(
        '# 修正依頼(原因種別: 品質ゲート FAIL)'
        ''
        'コミット前の品質ゲートが失敗しました。下の出力から原因を調べて直し、失敗したコマンドが通ることを確かめてください。'
        ''
        '```'
    ) + $body + @('```')
    Write-LfFile "$dir/fix-notes.md" (($lines -join "`n") + "`n")
    Invoke-Step -Name 'task-state.ps1' -Arguments @($TaskId, 'retry')
    if ($script:CallCode -eq 4) { Stop-Run -TaskId $TaskId -Reason 'retry-limit' }
    if ($script:CallCode -ne 0) { Stop-Run -TaskId $TaskId -Reason 'task-state' }
    Emit "Retry: $TaskId $([int]$retries + 1)/$script:MaxFixRetries (quality-gate)"
    Start-Task -TaskId $TaskId -Attempt $next
}

# collect が衝突した(状態は in_progress。worktree は残っている)
function Invoke-RedoAfterConflict {
    param([string]$TaskId, [int]$Attempt)
    $next = $Attempt + 1
    if ($Attempt -gt $script:MaxFixRetries) { Stop-Run -TaskId $TaskId -Reason 'conflict' }   # 試行は MAX + 1 回まで
    $dir = "$Runs/$TaskId-$next"
    $null = New-Item -ItemType Directory -Force $dir
    $root = ((Get-Location).Path -replace '\\', '/')
    $lines = @(
        '# 修正依頼(原因種別: 取り込みの衝突)'
        ''
        '前の試行の変更は、ほかのタスクのコミットと衝突したため本体に取り込めませんでした。最新の HEAD でやり直してください。'
        "前の試行の変更は ``$root/$Runs/$TaskId-$Attempt/changes.patch`` にあります。このファイルだけは worktree の外にありますが、読んで構いません(そのままは当たりません)。"
    )
    Write-LfFile "$dir/fix-notes.md" (($lines -join "`n") + "`n")
    Write-LfFile "$Runs/$TaskId-$Attempt/superseded" ''
    Emit "Redo: $TaskId-$next (conflict)"
    Start-Task -TaskId $TaskId -Attempt $next
}

# run-phase の段階に応じて1つ進める
function Invoke-Task {
    param([string]$TaskId)
    $phase = Get-Phase $TaskId
    switch ($phase.Phase) {
        'start' { Start-Task -TaskId $TaskId -Attempt $phase.N }
        'running' { Wait-Impl -TaskId $TaskId -Attempt $phase.N }
        'manual' { Stop-Run -TaskId $TaskId -Reason 'manual' -LastLine "Next: review $TaskId" }
        'review-start' { Start-Review -TaskId $TaskId -Attempt $phase.N }
        'reviewing' { Wait-Review -TaskId $TaskId -Attempt $phase.N }
        'collect' { Invoke-Collect -TaskId $TaskId -Attempt $phase.N }
        'gate' { Invoke-GateAndCommit -TaskId $TaskId -Attempt $phase.N }
        'retry' { Invoke-Retry -TaskId $TaskId -Attempt $phase.N }
        default { Stop-Run -TaskId $TaskId -Reason 'unknown-phase' }
    }
}

$script:StopMarker = 'workflow-run-stop'
$script:ExitCode = 1
$start = [DateTime]::UtcNow
$done = $false
try {
    while (-not $done) {
        foreach ($id in @(Get-ActiveIds)) { Invoke-Task $id }
        Invoke-Step 'next-task.ps1'
        switch ($script:CallCode) {
            0 {
                if ($script:CallNext -like 'dispatch *') {
                    $ids = @($script:CallNext.Substring(9) -split '\s+' | Where-Object { $_ -ne '' })
                    foreach ($id in $ids) { Start-Task -TaskId $id -Attempt 1 }
                } else {
                    Stop-Run -Reason 'next-task'
                }
            }
            5 { }                                                        # 実行中のタスクの完了待ち
            3 {
                Emit "Finished: $($script:CallNext)"
                Write-Output "Next: $($script:CallNext)"
                $script:ExitCode = 0
                $done = $true
            }
            6 {
                Emit "Finished: $($script:CallNext)"
                Write-Output "Next: $($script:CallNext)"
                $script:ExitCode = 0
                $done = $true
            }
            4 { Stop-Run -Reason 'blocked' }
            default { Stop-Run -Reason 'next-task' }
        }
        if ($done) { break }
        $elapsed = [int][Math]::Floor(([DateTime]::UtcNow - $start).TotalSeconds)
        if ($MaxWait -gt 0 -and $elapsed -ge $MaxWait) {
            Write-InFlight
            Write-Output 'Next: wait'
            $script:ExitCode = 2
            break
        }
        Start-Sleep -Seconds $Interval
    }
} catch {
    if ($_.Exception.Message -cne $script:StopMarker) { throw }
} finally {
    Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit $script:ExitCode
