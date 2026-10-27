# 複数の子エージェント run の output.log を、1つの画面に流し続ける(tail -f の複数 run 版)。
# workflow-logs.sh と同じ動作・同じ出力。
# Usage: workflow-logs.ps1 [-Run <ID>-<N>[,...]] [-Tail <行数>] [-Interval <秒>] [-Duration <秒>] [-Once]
#   -Run       指定した名前の run だけを追う(カンマ区切りで複数可。形式は ^[A-Za-z0-9_-]+-[0-9]+$)。
#              ディレクトリがまだ無ければ現れるまで待つ
#   -Tail      run を初めて見つけたとき、output.log の末尾から出す行数(既定 20)
#   -Interval  run の探し直しとログ確認の間隔(秒。既定 1。0 より大きい数だけ。0・0.0 は使い方の誤り)
#   -Duration  指定した秒数で終了する
#   -Once      対象の run の末尾を出して終了する
# 対象の run: -Run があればその名前の run。無ければ .agents/workflow/runs/*/ のうち
#   guard.sha256 があり done が無いもの(-Interval ごとに探し直し、新しい run を加える)。
#   output.log(無ければ guard.sha256)の最終更新が child_agent.timeout_seconds 秒
#   (.agents/workflow/config.json。読めない・正の整数でなければ 1800)より前の run は、
#   止まった run(kill・クラッシュで done が無い)として対象にしない。-Run 指定の run には当てない
# 文字コード: output.log の先頭が BOM FF FE なら UTF-16LE(Windows PowerShell 5.1 の `*>`)として、
#   EF BB BF なら UTF-8 の BOM を除いて読む。それ以外は UTF-8。2バイト単位に満たない端数は次の読み込みに回す
# 出力: 各行の先頭に `[<run>] ` を付ける。出力が端末へ向いていて環境変数 NO_COLOR が空か未設定なら、
#   接頭辞に run ごとに違う色(ANSI 31〜36)を付ける。初回は末尾の -Tail 行、以後は追記された完成した行だけ。
#   output.log が短くなったら先頭から読み直し `[<run>] --- log truncated` を出す。
#   done が現れたら残りの行(末尾の改行の無い行を含む)と `[<run>] --- finished (<EXIT の値>)` を出し、
#   その run の追跡をやめる(EXIT: 行がまだ無ければ 0.1 秒おきに最大 10 回読み直す)。開始時に stderr へ `Watching: ...` を出す
# 終わり方: -Once は末尾を出して終了 / -Duration は指定秒数で終了 /
#   -Run 指定時は指定した run がすべて終わったら終了 / それ以外は Ctrl+C まで続ける
#   (入力がリダイレクトされていなければ Ctrl+C を自分で受け取り、待ちの間に見つけて exit 0 で終わる)
# exit: 0=正常に終わった(Ctrl+C を含む) / 1=使い方不備(未知の引数・値の無いオプション・形式不正・数値でない値)
param(
    [string[]]$Run = @(),
    [string]$Tail = '20',
    [string]$Interval = '1',
    [string]$Duration = '',
    [switch]$Once
)

function Exit-Usage {
    param([string]$Message)
    if ($Message) { [Console]::Error.WriteLine($Message) }
    [Console]::Error.WriteLine('Usage: workflow-logs.ps1 [-Run <ID>-<N>[,...]] [-Tail <lines>] [-Interval <sec>] [-Duration <sec>] [-Once]')
    exit 1
}

