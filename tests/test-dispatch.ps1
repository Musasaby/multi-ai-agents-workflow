# #16: dispatch-run の done マーカーと dispatch-check(PowerShell版)
. "$PSScriptRoot/lib.ps1"

function Set-Child {
    param([string]$Body)
    Write-Utf8File "$script:Proj/child.ps1" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'pwsh -NoProfile -File ./child.ps1 "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt`n"
}

function Get-DoneExit { return (Get-Content "$script:Proj/.agents/workflow/runs/T1-1/done" -Encoding utf8)[0] }

# dispatch-run と同じ形式で guard.sha256 を書き(runs/<run>/prompt.md と管理ファイル)、
# dispatch-run と同じく git-state.ps1 の出力で git-state.txt も書く
function Write-Guard {
    param([string]$Run)
    Push-Location $script:Proj
    $lines = foreach ($f in @(".agents/workflow/runs/$Run/prompt.md", '.agents/workflow/state.json', '.agents/workflow/tasks.md', '.agents/workflow/config.json')) {
        $h = if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() } else { '-' }
        "$h  $f"
    }
    Pop-Location
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/guard.sha256" (($lines -join "`n") + "`n")
    Push-Location $script:Proj
    $gitState = @(& pwsh -NoProfile -File .agents/workflow/scripts/git-state.ps1)
    Pop-Location
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/git-state.txt" (($gitState -join "`n") + "`n")
}

function New-Run {
    param([string]$Exit, [string]$Log, [string]$Run = 'T1-1')
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/prompt.md" "prompt`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/done" "EXIT:$Exit`nEND:2026-01-01T00:00:00+09:00`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/output.log" "$Log`n"
    Write-Guard $Run
}

