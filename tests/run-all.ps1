# 全テスト(tests/test-*.ps1)を名前順に実行する。
# -Jobs <N> でテストファイル単位の並列実行(既定は tests/run-all.conf の jobs(無ければ 4)。-Jobs 1 で直列)。
# -PrintJobs は同時実行数を決めて「Jobs: <同時実行数>」だけを出し、テストを実行せずに終わる。
# テストファイルの一覧を作った後、1 行目として「Jobs: <同時実行数>」を出す。
# 直列では各テストの出力をそのまま流し、各ファイルが終わり次第
# PASS / FAIL と所要秒数を 1 行ずつ出す(作業ディレクトリは作らない)。
# 並列では各ファイルの出力をログに隔離し、実行後に
# 「----- ファイル -----」→ そのログ → その直後に PASS / FAIL の順で出す。
# 最後に失敗したファイルの一覧(または ALL PASSED)を出す。
# 1 本でも失敗すれば exit 1、すべて成功なら exit 0。
# (syntax-check.ps1 は品質ゲートとして別に実行するため、ここには含めない)
param([int]$Jobs = 0, [switch]$PrintJobs)
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path "$PSScriptRoot/..")
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ($PSBoundParameters.ContainsKey('Jobs')) {
    if ($Jobs -lt 1) {
        [Console]::Error.WriteLine("ERROR: -Jobs requires a positive integer")
        exit 2
    }
}
else {
    $Jobs = 4
    $confPath = "tests/run-all.conf"
    if (Test-Path -LiteralPath $confPath) {
        $line = Get-Content -LiteralPath $confPath | Where-Object { $_ -match '^jobs=' } | Select-Object -First 1
        if ($null -ne $line) {
            $value = ($line -replace '^jobs=', '').TrimEnd("`r")
            if ($value -notmatch '^\d+$' -or [int]$value -lt 1) {
                [Console]::Error.WriteLine("ERROR: tests/run-all.conf: jobs requires a positive integer")
                exit 2
            }
            $Jobs = [int]$value
        }
    }
}
if ($PrintJobs) {
    Write-Host "Jobs: $Jobs"
    exit 0
}

$testFiles = @(Get-ChildItem "tests/test-*.ps1" | Sort-Object Name)
if ($testFiles.Count -eq 0) {
    Write-Host "ALL PASSED: 0 files"
    exit 0
}
$items = foreach ($t in $testFiles) {
    [pscustomobject]@{
        FullName = $t.FullName
        BaseName = $t.BaseName
        Name     = $t.Name
    }
}

# テストの起動処理(直列・並列で同じ引数: pwsh -NoProfile -File <ファイル>)。
# 第 1 引数($LogPath)が $null の場合は直列用: 出力をそのまま流し、終了コードで成否を返す。
# 指定された場合は並列用: stdout を $LogPath、stderr を $ErrPath に隔離して書き、
# stderr を log に追記し、$ResultPath に "<exit code>|<秒>" を残す(例外時も必ず書く)。
# (ForEach-Object -Parallel はスクリプトブロックの $using をサポートしないため、
#  共有コードはこの here-string 1 か所だけに置き、両経路から scriptblock として使う)
$invokeTestText = @'
    param($FullName, $LogPath, $ErrPath, $ResultPath)
    $ErrorActionPreference = "Stop"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 1
    try {
        if ($null -ne $LogPath) {
            $p = Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", $FullName) -RedirectStandardOutput $LogPath -RedirectStandardError $ErrPath -Wait -PassThru -NoNewWindow
            $exitCode = $p.ExitCode
            if ((Test-Path -LiteralPath $ErrPath) -and (Get-Item -LiteralPath $ErrPath).Length -gt 0) {
                Get-Content -LiteralPath $ErrPath | Add-Content -LiteralPath $LogPath
            }
        }
        else {
            # 子 pwsh の stdout をパイプラインで受け取ると戻り値に混ざって捨てられるため、
            # Out-Host で画面に流す(戻り値は結果オブジェクトだけになる)
            & pwsh -NoProfile -File $FullName | Out-Host
            $exitCode = $LASTEXITCODE
        }
    }
    catch {
        $exitCode = 1
    }
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, [MidpointRounding]::AwayFromZero)
    if ($null -ne $ResultPath) {
        "$exitCode|$secs" | Set-Content -LiteralPath $ResultPath
    }
    [pscustomobject]@{ ExitCode = $exitCode; Seconds = $secs }