# --- 引数の検証 ---
# param に無い引数は $args に入って黙って無視されるので、未知の引数として弾く
if ($args.Count -gt 0) { Exit-Usage "Unknown argument: $($args[0])" }
$runNames = New-Object System.Collections.Generic.List[string]
foreach ($item in $Run) {
    foreach ($r in $item.Split(',')) {
        if ($r -cnotmatch '^[A-Za-z0-9_-]+-[0-9]+$') { Exit-Usage "Invalid -Run: $r" }
        if (-not $runNames.Contains($r)) { $runNames.Add($r) }
    }
}
if ($Tail -cnotmatch '^[0-9]+$') { Exit-Usage "Invalid -Tail: $Tail" }
$tailLines = [int]$Tail
$culture = [System.Globalization.CultureInfo]::InvariantCulture
if ($Interval -cnotmatch '^[0-9]+(\.[0-9]+)?$') { Exit-Usage "Invalid -Interval: $Interval" }
$intervalSec = [double]::Parse($Interval, $culture)
if ($intervalSec -le 0) { Exit-Usage "Invalid -Interval: $Interval (must be greater than 0)" }
$durationSec = $null
if ($Duration -ne '') {
    if ($Duration -cnotmatch '^[0-9]+(\.[0-9]+)?$') { Exit-Usage "Invalid -Duration: $Duration" }
    $durationSec = [double]::Parse($Duration, $culture)
}

Set-Location $PSScriptRoot\..\..\..
# .NET のファイル API は Set-Location では変わらないカレントディレクトリを使う
[Environment]::CurrentDirectory = (Get-Location).Path

$runsDir = '.agents/workflow/runs'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$stdout.NewLine = "`n"
$stdout.AutoFlush = $true
$useColor = (-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR)
$esc = [char]27

$tracked = @{}
$finished = New-Object 'System.Collections.Generic.HashSet[string]'
$order = New-Object System.Collections.Generic.List[string]

function Write-Line {
    param([string]$RunName, [string]$Text)
    if ($useColor) {
        $color = 31 + ($order.IndexOf($RunName) % 6)
        $prefix = "$esc[${color}m[$RunName]$esc[0m "
    } else {
        $prefix = "[$RunName] "
    }
    $stdout.WriteLine($prefix + $Text)
}

function ConvertFrom-LogBytes {
    param([byte[]]$Bytes)
    return $utf8.GetString($Bytes).TrimEnd("`r")
}

function Get-RunPath {
    param([string]$RunName, [string]$Name)
    return "$runsDir/$RunName/$Name"
}

# 状態の buf(未完成の行のバイト列。改行を含まない)に data を足し、完成した行(UTF-8 のバイト列)の
# リストを返す。先頭の BOM で文字コードを決める(State.enc)。BOM の判定に足りなければ $null
function Split-Lines {
    param($State, [byte[]]$Data)
    if ($null -eq $State.enc) {
        if ($Data.Length -eq 0 -or ($Data.Length -lt 3 -and ($Data[0] -eq 0xFF -or $Data[0] -eq 0xEF))) { return $null }
        if ($Data[0] -eq 0xFF -and $Data[1] -eq 0xFE) {
            $State.enc = 'utf16'
            $skip = 2
        } elseif ($Data.Length -ge 3 -and $Data[0] -eq 0xEF -and $Data[1] -eq 0xBB -and $Data[2] -eq 0xBF) {
            $State.enc = 'utf8'
            $skip = 3
        } else {
            $State.enc = 'utf8'
            $skip = 0
        }
        if ($skip -gt 0) {
            $rest = New-Object byte[] ($Data.Length - $skip)
            [Buffer]::BlockCopy($Data, $skip, $rest, 0, $rest.Length)
            $Data = $rest
        }
    }
    if ($State.enc -eq 'utf16') {
        $raw = Join-Bytes $State.raw $Data
        $n = [int]([Math]::Floor($raw.Length / 2) * 2)
        # サロゲートペアの前半で切れていたら、次の読み込みに回す
        if ($n -ge 2 -and $raw[$n - 1] -ge 0xD8 -and $raw[$n - 1] -le 0xDB) { $n -= 2 }
        $rest = New-Object byte[] ($raw.Length - $n)
        [Buffer]::BlockCopy($raw, $n, $rest, 0, $rest.Length)
        $State.raw = $rest
        $Data = $utf8.GetBytes([System.Text.Encoding]::Unicode.GetString($raw, 0, $n))
    }
    $scan = $State.buf.Length
    $buf = Join-Bytes $State.buf $Data
    $lines = New-Object System.Collections.Generic.List[byte[]]
    $start = 0
    while ($scan -lt $buf.Length) {
        $idx = [Array]::IndexOf($buf, [byte]10, $scan)
        if ($idx -lt 0) { break }
        $line = New-Object byte[] ($idx - $start)
        [Buffer]::BlockCopy($buf, $start, $line, 0, $line.Length)
        $lines.Add($line)
        $start = $idx + 1
        $scan = $start
    }
    $tail = New-Object byte[] ($buf.Length - $start)
    [Buffer]::BlockCopy($buf, $start, $tail, 0, $tail.Length)
    $State.buf = $tail
    return , $lines
}