function Set-Isolate {
    param([string]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.PSObject.Properties.Remove('isolate_xdg')
    if ($Value -ne 'absent') { $cfg.child_agent | Add-Member -NotePropertyName isolate_xdg -NotePropertyValue ($Value -eq 'true') }
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

# T4(#53): idle_timeout_seconds を設定する($Value = 秒)
function Set-IdleTimeout {
    param([string]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.PSObject.Properties.Remove('idle_timeout_seconds')
    $cfg.child_agent | Add-Member -NotePropertyName idle_timeout_seconds -NotePropertyValue ([int]$Value)
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

# T8(#53): 子CLI自身のログファイルのパス(cli_log)を設定する($Value = パス。New-Run の前に呼ぶ)
function Set-CliLog {
    param([string]$Value)
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.PSObject.Properties.Remove('cli_log')
    $cfg.child_agent | Add-Member -NotePropertyName cli_log -NotePropertyValue $Value
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}

function Get-ChildXdg {
    $env:XDG_DATA_HOME = 'C:/caller/xdg-data'
    try { Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1 } finally { Remove-Item Env:XDG_DATA_HOME -ErrorAction SilentlyContinue }
    return [System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log")
}

# T10(#46): 子の環境変数を NAME=<値>(\ は / に置換)で1行ずつ出力する子(既存 Set-Child の pwsh の子)
function Set-EnvChild {
    Set-Child (
        'Write-Output ("TMPDIR=" + ($env:TMPDIR -replace "\\", "/")); ' +
        'Write-Output ("TEMP=" + ($env:TEMP -replace "\\", "/")); ' +
        'Write-Output ("TMP=" + ($env:TMP -replace "\\", "/")); ' +
        'Write-Output ("GIT_CEILING_DIRECTORIES=" + ($env:GIT_CEILING_DIRECTORIES -replace "\\", "/"))'
    )
}

# T18: Python の子(sh 版の set_py_child と同じ構え)を登録する
function Set-PyChild {
    param([string]$Body)
    Write-Utf8File "$script:Proj/child.py" $Body
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.child_agent.command_template = 'python3 ./child.py "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/prompt.md" "prompt`n"
}

# output.log から <変数名>=<値> の行の値を返す(無ければ空文字列)。
# Where-Object で絞り込む(1行だけのとき、配列の -match フィルタがブール値に化けるのを防ぐため)
function Get-ChildEnvValue {
    param([string]$Name)
    $line = ((@((Get-Content "$script:Proj/.agents/workflow/runs/T1-1/output.log" -Encoding utf8 -ErrorAction SilentlyContinue)) | Where-Object { $_ -match "^$Name=" }) | Select-Object -First 1)
    return ("$line" -replace "^$Name=", '')
}

# 値が .agents/workflow/runs/T1-1/tmp で終わる絶対パス(/ または <ドライブ>:/ 始まり)かを確かめる
function Assert-RunTmpPath {
    param([string]$Value, [string]$Message)
    $norm = $Value -replace '\\', '/'
    $ok = ($norm -cmatch '^[A-Za-z]:/.*/\.agents/workflow/runs/T1-1/tmp$') -or ($norm -cmatch '^/.*/\.agents/workflow/runs/T1-1/tmp$')
    Add-Result $ok "$Message (expected / or drive-letter path ending with .agents/workflow/runs/T1-1/tmp, got '$Value')"
}

# 値が .agents/workflow/runs/T1-1 で終わる絶対パス(/ または <ドライブ>:/ 始まり)かを確かめる(GIT_CEILING_DIRECTORIES 用)
function Assert-RunRunPath {
    param([string]$Value, [string]$Message)
    $norm = $Value -replace '\\', '/'
    $ok = ($norm -cmatch '^[A-Za-z]:/.*/\.agents/workflow/runs/T1-1$') -or ($norm -cmatch '^/.*/\.agents/workflow/runs/T1-1$')
    Add-Result $ok "$Message (expected / or drive-letter path ending with .agents/workflow/runs/T1-1, got '$Value')"
}

# 呼び出し元の TMP 系環境変数を実在ディレクトリ($script:Proj/caller-tmp)に差し替えて、
# dispatch-run を同じプロセス内で呼ぶ(test-exitcode.ps1 の Invoke-InProcess と同じ形式)。
# 一時ファイルを作るヘルパー(TempFileName 等)が TEMP を実在パスとして使うため実在ディレクトリにする
# dispatch-run.ps1 直後の呼び出し元の値を $script:CallerEnvAfterRun に保存する
# (ヘルパーの finally で戻す前の値。ケース3で「呼び出し元を書き換えない」の検証に使う)
$script:CallerEnvAfterRun = @{}
function Invoke-RunWithCallerTmp {
    $null = New-Item -ItemType Directory -Force "$script:Proj/caller-tmp"
    $saved = @{}
    foreach ($name in @('TMPDIR', 'TEMP', 'TMP', 'GIT_CEILING_DIRECTORIES')) {
        $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Set-Item -Path "Env:$name" -Value "$script:Proj/caller-tmp"
    }
    Push-Location $script:Proj
    try {
        & "$script:Proj/.agents/workflow/scripts/dispatch-run.ps1" -TaskId T1 -Attempt 1 *> $null
        foreach ($name in @('TMPDIR', 'TEMP', 'TMP', 'GIT_CEILING_DIRECTORIES')) {
            $script:CallerEnvAfterRun[$name] = [System.Environment]::GetEnvironmentVariable($name)
        }
    } finally {
        Pop-Location
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "Env:$name" -Value $saved[$name] }
        }
    }
}

$report = "作業しました`n## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス"

Write-Host "test-dispatch.ps1"

Invoke-TestCase "run: 正常終了はEXIT:0" {
    Set-Child 'Write-Output hello; exit 0'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:0" (Get-DoneExit) "done marker"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log")) "hello" "output.log"
}

Invoke-TestCase "run: 起動時の git 状態を git-state.txt に記録する" {
    Set-Child 'Write-Output hello; exit 0'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    $expected = "$(git -C "$script:Proj" rev-parse HEAD)".Trim()
    $gitStateLines = [System.IO.File]::ReadAllLines("$script:Proj/.agents/workflow/runs/T1-1/git-state.txt")
    Assert-Eq "head $expected" $gitStateLines[0] "git-state.txt first line"
    Assert-Eq 4 $gitStateLines.Count "git-state.txt has 4 lines"
}

Invoke-TestCase "run: 通常の非0は数値のまま" {
    Set-Child 'exit 3'
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:3" (Get-DoneExit) "done marker"
}

Invoke-TestCase "run: isolate_xdg 未指定/false は XDG を引き継ぐ" {
    Set-Child 'Write-Output "DATA=$env:XDG_DATA_HOME"'
    Set-Isolate absent
    Assert-Contains (Get-ChildXdg) "DATA=C:/caller/xdg-data" "absent: caller XDG inherited"
    Set-Isolate false
    Assert-Contains (Get-ChildXdg) "DATA=C:/caller/xdg-data" "false: caller XDG inherited"
}

Invoke-TestCase "run: isolate_xdg true は XDG を切り替える" {
    Set-Child 'Write-Output "DATA=$env:XDG_DATA_HOME"'
    Set-Isolate true
    Assert-Contains (Get-ChildXdg) "DATA=.agents/workflow/.config" "true: XDG isolated"
}

# T10(#46): sh 版(test-dispatch.sh)と同じ名前の3ケース
Invoke-TestCase "run: 子の TMPDIR/TEMP/TMP は runs/<ID>-<試行>/tmp を指す" {
    Set-EnvChild
    Invoke-RunWithCallerTmp
    Assert-RunTmpPath (Get-ChildEnvValue 'TMPDIR') "child TMPDIR points to runs/T1-1/tmp"
    Assert-RunTmpPath (Get-ChildEnvValue 'TEMP') "child TEMP points to runs/T1-1/tmp"
    Assert-RunTmpPath (Get-ChildEnvValue 'TMP') "child TMP points to runs/T1-1/tmp"
    Add-Result (Test-Path -Path "$script:Proj/.agents/workflow/runs/T1-1/tmp" -PathType Container) "runs/T1-1/tmp directory exists"
}

Invoke-TestCase "run: 子の GIT_CEILING_DIRECTORIES は runs/<ID>-<試行> を指す" {
    Set-EnvChild
    Invoke-RunWithCallerTmp
    Assert-RunRunPath (Get-ChildEnvValue 'GIT_CEILING_DIRECTORIES') "child GIT_CEILING_DIRECTORIES points to runs/T1-1"
}

# T18: Python の子が TMPDIR 直下で git rev-parse を実行し、本物のリポジトリが見つからない(returncode 非0)ことを確かめる
Invoke-TestCase "run: 子が TMPDIR 直下で実行した git は本物のリポジトリを見つけない" {
    Set-PyChild @'
import os, subprocess
r = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=os.environ["TMPDIR"], capture_output=True)
print("GITRC=" + str(r.returncode))
'@
    Invoke-RunWithCallerTmp
    $rc = (Get-ChildEnvValue 'GITRC').Trim()
    Add-Result ($rc -cmatch '^\d+$' -and $rc -ne '0') "git under TMPDIR must not find the caller repo (GITRC='$rc')"
}

