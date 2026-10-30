param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
. "$PSScriptRoot/childprofile.ps1"
# パスや埋め込みに使うため、タスクIDと試行回数の形式を検証する
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt: '$TaskId' '$Attempt'")
    exit 1
}
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$runDir = ".agents/workflow/runs/$TaskId-$Attempt"
$null = New-Item -ItemType Directory -Force $runDir
$logPath = "$runDir/output.log"
$jsonlPath = "$runDir/output.jsonl"
$donePath = "$runDir/done"
# ログの無更新監視で子を止めたときに記録するファイル(#53)
$idlePath = "$runDir/idle-timeout"
Remove-Item -Force -ErrorAction SilentlyContinue $donePath, $idlePath
$promptPath = "$runDir/prompt.md"
# 子が管理ファイルを変更・削除していないかを dispatch-check が確かめられるよう、起動時の
# SHA-256 を記録する(存在しないファイルは "-")。形式は sha256sum と同じ "<hash>  <path>"
# worktree.txt があるとき(dispatch-worktree create 済み)は、子を worktree の中で動かす。
# 出力ファイル(output.log・done 等)は本体の runs/ に置いたまま、tmp と ceiling だけ worktree 側にする
$wtPath = ''
$wtBranch = ''
if (Test-Path -LiteralPath "$runDir/worktree.txt") {
    foreach ($l in ([System.IO.File]::ReadAllText((Resolve-Path "$runDir/worktree.txt"), [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        if (-not $wtPath -and $l.StartsWith('path ')) { $wtPath = $l.Substring(5) }
        elseif (-not $wtBranch -and $l.StartsWith('branch ')) { $wtBranch = $l.Substring(7) }
    }
}
$guardState = '.agents/workflow/state.json'
$guardTasks = '.agents/workflow/tasks.md'
if ($wtPath) {
    # worktree の run では、子が触れる worktree 側のコピーを守る
    $guardState = "$runDir/worktree/.agents/workflow/state.json"
    $guardTasks = "$runDir/worktree/.agents/workflow/tasks.md"
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
$guardFiles = @($promptPath, $guardState, $guardTasks, '.agents/workflow/config.json', '.agents/workflow/child-profiles.json')
# worktree の run は本体の tasks.md も守る(state.json は親が並列中に更新するため、自分のタスクの欄だけを state-entry.txt で守る)
if ($wtPath) { $guardFiles += '.agents/workflow/tasks.md' }
$guardLines = foreach ($f in $guardFiles) {
    $h = if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() } else { '-' }
    "$h  $f"
}
[System.IO.File]::WriteAllText((Join-Path (Get-Location) "$runDir/guard.sha256"), (($guardLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
if ($wtPath) {
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) "$runDir/state-entry.txt"), ((Get-StateEntryText $TaskId) + "`n"), [System.Text.UTF8Encoding]::new($false))
    # 全タスクの {id, status, retries, commit} も記録する(dispatch-check が、ほかのタスクの欄の不正な変更を検知する)
    $allTasks = @()
    try {
        $stAll = Get-Content -LiteralPath '.agents/workflow/state.json' -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $allTasks = @(foreach ($e in @($stAll.tasks)) { [ordered]@{ id = "$($e.id)"; status = "$($e.status)"; retries = [int]$e.retries; commit = $e.commit } })
    } catch {}
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) "$runDir/state-tasks.json"), ((ConvertTo-Json -InputObject $allTasks -Depth 5 -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
}
# 起動時の git 状態(HEAD・ブランチ・参照・設定)を git-state.txt に記録する。dispatch-check が
# 実行後の状態と比べて、子がリポジトリのどこを変えたかを特定する(失敗しても起動は止めない)
if ($wtPath) {
    # 親の作業ブランチは本体で取る(detached なら '-')
    $parentRef = "$(& git symbolic-ref -q HEAD 2> $null)".Trim()
    if (-not $parentRef) { $parentRef = '-' }
    # 親の作業ブランチの参照名と値を記録する(dispatch-check が巻き戻しを検知する)
    $parentSha = "$(& git rev-parse --verify -q HEAD 2> $null)".Trim()
    if (-not $parentSha) { $parentSha = '-' }
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) "$runDir/parent-head.txt"), "$parentRef`n$parentSha`n", [System.Text.UTF8Encoding]::new($false))
    # 実行中の自分以外のタスクの run のブランチだけを、refs の比較から外す
    $otherRuns = Get-OtherRunIds $TaskId
    Push-Location -LiteralPath $wtPath
    try { $gitState = & pwsh -NoProfile -File "$PSScriptRoot/git-state.ps1" -Run $wtBranch -Parent $parentRef -OtherRuns $otherRuns } finally { Pop-Location }
} else {
    $gitState = & pwsh -NoProfile -File "$PSScriptRoot/git-state.ps1"
}
[System.IO.File]::WriteAllText((Join-Path (Get-Location) "$runDir/git-state.txt"), (($gitState -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
$prompt = Get-Content $promptPath -Raw
$config = Get-Content ".agents/workflow/config.json" -Raw | ConvertFrom-Json
# child_agent.isolate_xdg が true のときだけ、子CLIの設定・データの置き場所をプロジェクト内に切り替える
# (sandbox で ~/.config 等に書けない環境向け)。既定(未指定・false)は呼び出し元の XDG をそのまま使う。
# 切り替えると ~/.local/share/<CLI>/auth.json 等の認証情報が見えなくなる点に注意。
if ($config.child_agent.isolate_xdg -eq $true) {
    # worktree の run では cwd が変わるので絶対パスにする
    $xdgDir = if ($wtPath) { Join-Path (Get-Location).Path ".agents/workflow/.config" } else { ".agents/workflow/.config" }
    $env:XDG_CONFIG_HOME = $xdgDir
    $env:XDG_DATA_HOME = $xdgDir
}

function Split-CommandLine {
    param([string]$cmd)
    $tokens = @()
    $current = ""
    $inQuotes = $false
    for ($i = 0; $i -lt $cmd.Length; $i++) {
        $c = $cmd[$i]
        if ($c -eq '"') {
            $inQuotes = !$inQuotes
        } elseif ($c -eq ' ' -and !$inQuotes) {
            if ($current -ne "") { $tokens += $current; $current = "" }
        } else {
            $current += $c
        }
    }
    if ($current -ne "") { $tokens += $current }
    return $tokens
}

# ファイル編集ツールの本文(書き込む内容)は [tool_use] 行から外す。本文に書かれたパスの文字列を
# dispatch-check が誤検知するため。全文は output.jsonl に残る
$script:FileEditTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
$script:FileEditBodyKeys = @('old_string', 'new_string', 'content', 'edits', 'new_source')

function ConvertTo-HumanLine {
    param($obj)
    switch ($obj.type) {
        'assistant' {
            $lines = @()
            foreach ($block in $obj.message.content) {
                switch ($block.type) {
                    'text' { $lines += $block.text }
                    'tool_use' {
                        $toolInput = $block.input
                        if (($script:FileEditTools -ccontains $block.name) -and ($toolInput -is [System.Management.Automation.PSCustomObject])) {
                            $toolInput = $toolInput | Select-Object -Property * -ExcludeProperty $script:FileEditBodyKeys
                        }
                        $inputJson = ($toolInput | ConvertTo-Json -Compress -Depth 5)
                        if ($inputJson.Length -gt 300) { $inputJson = $inputJson.Substring(0, 300) + "...(truncated)" }
                        $lines += "[tool_use] $($block.name): $inputJson"
                    }
                    default { $lines += "[assistant:$($block.type)]" }
                }
            }
            return ($lines -join "`n")
        }
        'user' {
            $lines = @()
            foreach ($block in $obj.message.content) {
                if ($block.type -eq 'tool_result') {
                    $content = $block.content
                    if ($content -is [System.Array]) {
                        $text = ($content | ForEach-Object { $_.text }) -join "`n"
                    } else {
                        $text = "$content"
                    }
                    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + "...(truncated)" }
                    $lines += "[tool_result] $text"
                }
            }
            return ($lines -join "`n")
        }
        'result' {
            return "[result] exit_subtype=$($obj.subtype) result=$($obj.result)"
        }
        default {
            $compact = ($obj | ConvertTo-Json -Compress -Depth 5)
            if ($compact.Length -gt 300) { $compact = $compact.Substring(0, 300) + "...(truncated)" }
            return "[$($obj.type)] $compact"
        }
    }
}

# 子の一時ファイルをプロジェクト内(runs/<ID>-<試行>/tmp/)に置かせ、そこで実行された git が
# 本物のリポジトリにたどり着かないようにする(#46)。git は ceiling と同じディレクトリが
# カレントのときは探索を止めないため、tmp/ の親(runs/<ID>-<試行>/)を上限にする
$childBase = if ($wtPath) { Join-Path $wtPath $runDir } else { Join-Path (Get-Location).Path $runDir }
$childTmp = Join-Path $childBase "tmp"
$null = New-Item -ItemType Directory -Force $childTmp
$childCeiling = $childBase
# 子の起動中だけ TEMP 系環境変数を差し替えるため、元の値を保存してから設定する
# 同じプロセス内で & dispatch-run.ps1 と呼ばれたとき(tests/test-exitcode.ps1 等)に呼び出し元に書き換えが
# 残らないよう、finally で戻す(catch の exit 1 でも実行される)
$savedEnv = @{}
foreach ($name in @('TMPDIR', 'TEMP', 'TMP', 'GIT_CEILING_DIRECTORIES')) {
    $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
    $value = if ($name -eq 'GIT_CEILING_DIRECTORIES') { $childCeiling } else { $childTmp }
    [System.Environment]::SetEnvironmentVariable($name, $value)
}

$watchdog = $null
try {
    # ログ(output.log)が idle_timeout_seconds 更新されなければ子を止め、idle-timeout ファイルに記録する(#53)。
    # thread ジョブ内で 1 秒ごとにログの更新時刻を見て、このプロセスの子(CLI)を孫プロセスごと止める(Kill($true))
    $idleTimeout = [double]($config.child_agent.idle_timeout_seconds)
    if ($idleTimeout -gt 0) {
        $watchdog = Start-ThreadJob -ArgumentList $PID, (Join-Path (Get-Location) $logPath), (Join-Path (Get-Location) $idlePath), $idleTimeout -ScriptBlock {
            param($ParentPid, $LogPath, $MarkerPath, $IdleSeconds)
            $start = Get-Date
            while ($true) {
                Start-Sleep -Seconds 1
                $last = $start
                if (Test-Path -LiteralPath $LogPath) {
                    $t = (Get-Item -LiteralPath $LogPath).LastWriteTime
                    if ($t -gt $last) { $last = $t }
                }
                if (((Get-Date) - $last).TotalSeconds -ge $IdleSeconds) {
                    Set-Content -LiteralPath $MarkerPath -Value ([int]$IdleSeconds) -Encoding utf8
                    Get-Process | Where-Object { $_.Parent -and $_.Parent.Id -eq $ParentPid } | ForEach-Object { $_.Kill($true) }
                    break
                }
            }
        }
    }
    try {
        $childProfile = Get-ChildProfile -Root (Get-Location).Path
    } catch {
        [System.IO.File]::WriteAllText((Join-Path (Get-Location) $logPath), "Child profile error: $($_.Exception.Message)`n", [System.Text.UTF8Encoding]::new($false))
        $endTime = (Get-Date).ToString("o")
        "EXIT:1`nEND:$endTime" | Out-File -Encoding utf8 $donePath
        exit 0
    }
    $template = [string]$config.child_agent.command_template
    $tokens = Split-CommandLine $template
    $isStreamJson = $childProfile.OutputFormat -eq 'claude-stream-json'
    $promptFile = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $promptPath)).Replace('\', '/')
    # {prompt_file}・{prompt} のどちらも無いテンプレートは、プロンプトを stdin で渡す
    $useStdin = -not ($template.Contains('{prompt_file}') -or $template.Contains('{prompt}'))
    $argList = @()
    foreach ($token in $tokens) {
        $arg = $token
        if ($arg.Length -ge 2 -and $arg[0] -eq '"' -and $arg[-1] -eq '"') {
            $arg = $arg.Substring(1, $arg.Length - 2)
        }
        $arg = $arg.Replace("{prompt_file}", $promptFile).Replace("{prompt}", $prompt)
        $argList += $arg
    }
    $exe = $argList[0]
    $rest = @(if ($argList.Count -gt 1) { $argList[1..($argList.Count - 1)] })

    if ($isStreamJson) {
        Remove-Item -Force -ErrorAction SilentlyContinue $jsonlPath, $logPath

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        foreach ($a in $rest) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        if ($wtPath) { $psi.WorkingDirectory = $wtPath }
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        if ($useStdin) { $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false) }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $errAction = {
            $line = $Event.SourceEventArgs.Data
            if ($null -ne $line) {
                Add-Content -Path $Event.MessageData -Value $line -Encoding utf8
            }
        }
        $errJob = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errAction -MessageData $logPath

        $stdinJob = $null
        try {
            $proc.Start() | Out-Null
            $proc.BeginErrorReadLine()
            if ($useStdin) {
                # 子が stdin を読み切る前に stderr / stdout へ大量に書いても止まらないよう、別スレッドで書き込む
                $stdinJob = Start-ThreadJob -ArgumentList $proc.StandardInput, $prompt -ScriptBlock {
                    param($Writer, $Text)
                    try { $Writer.Write($Text) } catch { } finally { try { $Writer.Close() } catch { } }
                }
            } else {
                $proc.StandardInput.Close()
            }

            while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
                Add-Content -Path $jsonlPath -Value $line -Encoding utf8
                $human = $null
                try {
                    $obj = $line | ConvertFrom-Json
                    $human = ConvertTo-HumanLine $obj
                } catch {
                    $human = $line
                }
                if ($human) { Add-Content -Path $logPath -Value $human -Encoding utf8 }
            }
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
        } finally {
            if ($stdinJob) {
                Wait-Job $stdinJob | Out-Null
                Remove-Job $stdinJob -Force -ErrorAction SilentlyContinue
            }
            Unregister-Event -SourceIdentifier $errJob.Name -ErrorAction SilentlyContinue
            Remove-Job -Id $errJob.Id -Force -ErrorAction SilentlyContinue
        }
    } else {
        $stdinText = if ($useStdin) { $prompt } else { $null }
        # cwd を変えるので、ログは絶対パスで指定する
        $logFull = Join-Path (Get-Location).Path $logPath
        if ($wtPath) { Push-Location -LiteralPath $wtPath }
        try {
            if ($rest.Count -gt 0) {
                $stdinText | & $exe @rest *> $logFull
            } else {
                $stdinText | & $exe *> $logFull
            }
        } finally {
            if ($wtPath) { Pop-Location }
        }
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    # シグナル死(監視で止めた子は非0で終わる)より idle-timeout を優先する(idle-timeout ファイルは記録として残す)
    if (Test-Path -LiteralPath $idlePath -PathType Leaf) { $exitCode = 'idle-timeout' }
    $endTime = (Get-Date).ToString("o")
    "EXIT:$exitCode`nEND:$endTime" | Out-File -Encoding utf8 $donePath
} catch {
    $endTime = (Get-Date).ToString("o")
    "EXIT:crashed:$($_.Exception.Message)`nEND:$endTime" | Out-File -Encoding utf8 $donePath
    # ラッパー自体の異常終了(子の終了コードは done マーカーに記録済み)
    exit 1
} finally {
    # 子が先に終わったときは監視スレッドジョブを止める
    if ($watchdog) {
        Stop-Job $watchdog -ErrorAction SilentlyContinue
        Remove-Job $watchdog -Force -ErrorAction SilentlyContinue
    }
    # 子の起動前に保存した TEMP 系環境変数の値に戻す(元が無ければ変数自体を消す)
    foreach ($name in $savedEnv.Keys) {
        if ($null -eq $savedEnv[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$name" -Value $savedEnv[$name]
        }
    }
}
# 子の終了コードは done マーカーに記録する。ラッパー自体は正常に終わったので 0 を返す
# (exit を呼ばないと、PowerShell セッション内で直接呼んだときに $LASTEXITCODE が更新されない)
exit 0