function Join-Bytes {
    param([byte[]]$A, [byte[]]$B)
    $r = New-Object byte[] ($A.Length + $B.Length)
    [Buffer]::BlockCopy($A, 0, $r, 0, $A.Length)
    [Buffer]::BlockCopy($B, 0, $r, $A.Length, $B.Length)
    return , $r
}

# output.log の pos 以降を読む(書き込み中でも開けるよう FileShare.ReadWrite)。読めなければ $null
function Read-LogFrom {
    param([string]$Path, [long]$Pos)
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            [void]$fs.Seek($Pos, [System.IO.SeekOrigin]::Begin)
            $ms = New-Object System.IO.MemoryStream
            $fs.CopyTo($ms)
            return , $ms.ToArray()
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
}

function Read-First {
    param([string]$RunName)
    $st = $tracked[$RunName]
    $data = Read-LogFrom (Get-RunPath $RunName 'output.log') 0
    if ($null -eq $data) { return }
    $lines = Split-Lines $st $data
    if ($null -eq $lines) { return }
    $st.pos = $data.Length
    if ($tailLines -eq 0) { return }
    $from = [Math]::Max(0, $lines.Count - $tailLines)
    for ($i = $from; $i -lt $lines.Count; $i++) {
        Write-Line $RunName (ConvertFrom-LogBytes $lines[$i])
    }
}

function Read-New {
    param([string]$RunName)
    $st = $tracked[$RunName]
    $path = Get-RunPath $RunName 'output.log'
    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    $size = $item.Length
    if ($size -lt $st.pos) {
        $st.pos = 0
        $st.buf = [byte[]]@()
        $st.raw = [byte[]]@()
        $st.enc = $null
        Write-Line $RunName '--- log truncated'
    }
    if ($size -eq $st.pos) { return }
    $data = Read-LogFrom $path $st.pos
    if ($null -eq $data) { return }
    $lines = Split-Lines $st $data
    if ($null -eq $lines) { return }
    $st.pos += $data.Length
    foreach ($ln in $lines) {
        Write-Line $RunName (ConvertFrom-LogBytes $ln)
    }
}

