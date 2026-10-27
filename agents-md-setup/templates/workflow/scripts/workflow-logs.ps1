# 複数の子エージェント run の output.log を、1つの画面に流し続ける(tail -f の複数 run 版)。
# workflow-logs.sh と同じ動作・同じ出力。
# Usage: workflow-logs.ps1 [-Run <ID>-<N>[,...]] [-Tail <行数>] [-Interval <秒>] [-Duration <秒>] [-Once]
#   -Run       指定した名前の run だけを追う(カンマ区切りで複数可。形式は ^[A-Za-z0-9_-]+-[0-9]+$)。
#              ディレクトリがまだ無ければ現れるまで待つ
#   -Tail      run を初めて見つけたとき、output.log の末尾から出す行数(既定 20)
#   -Interval  run の探し直しとログ確認の間隔(秒。既定 1)
#   -Duration  指定した秒数で終了する
#   -Once      対象の run の末尾を出して終了する
# 対象の run: -Run があればその名前の run。無ければ .agents/workflow/runs/*/ のうち
#   guard.sha256 があり done が無いもの(-Interval ごとに探し直し、新しい run を加える)
# 出力: 各行の先頭に `[<run>] ` を付ける。出力が端末へ向いていて環境変数 NO_COLOR が無ければ、
#   接頭辞に run ごとに違う色(ANSI 31〜36)を付ける。初回は末尾の -Tail 行、以後は追記された完成した行だけ。
#   output.log が短くなったら先頭から読み直し `[<run>] --- log truncated` を出す。
#   done が現れたら残りの行(末尾の改行の無い行を含む)と `[<run>] --- finished (<EXIT の値>)` を出し、
#   その run の追跡をやめる。開始時に stderr へ `Watching: ...` を出す
# 終わり方: -Once は末尾を出して終了 / -Duration は指定秒数で終了 /
#   -Run 指定時は指定した run がすべて終わったら終了 / それ以外は Ctrl+C まで続ける
# exit: 0=正常に終わった / 1=使い方不備(未知の引数・値の無いオプション・形式不正・数値でない値)
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

# 状態の buf(未完成の行のバイト列)に data を足し、完成した行(バイト列)の配列を返す
function Split-Lines {
    param($State, [byte[]]$Data)
    $buf = $State.buf
    $buf.AddRange($Data)
    $lines = New-Object System.Collections.Generic.List[byte[]]
    $start = 0
    for ($i = 0; $i -lt $buf.Count; $i++) {
        if ($buf[$i] -eq 10) {
            $lines.Add($buf.GetRange($start, $i - $start).ToArray())
            $start = $i + 1
        }
    }
    if ($start -gt 0) { $buf.RemoveRange(0, $start) }
    return , $lines
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
    $st.pos = $data.Length
    $lines = Split-Lines $st $data
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
        $st.buf.Clear()
        Write-Line $RunName '--- log truncated'
    }
    if ($size -eq $st.pos) { return }
    $data = Read-LogFrom $path $st.pos
    if ($null -eq $data) { return }
    $st.pos += $data.Length
    $lines = Split-Lines $st $data
    foreach ($ln in $lines) {
        Write-Line $RunName (ConvertFrom-LogBytes $ln)
    }
}

function Get-ExitValue {
    param([string]$RunName)
    try {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path (Get-Location).Path (Get-RunPath $RunName 'done')))
    } catch {
        return 'unknown'
    }
    $text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $m = [regex]::Match($text, '(?m)^EXIT:(.*?)\r?$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return 'unknown'
}

function Find-Runs {
    if ($runNames.Count -gt 0) {
        $names = @($runNames | Where-Object { Test-Path -LiteralPath "$runsDir/$_" -PathType Container })
    } else {
        $names = @()
        if (Test-Path -LiteralPath $runsDir -PathType Container) {
            $names = @(Get-ChildItem -LiteralPath $runsDir -Directory -Name | Sort-Object { $_ } -CaseSensitive |
                Where-Object {
                    (Test-Path -LiteralPath (Get-RunPath $_ 'guard.sha256') -PathType Leaf) -and
                    -not (Test-Path -LiteralPath (Get-RunPath $_ 'done'))
                })
        }
    }
    foreach ($n in $names) {
        if ($tracked.ContainsKey($n) -or $finished.Contains($n)) { continue }
        $order.Add($n)
        $tracked[$n] = @{ pos = [long]0; buf = (New-Object System.Collections.Generic.List[byte]) }
        Read-First $n
    }
}

function Invoke-Poll {
    Find-Runs
    foreach ($n in @($tracked.Keys)) {
        $isDone = Test-Path -LiteralPath (Get-RunPath $n 'done')
        Read-New $n
        if ($isDone) {
            $st = $tracked[$n]
            $tracked.Remove($n)
            if ($st.buf.Count -gt 0) { Write-Line $n (ConvertFrom-LogBytes $st.buf.ToArray()) }
            Write-Line $n "--- finished ($(Get-ExitValue $n))"
            [void]$finished.Add($n)
        }
    }
}

[Console]::Error.WriteLine('Watching: .agents/workflow/runs (Ctrl+C to stop)')
$deadline = $null
if ($null -ne $durationSec) { $deadline = [DateTime]::UtcNow.AddSeconds($durationSec) }
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
        Start-Sleep -Milliseconds ([int][Math]::Ceiling($wait * 1000))
    }
} catch [System.IO.IOException] {
    # 出力先が閉じられた(パイプの切断)場合は正常終了として扱う
}
exit 0
