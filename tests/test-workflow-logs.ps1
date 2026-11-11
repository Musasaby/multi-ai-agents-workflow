# workflow-logs.ps1(複数 run のログを1つの画面に流す)
. "$PSScriptRoot/lib.ps1"

# 子を起動せずに run ディレクトリを作る($Exit が空なら done 無し)
function New-LogRun {
    param([string]$Run, [string]$Log, [string]$Exit = '')
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/guard.sha256" ''
    Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/output.log" "$Log`n"
    if ($Exit -ne '') {
        Write-Utf8File "$script:Proj/.agents/workflow/runs/$Run/done" "EXIT:$Exit`nEND:2026-01-01T00:00:00+09:00`n"
    }
}

# $Text のうち $Needle を含む最初の行を返す(columns の行の並びを見るため)
function Get-FirstLineMatching {
    param([string]$Text, [string]$Needle)
    foreach ($line in ($Text -split "`n")) {
        if ($line.Contains($Needle)) { return $line }
    }
    return ''
}

# 1 行の表示幅(全角 2 桁。ANSI エスケープは除く。テストで使う日本語の範囲だけを判定する)
function Get-TestDisplayWidth {
    param([string]$Text)
    $Text = [regex]::Replace($Text, '\x1b\[[0-9;?]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)', '')
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Get-MaxLineWidth {
    param([string]$Text)
    $m = 0
    foreach ($line in ($Text -split "`n")) {
        $w = Get-TestDisplayWidth $line
        if ($w -gt $m) { $m = $w }
    }
    return $m
}

Write-Host "test-workflow-logs.ps1"

Invoke-TestCase "logs: -Once は実行中の run だけを接頭辞付きで出す" {
    New-LogRun 'T1-1' "t1 line a`nt1 line b"
    New-LogRun 'T2-1' 't2 line a'
    New-LogRun 'T3-1' 't3 line a' '0'
    Write-Utf8File "$script:Proj/.agents/workflow/runs/refine/output.log" "refine line`n"
    Invoke-Script workflow-logs.ps1 -Once
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T1-1] t1 line b" "T1-1 の行"
    Assert-Contains $script:Out "[T2-1] t2 line a" "T2-1 の行"
    Assert-NotContains $script:Out "[T3-1] " "done のある run は出さない"
    Assert-NotContains $script:Out "[refine] " "guard.sha256 の無い run は出さない"
}

Invoke-TestCase "logs: -Run で指定した run だけを出す" {
    New-LogRun 'T1-1' 't1 line a'
    New-LogRun 'T2-1' 't2 line a'
    Invoke-Script workflow-logs.ps1 -Once -Run T2-1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T2-1] t2 line a" "T2-1 の行"
    Assert-NotContains $script:Out "[T1-1] " "指定外の run は出さない"
}

Invoke-TestCase "logs: 追跡中に足した行と finished を出す" {
    New-LogRun 'T1-1' 'first line'
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath pwsh -WorkingDirectory $script:Proj -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList @('-NoProfile', '-File', '.agents/workflow/scripts/workflow-logs.ps1', '-Run', 'T1-1', '-Interval', '0.5')
    Start-Sleep -Seconds 1
    [System.IO.File]::AppendAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log", "added line`n")
    Start-Sleep -Seconds 1
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/done" "EXIT:0`nEND:2026-01-01T00:00:00+09:00`n"
    # 指定した run が終わったら自分で終わるはず(30 秒を超えたら失敗)
    $exited = $p.WaitForExit(30000)
    if (-not $exited) { $p.Kill() }
    Assert-Eq 'True' "$exited" "30 秒以内に自分で終わる"
    if ($exited) { Assert-Eq 0 $p.ExitCode "自分で exit 0 で終わる" }
    $out = [System.IO.File]::ReadAllText($outFile)
    Remove-Item $outFile, $errFile -Force
    Assert-Contains $out "[T1-1] first line" "既存の行"
    Assert-Contains $out "[T1-1] added line" "追跡中に足した行"
    Assert-Contains $out "[T1-1] --- finished (0)" "終了行"
}

Invoke-TestCase "logs: -Tail 1 は末尾の1行だけ出す" {
    New-LogRun 'T1-1' "line a`nline b`nline c"
    Invoke-Script workflow-logs.ps1 -Once -Tail 1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T1-1] line c" "最後の行"
    Assert-NotContains $script:Out "line a" "古い行は出さない"
    Assert-NotContains $script:Out "line b" "古い行は出さない"
}

Invoke-TestCase "logs: 未知の引数は exit 1" {
    Invoke-Script workflow-logs.ps1 -Bogus
    Assert-Eq 1 $script:Code "exit code: $($script:Err)"
}

Invoke-TestCase "logs: BOM 付き UTF-16LE のログを正しい文字で出す" {
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" ''
    $text = "`u{3053}`u{3093}`u{306B}`u{3061}`u{306F}`nline2 `u{30C6}`u{30B9}`u{30C8}`n"
    $bytes = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($text))
    [System.IO.File]::WriteAllBytes("$script:Proj/.agents/workflow/runs/T1-1/output.log", $bytes)
    Invoke-Script workflow-logs.ps1 -Once
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T1-1] `u{3053}`u{3093}`u{306B}`u{3061}`u{306F}" "UTF-16LE の1行目"
    Assert-Contains $script:Out "[T1-1] line2 `u{30C6}`u{30B9}`u{30C8}" "UTF-16LE の2行目"
    Assert-NotContains $script:Out "`u{FFFD}" "文字化けしない"
}