function Get-ExitValue {
    param([string]$RunName)
    try {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path (Get-Location).Path (Get-RunPath $RunName 'done')))
    } catch {
        return $null
    }
    $text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $m = [regex]::Match($text, '(?m)^EXIT:(.*?)\r?$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# EXIT: 行がまだ無ければ 0.1 秒おきに最大 10 回読み直す
function Get-FinalExitValue {
    param([string]$RunName)
    for ($i = 0; $i -le 10; $i++) {
        $v = Get-ExitValue $RunName
        if ($null -ne $v) { return $v }
        if ($i -lt 10) { Start-Sleep -Milliseconds 100 }
    }
    return 'unknown'
}

# 止まった run を外す秒数(config.json の child_agent.timeout_seconds。読めない・正の整数でなければ 1800)
function Get-StaleLimit {
    try {
        $cfg = Get-Content -Raw -LiteralPath '.agents/workflow/config.json' -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $v = $cfg.child_agent.timeout_seconds
        if (($v -is [int] -or $v -is [long]) -and $v -gt 0) { return [long]$v }
    } catch {
    }
    return 1800
}

# output.log(無ければ guard.sha256)の最終更新が limit 秒より前なら $true
function Test-Stale {
    param([string]$RunName, [long]$Limit)
    foreach ($name in 'output.log', 'guard.sha256') {
        $item = Get-Item -LiteralPath (Get-RunPath $RunName $name) -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            return (([DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds -gt $Limit)
        }
    }
    return $false
}

function Find-Runs {
    if ($runNames.Count -gt 0) {
        $names = @($runNames | Where-Object { Test-Path -LiteralPath "$runsDir/$_" -PathType Container })
    } else {
        $names = @()
        if (Test-Path -LiteralPath $runsDir -PathType Container) {
            $limit = Get-StaleLimit
            $names = @(Get-ChildItem -LiteralPath $runsDir -Directory -Name | Sort-Object { $_ } -CaseSensitive |
                Where-Object {
                    (Test-Path -LiteralPath (Get-RunPath $_ 'guard.sha256') -PathType Leaf) -and
                    -not (Test-Path -LiteralPath (Get-RunPath $_ 'done')) -and
                    ($tracked.ContainsKey($_) -or -not (Test-Stale $_ $limit))
                })
        }
    }
    foreach ($n in $names) {
        if ($tracked.ContainsKey($n) -or $finished.Contains($n)) { continue }
        $order.Add($n)
        $tracked[$n] = @{ pos = [long]0; buf = [byte[]]@(); raw = [byte[]]@(); enc = $null }
        Read-First $n
    }
}

function Invoke-Poll {
    Find-Runs
    foreach ($n in @($order | Where-Object { $tracked.ContainsKey($_) })) {
        $isDone = Test-Path -LiteralPath (Get-RunPath $n 'done')
        Read-New $n
        if ($isDone) {
            $st = $tracked[$n]
            $tracked.Remove($n)
            if ($st.buf.Length -gt 0) { Write-Line $n (ConvertFrom-LogBytes $st.buf) }
            Write-Line $n "--- finished ($(Get-FinalExitValue $n))"
            [void]$finished.Add($n)
        }
    }
}

# 待つ。Ctrl+C を自分で受け取っているときは 100 ミリ秒以下ごとにキーを見て、Ctrl+C なら $true を返す
$catchCtrlC = $false
function Wait-Interval {
    param([double]$Seconds)
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        $remainMs = ($end - [DateTime]::UtcNow).TotalMilliseconds
        if ($remainMs -le 0) { return $false }
        Start-Sleep -Milliseconds ([int][Math]::Ceiling([Math]::Min(100, $remainMs)))
        if ($catchCtrlC) {
            try {
                while ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
                }
            } catch [System.InvalidOperationException] {
                $script:catchCtrlC = $false
            }
        }
    }
}

[Console]::Error.WriteLine('Watching: .agents/workflow/runs (Ctrl+C to stop)')
$deadline = $null
if ($null -ne $durationSec) { $deadline = [DateTime]::UtcNow.AddSeconds($durationSec) }
$origTreatCtrlC = $null
if (-not [Console]::IsInputRedirected) {
    try {
        $origTreatCtrlC = [Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput = $true
        $catchCtrlC = $true
    } catch {
        $origTreatCtrlC = $null
    }
}
try {
    while ($true) {
        Invoke-Poll
        if ($Once) { break }
        if ($runNames.Count -gt 0 -and @($runNames | Where-Object { -not $finished.Contains($_) }).Count -eq 0) { break }
        $wait = $intervalSec
        if ($null -ne $deadline) {
            $remain = ($deadline - [DateTime]::UtcNow).TotalSeconds
            if ($remain -le 0) { break }
            $wait = [Math]::Min($wait, $remain)
        }
        if (Wait-Interval $wait) { break }
    }
} catch [System.IO.IOException] {
    # 出力先が閉じられた(パイプの切断)場合は正常終了として扱う
} finally {
    if ($null -ne $origTreatCtrlC) { [Console]::TreatControlCAsInput = $origTreatCtrlC }
}
exit 0