# T3/T4(#53): ログが idle_timeout_seconds 更新されなければ子を止めて EXIT:idle-timeout
Invoke-TestCase "run: ログが idle_timeout_seconds 更新されなければ子を止めて EXIT:idle-timeout" {
    Set-Child 'Write-Output start; Start-Sleep 30'
    Set-IdleTimeout 2
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    $sw.Stop()
    Add-Result ($sw.Elapsed.TotalSeconds -lt 20) "finished in under 20 seconds (elapsed=$([int]$sw.Elapsed.TotalSeconds))"
    Assert-Eq "EXIT:idle-timeout" (Get-DoneExit) "done marker"
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/idle-timeout" "idle-timeout file"
}

# T3/T4(#53): ログが更新され続ければ idle_timeout_seconds で止めない
Invoke-TestCase "run: ログが更新され続ければ idle_timeout_seconds で止めない" {
    Set-Child '1..5 | ForEach-Object { Write-Output "tick $_"; Start-Sleep 1 }'
    Set-IdleTimeout 3
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-Eq "EXIT:0" (Get-DoneExit) "done marker"
    Assert-Contains ([System.IO.File]::ReadAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log")) "tick 5" "output.log"
    Assert-FileAbsent "$script:Proj/.agents/workflow/runs/T1-1/idle-timeout" "no idle-timeout file"
}

Invoke-TestCase "run: 呼び出し元の TMPDIR/TEMP/TMP を書き換えない" {
    Set-EnvChild
    Invoke-RunWithCallerTmp
    # dispatch-run.ps1 呼び出し直後の値(ヘルパー finally で戻す前)が、
    # 呼び出し元で設定した値のまま(= dispatch-run.ps1 が finally で戻せている)ことを確かめる
    foreach ($name in @('TMPDIR', 'TEMP', 'TMP', 'GIT_CEILING_DIRECTORIES')) {
        $after = $script:CallerEnvAfterRun[$name]
        Add-Result ("$after" -ceq "$script:Proj/caller-tmp") "caller $name unchanged right after dispatch-run (expected '$script:Proj/caller-tmp', got '$after')"
    }
}

Invoke-TestCase "check: 正常" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "kind: ok" "kind"
    Assert-Contains $script:Out "a.txt" "git status shown"
    Assert-Contains $script:Out "Completion report: found" "report found"
}