Invoke-TestCase "logs: リダイレクトで受けた日本語は BOM なしの UTF-8 のバイト列になる" {
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" ''
    $jp = "`u{3053}`u{3093}`u{306B}`u{3061}`u{306F}"
    [System.IO.File]::WriteAllBytes("$script:Proj/.agents/workflow/runs/T1-1/output.log", [System.Text.Encoding]::UTF8.GetBytes("$jp`n"))
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath pwsh -WorkingDirectory $script:Proj -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList @('-NoProfile', '-File', '.agents/workflow/scripts/workflow-logs.ps1', '-Once')
    $exited = $p.WaitForExit(30000)
    if (-not $exited) { $p.Kill() }
    $bytes = [System.IO.File]::ReadAllBytes($outFile)
    Remove-Item $outFile, $errFile -Force
    # stream は最初に見つけたとき watching の行を出す(sh 版と同じ)。時刻は output.log の更新時刻
    $clock = (Get-Item "$script:Proj/.agents/workflow/runs/T1-1/output.log").LastWriteTime.ToString('HH:mm:ss')
    $expected = [System.Text.Encoding]::UTF8.GetBytes("[T1-1] --- watching (updated $clock)`n[T1-1] $jp`n")
    Assert-Eq 'True' "$exited" "自分で終わる"
    Assert-Eq ($expected -join ',') ($bytes -join ',') "BOM なしの UTF-8 のバイト列"
}

Invoke-TestCase "logs: UTF-8 の BOM は出力に残らない" {
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/guard.sha256" ''
    $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("first line`nsecond line`n"))
    [System.IO.File]::WriteAllBytes("$script:Proj/.agents/workflow/runs/T1-1/output.log", $bytes)
    Invoke-Script workflow-logs.ps1 -Once
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T1-1] first line" "最初の行"
    Assert-NotContains $script:Out "`u{FEFF}" "BOM が残らない"
}

Invoke-TestCase "logs: 止まった run は探索から外し -Run なら出す" {
    New-LogRun 'T1-1' 'old line'
    New-LogRun 'T2-1' 'fresh line'
    (Get-Item "$script:Proj/.agents/workflow/runs/T1-1/output.log").LastWriteTime = (Get-Date).AddHours(-2)
    Invoke-Script workflow-logs.ps1 -Once
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T2-1] fresh line" "新しい run は出る"
    Assert-NotContains $script:Out "[T1-1] " "止まった run は出さない"
    Invoke-Script workflow-logs.ps1 -Once -Run T1-1
    Assert-Eq 0 $script:Code "exit code (-Run): $($script:Err)"
    Assert-Contains $script:Out "[T1-1] old line" "-Run で指定すれば出る"
}

Invoke-TestCase "logs: -Interval 0 は exit 1" {
    New-LogRun 'T1-1' 'line'
    Invoke-Script workflow-logs.ps1 -Once -Interval 0
    Assert-Eq 1 $script:Code "exit code: $($script:Err)"
}

Invoke-TestCase "logs: EXIT: 行の無い done は finished (unknown)" {
    New-LogRun 'T1-1' 'line a'
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/done" "END:2026-01-01T00:00:00+09:00`n"
    Invoke-Script workflow-logs.ps1 -Run T1-1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out "[T1-1] --- finished (unknown)" "EXIT: 行が無い done"
}

Invoke-TestCase "logs: columns は run ごとに列を分けて並べる" {
    New-LogRun 'T1-1' "alpha one`nalpha two"
    New-LogRun 'T2-1' "beta one`nbeta two"
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 80 -Height 10
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    $header = Get-FirstLineMatching $script:Out 'T1-1'
    Assert-Contains $header 'T2-1' "run の数だけ横に並ぶ"
    $row1 = Get-FirstLineMatching $script:Out 'alpha one'
    Assert-Contains $row1 'beta one' "同じ行に別の列の行が並ぶ"
    Assert-NotContains $row1 'beta two' "ほかの run の行が混ざらない"
    $row2 = Get-FirstLineMatching $script:Out 'alpha two'
    Assert-Contains $row2 'beta two' "2 行目も列がずれない"
}

