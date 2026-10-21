# state.json のタスクの状態を、許された遷移だけで機械的に更新する(LLM が JSON を手で編集しない)。
# Usage: task-state.ps1 -TaskId <ID> -Action <start|review|done|retry|fail|reset> [-Commit <hash>]
#   start  : pending / in_progress → in_progress(dispatch。中断後の再 dispatch も可)
#   review : in_progress → in_review(子の完了報告を検証した後)
#   done   : in_review → done(-Commit <コミットハッシュ> 必須)
#   retry  : in_review → in_progress、retries + 1(retries が max_fix_retries 以上なら exit 4)
#   fail   : pending 以外 → failed
#   reset  : failed → pending(retries を 0、commit を null に戻す。ユーザー判断でやり直す場合)
# exit: 0=更新した / 1=使い方不備・許されない遷移 / 4=retry の上限超過
# 拒否した場合、state.json は変更しない。
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$TaskId,
    [Parameter(Mandatory = $true, Position = 1)][string]$Action,
    [string]$Commit
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$') { Fail "Invalid TaskId: '$TaskId'" }

# 動作ごとの「遷移元として許される状態」と遷移先
$transitions = @{
    start  = @{ from = @('pending', 'in_progress'); to = 'in_progress' }
    review = @{ from = @('in_progress'); to = 'in_review' }
    done   = @{ from = @('in_review'); to = 'done' }
    retry  = @{ from = @('in_review'); to = 'in_progress' }
    fail   = @{ from = @('in_progress', 'in_review', 'done', 'failed'); to = 'failed' }
    reset  = @{ from = @('failed'); to = 'pending' }
}
# 大文字小文字を区別する(POSIX 版と同じ。ハッシュテーブルの ContainsKey は区別しないため)
if ($transitions.Keys -cnotcontains $Action) {
    Fail "Unknown action '$Action' (expected: start, review, done, retry, fail, reset)"
}
if ($Action -eq 'done') {
    if (-not $Commit) { Fail 'done requires -Commit <hash>' }
    if ($Commit -notmatch '^[0-9a-fA-F]{7,40}$') { Fail "Invalid commit hash: '$Commit'" }
    # git log の %H(小文字)と前方一致で照合するため、小文字に正規化して記録する
    $Commit = $Commit.ToLowerInvariant()
} elseif ($Commit) {
    Fail '-Commit is only valid with done'
}

Set-Location $PSScriptRoot\..\..\..
$statePath = '.agents/workflow/state.json'
$configPath = '.agents/workflow/config.json'
if (-not (Test-Path $statePath)) { Fail "state.json not found: $statePath" }

$state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$task = $state.tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
if (-not $task) { Fail "Task '$TaskId' not found in state.json" }

$rule = $transitions[$Action]
$current = $task.status
if ($rule.from -notcontains $current) {
    Fail "${TaskId}: cannot '$Action' from '$current' (allowed from: $(($rule.from | Sort-Object) -join ', '))"
}

$retries = [int]$task.retries
if ($Action -eq 'retry') {
    $maxRetries = 2
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $cfg.max_fix_retries) { $maxRetries = [int]$cfg.max_fix_retries }
    }
    if ($retries -ge $maxRetries) {
        Fail "${TaskId}: retries ($retries) reached max_fix_retries ($maxRetries); escalate instead of retrying" 4
    }
    $retries++
}

# 読み込んだオブジェクトをその場で更新して書き戻す(未知のフィールドも POSIX 版と同様に保持する)
function Set-Field {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
Set-Field $task 'status' $rule.to
Set-Field $task 'retries' $retries
if ($Action -eq 'done') { Set-Field $task 'commit' $Commit }
if ($Action -eq 'reset') { Set-Field $task 'retries' 0; Set-Field $task 'commit' $null }
Set-Field $state 'updated_at' (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $statePath), ($state | ConvertTo-Json -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))

$suffix = ''
if ($Action -eq 'retry') { $suffix = " (retries $retries)" }
if ($Action -eq 'done') { $suffix = " (commit $Commit)" }
Write-Output "${TaskId}: $current -> $($rule.to)$suffix"
exit 0