Invoke-TestCase "check: signalはexit 4" {
    New-Run "signal:15" "step 67 ..."
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: signal" "kind"
    Assert-Contains $script:Out "step 67" "log tail shown"
}

Invoke-TestCase "check: EXIT:idle-timeout は abnormal-exit(exit 4)" {
    New-Run idle-timeout "> build · glm-5.3"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: idle-timeout" "kind"
    Assert-Contains $script:Out "Verdict: abnormal-exit" "verdict"
}

Invoke-TestCase "check: 非0はexit 4" {
    New-Run 3 $report
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: nonzero" "kind"
}

Invoke-TestCase "check: crashedはexit 4" {
    New-Run "crashed:boom" ""
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 4 $script:Code "exit code"
    Assert-Contains $script:Out "kind: crashed" "kind"
}

Invoke-TestCase "check: 完了報告なしはexit 5" {
    New-Run 0 "did something but no report"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code"
    Assert-Contains $script:Out "Completion report: missing" "report missing"
}

# #50: 最後のツール実行の後に何も出力していない(推論だけで出力トークン上限に達した)場合の理由
Invoke-TestCase "check: 最後のツール実行の後に出力が無ければ理由に書く(exit 5)" {
    $esc = [char]27
    New-Run 0 "> build · glm-5.3`n`n$esc[0m→ $esc[0mRead a.txt`n$esc[0m→ $esc[0mRead b.txt"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "no output after the last tool call" "reason"
}

# ツール実行の後に本文があれば、理由を付けない(単なる報告漏れとして扱う)
Invoke-TestCase "check: ツール実行の後に本文があれば理由を付けない(exit 5)" {
    $esc = [char]27
    New-Run 0 "$esc[0m→ $esc[0mRead a.txt`n考え中です"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Completion report: missing" "report missing"
    Assert-NotContains $script:Out "no output after the last tool call" "reason absent"
}

Invoke-TestCase "check: doneなしはexit 1" {
    $null = New-Item -ItemType Directory -Force "$script:Proj/.agents/workflow/runs/T1-1"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 1 $script:Code "exit code"
}

Invoke-TestCase "check: BOM付きdone" {
    New-Run 0 $report
    [System.IO.File]::WriteAllText("$script:Proj/.agents/workflow/runs/T1-1/done", "EXIT:0`r`nEND:x`r`n", [System.Text.UTF8Encoding]::new($true))
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "BOM-prefixed done marker parsed: $($script:Out)"
}

$esc = [char]27

# #35: 子がテンプレートを cat しただけの `## 完了報告` に一致させない
Invoke-TestCase "check: 完了報告の後にツール実行が続けば無効(exit 5)" {
    New-Run 0 "$esc[0m`$ $esc[0mcat dispatch-pr-prompt-template.md`n## 完了報告`n- PR URL: <作成した PR の URL>`n$esc[0m→ $esc[0mRead README.md`n$esc[0m`$ $esc[0mls"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "invalid (tool activity after the report" "reason"
}

Invoke-TestCase "check: テンプレートのままの完了報告は無効(exit 5)" {
    New-Run 0 "## 完了報告`n- 変更ファイル: <一覧>`n- テスト結果: <パス/失敗の件数>"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "template placeholder" "reason"
}