Invoke-TestCase "logs: columns の2行目は更新時刻と running / finished" {
    New-LogRun 'T1-1' 'running line'
    New-LogRun 'T2-1' 'finished line' '3'
    $fixed = Get-Date -Year 2020 -Month 1 -Day 2 -Hour 3 -Minute 4 -Second 5
    (Get-Item "$script:Proj/.agents/workflow/runs/T1-1/output.log").LastWriteTime = $fixed
    (Get-Item "$script:Proj/.agents/workflow/runs/T2-1/output.log").LastWriteTime = $fixed
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 70 -Height 8 -Run 'T1-1,T2-1'
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out 'updated 03:04:05 running' "running の列の2行目は更新時刻"
    Assert-Contains $script:Out 'updated 03:04:05 finished (3)' "done のある run は finished (EXIT の値)"
}

Invoke-TestCase "logs: columns は全角の行を列の幅で折り返す" {
    $jp = "あいうえおかきくけこさしすせそたちつてとなにぬねの"
    New-LogRun 'T1-1' $jp
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 20 -Height 10
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out 'あいうえおかきくけこ' "全角は列の幅で折り返す"
    Assert-NotContains $script:Out $jp "折り返さずに1行では出さない"
    $maxw = Get-MaxLineWidth $script:Out
    Assert-Eq 'True' "$($maxw -le 20)" "どの行も幅を超えない (max=$maxw)"
}

Invoke-TestCase "logs: columns は制御文字を整える" {
    $log = "`u{1B}[31mred`nprogress 10%`rprogress 90%`n`ttab`n`u{1B}[2Kclear"
    New-LogRun 'T1-1' $log
    New-LogRun 'T2-1' 'normal line'
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 70 -Height 8
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-NotContains $script:Out "`r" "復帰(`r)を残さない"
    Assert-NotContains $script:Out "`t" "タブを残さない"
    Assert-NotContains $script:Out "`u{1B}[2K" "SGR 以外の ANSI を残さない"
    Assert-Contains $script:Out 'progress 90%' "同じ行の後半だけ残す"
    Assert-NotContains $script:Out 'progress 10%' "`r より前は残さない"
    $redLine = Get-FirstLineMatching $script:Out 'red'
    $escIdx = $redLine.IndexOf("`u{1B}[0m")
    $sepIdx = $redLine.IndexOf(' │ ')
    Assert-Eq 'True' "$($escIdx -ge 0 -and $sepIdx -ge 0 -and $escIdx -lt $sepIdx)" "red の行で色を戻す ANSI が区切りより前にある"
    $maxw = Get-MaxLineWidth $script:Out
    Assert-Eq 'True' "$($maxw -le 70)" "ANSI を除いた幅が画面の幅を超えない (max=$maxw)"
}

Invoke-TestCase "logs: columns は全角の記号を列の幅で折り返す" {
    New-LogRun 'T1-1' ('✅' * 12)
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 20
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out ('✅' * 10) "全角の記号は10個で折り返す"
    Assert-NotContains $script:Out ('✅' * 11) "11個以上を1行に出さない"
}

Invoke-TestCase "logs: columns は長いログの末尾だけを出す" {
    $log = ((0..1999 | ForEach-Object { 'line {0:0000}' -f $_ }) -join "`n")
    New-LogRun 'T1-1' $log
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 40 -Height 6
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-NotContains $script:Out 'line 1996' "末尾より前の行は出さない"
    $i97 = $script:Out.IndexOf('line 1997')
    $i98 = $script:Out.IndexOf('line 1998')
    $i99 = $script:Out.IndexOf('line 1999')
    Assert-Eq 'True' "$($i97 -ge 0 -and $i97 -lt $i98 -and $i98 -lt $i99)" "末尾の3行をこの順で出す"
}

Invoke-TestCase "logs: columns は入りきらない run を +N more で出す" {
    New-LogRun 'T1-1' 't1 line'
    New-LogRun 'T2-1' 't2 line'
    Invoke-Script workflow-logs.ps1 -Once -Layout columns -Width 40 -Height 6
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out '+1 more:' "入りきらない run は最下行に出す"
    Assert-Contains $script:Out 'T2-1 (updated ' "最下行に run 名と更新時刻を出す"
}

Invoke-TestCase "logs: stream は watching の行に更新時刻を出す" {
    New-LogRun 'T1-1' 'line a'
    (Get-Item "$script:Proj/.agents/workflow/runs/T1-1/output.log").LastWriteTime = Get-Date -Year 2020 -Month 1 -Day 2 -Hour 3 -Minute 4 -Second 5
    Invoke-Script workflow-logs.ps1 -Once -Layout stream -Run T1-1
    Assert-Eq 0 $script:Code "exit code: $($script:Err)"
    Assert-Contains $script:Out '[T1-1] --- watching (updated 03:04:05)' "watching の行に更新時刻を出す"
}

Show-Summary
