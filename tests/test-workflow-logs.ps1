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
        -ArgumentList @('-NoProfile', '-File', '.agents/workflow/scripts/workflow-logs.ps1', '-Run', 'T1-1', '-Duration', '3', '-Interval', '0.5')
    Start-Sleep -Seconds 1
    [System.IO.File]::AppendAllText("$script:Proj/.agents/workflow/runs/T1-1/output.log", "added line`n")
    Start-Sleep -Seconds 1
    Write-Utf8File "$script:Proj/.agents/workflow/runs/T1-1/done" "EXIT:0`nEND:2026-01-01T00:00:00+09:00`n"
    $null = $p.WaitForExit(30000)
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

Show-Summary