Invoke-TestCase "check: 必須項目が無い完了報告は無効(exit 5)" {
    New-Run 0 "## 完了報告`n- 変更ファイル: a.txt`n- 備考: なし"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 5 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "missing field: テスト結果" "reason"
}

# #55: 必須項目行の区切りは全角コロンでも有効
Invoke-TestCase "check: 全角コロンの必須項目も有効(exit 0)" {
    New-Run 0 "## 完了報告`n- 変更ファイル：`n  - a.txt`n- テストコマンド: bash tests/test.sh`n- テスト結果： 全件パス"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Completion report: found" "report"
}

# #55: PR URL 行の区切りが全角コロンでも有効
Invoke-TestCase "check: 全角コロンのPR URLも有効(exit 0)" {
    New-Run 0 "## 完了報告`n- PR URL： https://github.com/o/r/pull/1" 'pr-1-1'
    Invoke-Script dispatch-check.ps1 -TaskId pr-1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Completion report: found" "report"
}

Invoke-TestCase "check: 箇条書きの値・CRLF・ANSIを含む完了報告は有効" {
    New-Run 0 "$esc[0m`$ $esc[0mbash tests/test.sh`r`n## 完了報告`r`n- 変更ファイル:`r`n  - ``a.txt```r`n- テスト結果: 全件パス`r"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "check: 権限拒否はexit 6" {
    New-Run 0 "! permission requested: external_directory (/tmp/*); auto-rejecting`n✗ cd /tmp && git init failed`nError: The user rejected permission to use this specific tool call."
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Permission denied: yes" "flag"
    Assert-Contains $script:Out "auto-rejecting" "denied line shown"
}

Invoke-TestCase "check: 変更0件はexit 7" {
    New-Run 0 $report
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 7 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Changes: 0" "changes"
}

Invoke-TestCase "check: PR作成のrunは変更0件でも正常" {
    New-Run 0 "## 完了報告`n- PR URL: https://github.com/o/r/pull/1`n- タイトル: t" 'pr-1-1'
    Invoke-Script dispatch-check.ps1 -TaskId pr-1 -Attempt 1
    Assert-Eq 0 $script:Code "pr run is not checked for changes: $($script:Out)"
}

# #34: 管理ファイルの変更・削除を検知する
Invoke-TestCase "check: state.jsonの変更はexit 8" {
    Set-State 'T1:in_progress'
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Set-State 'T1:done'
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "changed: .agents/workflow/state.json" "issue"
}

Invoke-TestCase "check: prompt.mdの削除はexit 8" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/prompt.md"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "deleted: .agents/workflow/runs/T1-1/prompt.md" "issue"
}

Invoke-TestCase "check: guard.sha256が無ければexit 8" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "guard.sha256 not found" "issue"
}

Invoke-TestCase "check: git-state.txt が無ければ exit 8" {
    New-Run 0 $report
    Remove-Item "$script:Proj/.agents/workflow/runs/T1-1/git-state.txt"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Guard: NG" "guard ng"
    Assert-Contains $script:Out "git-state.txt not found" "issue"
}

Invoke-TestCase "check: output.logの切り詰めはexit 8" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" ("`0`0`0" + $report + "`n")
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "truncated during the run" "issue"
}

# #44: 切り詰められた output.log の末尾表示から NUL を除く(sh 版と揃える)
Invoke-TestCase "check: 切り詰められたoutput.logの表示にNULを含めない" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/output.log" ("`0`0`0" + $report + "`n")
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-NotContains $script:Out ([string][char]0) "no NUL in output"
    Assert-Contains $script:Out "テスト結果: 全件パス" "report body shown"
}