'@
$invokeTest = [scriptblock]::Create($invokeTestText)

Write-Host "Jobs: $Jobs"

$failed = 0
$failedFiles = @()
$runRoot = $null
try {
    if ($Jobs -eq 1) {
        # 直列実行: 各テストの出力をそのまま流し、終わり次第結果を 1 行ずつ出す。
        # 作業ディレクトリは作らない。
        foreach ($it in $items) {
            $r = & $invokeTest $it.FullName $null $null $null
            $it | Add-Member -NotePropertyName ExitCode -NotePropertyValue $r.ExitCode
            $it | Add-Member -NotePropertyName Seconds -NotePropertyValue $r.Seconds
            $name = "tests/$($it.Name)"
            if ($r.ExitCode -eq 0) {
                Write-Host "PASS: $name ($($r.Seconds)s)"
            }
            else {
                $failed++
                $failedFiles += $name
                Write-Host "FAIL: $name ($($r.Seconds)s)"
            }
        }
    }
    else {
        # 並列実行: 同時実行数を Jobs に制限し、各ファイルの出力をログに隔離する。
        $runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("runall-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $items | ForEach-Object -Parallel {
            $invoke = [scriptblock]::Create($using:invokeTestText)
            $root = $using:runRoot
            $log = Join-Path $root "$($_.BaseName).log"
            $err = Join-Path $root "$($_.BaseName).err"
            $result = Join-Path $root "$($_.BaseName).result"
            & $invoke $_.FullName $log $err $result | Out-Null
        } -ThrottleLimit $Jobs
        foreach ($it in $items) {
            $resultPath = Join-Path $runRoot "$($it.BaseName).result"
            if (Test-Path -LiteralPath $resultPath) {
                $parts = (Get-Content -LiteralPath $resultPath) -split '\|'
                $exitCode = [int]$parts[0]
                $secs = [int]$parts[1]
            }
            else {
                # .result が無い(テストの起動に失敗した等)場合は例外で止めず FAIL として扱う
                $exitCode = 1
                $secs = 0
            }
            $it | Add-Member -NotePropertyName ExitCode -NotePropertyValue $exitCode
            $it | Add-Member -NotePropertyName Seconds -NotePropertyValue $secs
        }
    }

    # 並列では各ファイルごとに「----- ファイル -----」→ そのログ →
    # その直後に PASS / FAIL の順に出す(直列は実行時に出力済み)。
    if ($Jobs -ne 1) {
        foreach ($it in $items) {
            $name = "tests/$($it.Name)"
            $log = Join-Path $runRoot "$($it.BaseName).log"
            Write-Host "----- $name -----"
            if (Test-Path -LiteralPath $log) {
                Get-Content -LiteralPath $log | Write-Host
            }
            if ($it.ExitCode -eq 0) {
                Write-Host "PASS: $name ($($it.Seconds)s)"
            }
            else {
                $failed++
                $failedFiles += $name
                Write-Host "FAIL: $name ($($it.Seconds)s)"
            }
        }
    }

    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "FAILED: $failed/$($testFiles.Count)"
        foreach ($file in $failedFiles) {
            Write-Host "  $file"
        }
        exit 1
    }
    Write-Host "ALL PASSED: $($testFiles.Count) files"
    exit 0
}
finally {
    if ($runRoot) {
        Remove-Item -Recurse -Force $runRoot -ErrorAction SilentlyContinue
    }
}
