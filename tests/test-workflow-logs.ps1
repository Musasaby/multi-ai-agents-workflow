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
    $expected = [System.Text.Encoding]::UTF8.GetBytes("[T1-1] $jp`n")
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

Show-Summary