# dispatch-run が書いた guard.sha256 を dispatch-check が検証する(結合)
Invoke-TestCase "run+check: 子が正常に完了すればexit 0" {
    Set-State 'T1:in_progress'
    Set-Child "Set-Content -Path a.txt -Value x; Write-Output '## 完了報告'; Write-Output '- 変更ファイル: a.txt'; Write-Output '- テスト結果: 全件パス'"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Assert-FileExists "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" "guard written"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "run+check: 子がprompt.mdを消せばexit 8" {
    Set-Child "Remove-Item .agents/workflow/runs/T1-1/prompt.md; Set-Content -Path a.txt -Value x; Write-Output '## 完了報告'; Write-Output '- 変更ファイル: a.txt'; Write-Output '- テスト結果: 全件パス'"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
}

# T8: 子が本物のリポジトリの git 状態(HEAD・ブランチ・参照・設定)を変えれば exit 8
Invoke-TestCase "run+check: 子がコミットすれば exit 8(git changed: head)" {
    Set-State 'T1:in_progress'
    Set-Child "git commit -q --allow-empty -m x"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Guard: NG" "guard ng"
    Assert-Contains $script:Out "git changed: head" "issue"
}

Invoke-TestCase "run+check: 子が git config を変えれば exit 8(git changed: config)" {
    Set-State 'T1:in_progress'
    Set-Child "git config user.name x"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Guard: NG" "guard ng"
    Assert-Contains $script:Out "git changed: config" "issue"
}

Invoke-TestCase "run+check: 子がブランチを作れば exit 8(git changed: refs)" {
    Set-State 'T1:in_progress'
    Set-Child "git branch x"
    Invoke-Script dispatch-run.ps1 -TaskId T1 -Attempt 1
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 8 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Guard: NG" "guard ng"
    Assert-Contains $script:Out "git changed: refs" "issue"
}

Invoke-TestCase "check: 報告本文の→や$で始まる行は有効" {
    New-Run 0 "## 完了報告`n- 変更ファイル: a.txt`n- テスト結果: 全件パス`n`$ npm test`n→ 要確認"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
}

Invoke-TestCase "check: 表示されたソース中の権限拒否の文字列には反応しない" {
    New-Run 0 "$esc[0m`$ $esc[0mgrep -n auto-rejecting tests/test-dispatch.sh`n12:    make_run 0 `"! permission requested: external_directory (/tmp/*); auto-rejecting`nError: The user rejected permission to use this specific tool call.`"`n$report"
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Permission denied: no" "flag"
}

Invoke-TestCase "check: 色付きの権限拒否行もexit 6" {
    New-Run 0 "$esc[91m! permission requested: external_directory (/tmp/*); auto-rejecting$esc[0m"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "colored permission line detected: $($script:Out)"
}

# T13(#46): sh 版(test-dispatch.sh)と同じ名前の4ケース
Invoke-TestCase "check: ツール実行行の /tmp への書き込みは exit 6(outside-access)" {
    New-Run 0 ($report + "`n" + "$esc[0m`$ $esc[0mbash -c `"bash tests/x.sh > /tmp/dsp-ps1.log`"")
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Verdict: outside-access" "verdict"
    Assert-Contains $script:Out "Outside access: yes" "flag"
    Assert-Contains $script:Out "/tmp/dsp-ps1.log" "line shown"
}

Invoke-TestCase "check: runs/<ID>/tmp 配下へのアクセスは検出しない" {
    New-Run 0 ("$esc[0m`$ $esc[0mbash tests/x.sh > .agents/workflow/runs/T1-1/tmp/out.log`n$esc[0m`$ $esc[0mecho `$TMPDIR`n" + $report)
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Outside access: no" "flag"
}

Invoke-TestCase "check: ツールの出力中の /tmp には反応しない" {
    New-Run 0 ("PROJ=/tmp/tmp.abc`n[tool_result] /tmp/x`n" + $report)
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Outside access: no" "flag"
}

Invoke-TestCase "check: 権限拒否とプロジェクト外アクセスが両方あれば permission-denied" {
    New-Run 0 ("! permission requested: external_directory (/tmp/*); auto-rejecting`n$esc[0m`$ $esc[0mbash -c `"bash tests/x.sh > /tmp/dsp-ps1.log`"")
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Verdict: permission-denied" "verdict"
    Assert-Contains $script:Out "Permission denied: yes" "flag"
    Assert-Contains $script:Out "Outside access: yes" "flag"
}

Invoke-TestCase "check: 大文字の /TMP は検出しない" {
    # /tmp の参照は大文字小文字を区別する(/TMP は検出しない)
    New-Run 0 ("$esc[0m`$ $esc[0mls /TMP/x`n" + $report)
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Outside access: no" "flag"
}

Invoke-TestCase "check: リダイレクト直後の ~/ は exit 6" {
    # リダイレクト(`>`)の直後の ~/ もホームディレクトリの参照とみなす
    New-Run 0 ($report + "`n" + "$esc[0m`$ $esc[0mbash tests/x.sh >~/out.log")
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Verdict: outside-access" "verdict"
    Assert-Contains $script:Out "~/out.log" "line shown"
}

# T14(#46): sh 版(test-dispatch.sh)と同じ名前の3ケース
Invoke-TestCase "check: tool_use 行のホームディレクトリ参照は exit 6" {
    New-Run 0 ($report + "`n" + '[tool_use] bash: {"command": "cat ~/x.log"}')
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Verdict: outside-access" "verdict"
    Assert-Contains $script:Out "Outside access: yes" "flag"
    Assert-Contains $script:Out "~/x.log" "line shown"
}

Invoke-TestCase "check: 色付きツール実行行の USERPROFILE・AppData の Temp 参照は exit 6" {
    New-Run 0 ("$esc[0m`$ $esc[0mGet-Content `$env:USERPROFILE\x.log`n" + $report) 'T1-2'
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 2
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Verdict: outside-access" "verdict"
    Assert-Contains $script:Out "Outside access: yes" "flag"
    New-Run 0 ("$esc[0m`$ $esc[0mls C:\Users\u\AppData\Local\Temp`n" + $report) 'T1-3'
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 3
    Assert-Eq 6 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Verdict: outside-access" "verdict"
    Assert-Contains $script:Out "Outside access: yes" "flag"
}

Invoke-TestCase "check: HOMEBREW_PREFIX や env:TEMP は検出しない" {
    New-Run 0 ("$esc[0m`$ $esc[0mecho `$HOMEBREW_PREFIX`n$esc[0m`$ $esc[0mGet-ChildItem `$env:TEMP`n" + $report)
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Outside access: no" "flag"
}

# T8(#53): sh 版(test-dispatch.sh)と同じ名前の3ケース
# (cli_log は guard.sha256 の対象なので New-Run の前に設定する)
Invoke-TestCase "check: CLI ログの利用上限エラーを Provider error: yes にする" {
    Set-CliLog "$script:Proj/cli.log"
    Write-Utf8File "$script:Proj/cli.log" ('timestamp=2026-10-17T03:07:49.892Z level=INFO message="ok"' + "`n" + 'timestamp=2026-10-17T03:07:50.429Z level=ERROR message="stream error" error.error="AI_APICallError: Go usage limit exceeded"' + "`n")
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Go usage limit exceeded" "error line shown"
    Assert-Contains $script:Out "Provider error: yes" "provider flag"
    Assert-NotContains $script:Out "level=INFO" "info line not shown"
}

Invoke-TestCase "check: CLI ログの ERROR がプロバイダー由来でなければ Provider error: no" {
    Set-CliLog "$script:Proj/cli.log"
    Write-Utf8File "$script:Proj/cli.log" ('timestamp=2026-10-17T03:07:50.429Z level=ERROR message="tool failed"' + "`n")
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out 'message="tool failed"' "error line shown"
    Assert-Contains $script:Out "Provider error: no" "provider flag"
}

Invoke-TestCase "check: cli_log が未設定なら CLI log: (not configured)" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "CLI log: (not configured)" "not configured"
    Assert-Contains $script:Out "Provider error: unknown" "provider flag"
}

Invoke-TestCase "check: UTF-16LEのoutput.log(Windows PowerShell 5.1)を読める" {
    New-Run 0 $report
    Write-Utf8File "$script:Proj/a.txt" "x`n"
    [System.IO.File]::WriteAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log", "$report`r`n", [System.Text.UnicodeEncoding]::new($false, $true))
    Invoke-Script dispatch-check.ps1 -TaskId T1 -Attempt 1
    Assert-Eq 0 $script:Code "exit code: $($script:Out)"
    Assert-Contains $script:Out "Guard: ok" "UTF-16 is not treated as truncated"
}

Show-Summary
