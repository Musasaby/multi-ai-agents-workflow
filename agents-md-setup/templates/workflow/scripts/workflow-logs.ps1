# 複数の子エージェント run の output.log を、1つの画面に表示する(tail -f の複数 run 版)。
# workflow-logs.sh と同じ動作・同じ出力。
# Usage: workflow-logs.ps1 [-Run <ID>-<N>[,...]] [-Tail <行数>] [-Interval <秒>] [-Duration <秒>]
#        [-Once] [-Layout <columns|stream>] [-Width <桁>] [-Height <行>]
#   -Run       指定した名前の run だけを追う(カンマ区切りで複数可。形式は ^[A-Za-z0-9_-]+-[0-9]+$)。
#              ディレクトリがまだ無ければ現れるまで待つ
#   -Tail      stream で run を初めて見つけたとき、output.log の末尾から出す行数(既定 20)
#   -Interval  run の探し直しとログ確認・再描画の間隔(秒。既定 1。0 より大きい数だけ。0・0.0 は使い方の誤り)
#   -Duration  指定した秒数で終了する
#   -Once      対象の run を1回だけ描いて終了する(stream は末尾の行、columns は1画面)
#   -Layout    表示のしかた。columns=run ごとに横へ列を並べる / stream=全 run の行を1列に流す。
#              既定は出力が端末なら columns、そうでなければ stream(パイプ・テストでは stream のまま)
#   -Width     画面の幅(桁)。無ければ端末の幅、取れなければ 120
#   -Height    画面の高さ(行)。無ければ端末の高さ、取れなければ 30
# 対象の run: -Run があればその名前の run。無ければ .agents/workflow/runs/*/ のうち
#   guard.sha256 があり done が無いもの(-Interval ごとに探し直し、新しい run を加える)。
#   output.log(無ければ guard.sha256)の最終更新が child_agent.timeout_seconds 秒
#   (.agents/workflow/config.json。読めない・正の整数でなければ 1800)より前の run は、
#   止まった run(kill・クラッシュで done が無い)として対象にしない。-Run 指定の run には当てない
# 最終更新: run の output.log(無ければ guard.sha256)の更新時刻(ローカル時刻)。
#   stream は run を最初に見つけたときに `[<run>] --- watching (updated HH:MM:SS)`、
#   新しい行が 60 秒出ないごとに `[<run>] --- no output for <N>s (updated HH:MM:SS)` を出す。
# columns レイアウト: run を見つけた順に左から並べる。列の幅は画面の幅を列の数で割り、列の間に ` │ ` を挟む。
#   列の幅が 30 桁に満たなくなる数の run があるときは、入るだけの列を出し、入らない run は最下行に
#   `+<N> more: <run> (updated HH:MM:SS) ...` で出す。終わった run の列は、新しい run が入りきらなくなるまで
#   残し、入りきらなければ終わった run から外す。各列の 1 行目は run の名前(色は stream と同じ規則)、
#   2 行目は `updated HH:MM:SS (<N>s ago)` と running / finished (<EXIT の値)。列の幅に入らないときは
#   `(<N>s ago)` を外し、それでも入らなければ先頭の `updated ` も外し、最後は列の幅で切る。
#   3 行目は区切りの線、4 行目から下はその run のログの末尾を列の幅で折り返して出す。
#   全角は 2 桁(.NET に east_asian_width が無いので、Unicode の East Asian Width が W / F の
#   主な範囲を表で判定する)、ANSI エスケープは除いて数える。
#   再描画は -Interval ごとに画面全体。端末では代替画面(ESC[?1049h)に切り替え、終了時(Ctrl+C を含む)に戻す。
#   -Once のときは ESC の制御を入れずに1画面だけ出す(テスト用)。
# 文字コード: output.log の先頭が BOM FF FE なら UTF-16LE(Windows PowerShell 5.1 の `*>`)として、
#   EF BB BF なら UTF-8 の BOM を除いて読む。それ以外は UTF-8。2バイト単位に満たない端数は次の読み込みに回す
#   出力が端末のときは、書き始める前に [Console]::OutputEncoding を BOM なしの UTF-8 にし、終了時に元へ戻す。
#   リダイレクトされているときは BOM なしの UTF-8 のバイト列を出すだけで、OutputEncoding は変えない
# stream の出力: 各行の先頭に `[<run>] ` を付ける。出力が端末へ向いていて環境変数 NO_COLOR が空か未設定なら、
#   接頭辞に run ごとに違う色(ANSI 31〜36)を付ける。初回は末尾の -Tail 行、以後は追記された完成した行だけ。
#   output.log が短くなったら先頭から読み直し `[<run>] --- log truncated` を出す。
#   done が現れたら残りの行(末尾の改行の無い行を含む)と `[<run>] --- finished (<EXIT の値>)` を出し、
#   その run の追跡をやめる(EXIT: 行がまだ無ければ 0.1 秒おきに最大 10 回読み直す)。開始時に stderr へ `Watching: ...` を出す
# 終わり方: -Once は1回描いて終了 / -Duration は指定秒数で終了 /
#   -Run 指定時は指定した run がすべて終わったら終了 / それ以外は Ctrl+C まで続ける
#   (入力がリダイレクトされていなければ Ctrl+C を自分で受け取り、待ちの間に見つけて exit 0 で終わる)
# exit: 0=正常に終わった(Ctrl+C を含む) / 1=使い方不備(未知の引数・値の無いオプション・形式不正・数値でない値)
param(
    [string[]]$Run = @(),
    [string]$Tail = '20',
    [string]$Interval = '1',
    [string]$Duration = '',
    [switch]$Once,
    [string]$Layout = '',
    [string]$Width = '',
    [string]$Height = ''
)

function Exit-Usage {
    param([string]$Message)
    if ($Message) { [Console]::Error.WriteLine($Message) }
    [Console]::Error.WriteLine('Usage: workflow-logs.ps1 [-Run <ID>-<N>[,...]] [-Tail <lines>] [-Interval <sec>] [-Duration <sec>] [-Once] [-Layout <columns|stream>] [-Width <cols>] [-Height <rows>]')
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
if ($Layout -ne '' -and $Layout -cne 'columns' -and $Layout -cne 'stream') { Exit-Usage "Invalid -Layout: $Layout" }
$optWidth = $null
if ($Width -ne '') {
    if ($Width -cnotmatch '^[0-9]+$') { Exit-Usage "Invalid -Width: $Width" }
    $optWidth = [long]$Width
    if ($optWidth -le 0) { Exit-Usage "Invalid -Width: $Width (must be a positive integer)" }
}
$optHeight = $null
if ($Height -ne '') {
    if ($Height -cnotmatch '^[0-9]+$') { Exit-Usage "Invalid -Height: $Height" }
    $optHeight = [long]$Height
    if ($optHeight -le 0) { Exit-Usage "Invalid -Height: $Height (must be a positive integer)" }
}
# 既定は出力が端末なら columns、そうでなければ stream
$layout = $Layout
if ($layout -eq '') {
    if ([Console]::IsOutputRedirected) { $layout = 'stream' } else { $layout = 'columns' }
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
$maxLines = 2000
$noOutputEvery = 60
# ANSI エスケープ(sh 版の regex と同じ)。桁数の計算から除き、折り返し・切り詰めではそのまま残す
$script:ansiRegex = [regex]::new("\G(?:\u001b\[[0-9;?]*[@-~]|\u001b\][^\u0007]*(?:\u0007|\u001b\\))")

$tracked = @{}
$order = New-Object System.Collections.Generic.List[string]

function Get-Now {
    return ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0)
}

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

# output.log(無ければ guard.sha256)の更新時刻(ローカル時刻)を HH:MM:SS にする
function Get-UpdateClock {
    param([string]$RunName)
    foreach ($name in 'output.log', 'guard.sha256') {
        $item = Get-Item -LiteralPath (Get-RunPath $RunName $name) -ErrorAction SilentlyContinue
        if ($null -ne $item) { return $item.LastWriteTime.ToString('HH:mm:ss') }
    }
    return '--:--:--'
}

# output.log(無ければ guard.sha256)の更新時刻を UNIX 秒で返す(無ければ $null)
function Get-UpdateEpoch {
    param([string]$RunName)
    foreach ($name in 'output.log', 'guard.sha256') {
        $item = Get-Item -LiteralPath (Get-RunPath $RunName $name) -ErrorAction SilentlyContinue
        if ($null -ne $item) { return ([DateTimeOffset]$item.LastWriteTime).ToUnixTimeMilliseconds() / 1000.0 }
    }
    return $null
}

# --- 表示幅(全角・ANSI エスケープ) ---
# .NET に east_asian_width が無いので、East Asian Width が W / F の主な範囲を表で判定する
function Test-WideCodePoint {
    param([int]$CodePoint)
    return (
        ($CodePoint -ge 0x1100 -and $CodePoint -le 0x115F) -or
        ($CodePoint -ge 0x2E80 -and $CodePoint -le 0x303E) -or
        ($CodePoint -ge 0x3041 -and $CodePoint -le 0x33FF) -or
        ($CodePoint -ge 0x3400 -and $CodePoint -le 0x4DBF) -or
        ($CodePoint -ge 0x4E00 -and $CodePoint -le 0x9FFF) -or
        ($CodePoint -ge 0xA000 -and $CodePoint -le 0xA4CF) -or
        ($CodePoint -ge 0xA960 -and $CodePoint -le 0xA97F) -or
        ($CodePoint -ge 0xAC00 -and $CodePoint -le 0xD7A3) -or
        ($CodePoint -ge 0xF900 -and $CodePoint -le 0xFAFF) -or
        ($CodePoint -ge 0xFE10 -and $CodePoint -le 0xFE19) -or
        ($CodePoint -ge 0xFE30 -and $CodePoint -le 0xFE6F) -or
        ($CodePoint -ge 0xFF00 -and $CodePoint -le 0xFF60) -or
        ($CodePoint -ge 0xFFE0 -and $CodePoint -le 0xFFE6) -or
        ($CodePoint -ge 0x1B000 -and $CodePoint -le 0x1B001) -or
        ($CodePoint -ge 0x1F200 -and $CodePoint -le 0x1F2FF) -or
        ($CodePoint -ge 0x1F300 -and $CodePoint -le 0x1F64F) -or
        ($CodePoint -ge 0x1F680 -and $CodePoint -le 0x1F6FF) -or
        ($CodePoint -ge 0x1F900 -and $CodePoint -le 0x1F9FF) -or
        ($CodePoint -ge 0x1FA70 -and $CodePoint -le 0x1FAFF) -or
        ($CodePoint -ge 0x20000 -and $CodePoint -le 0x3FFFD)
    )
}

# 1 文字(コードポイント)の桁数。結合文字は 0、全角は 2、それ以外は 1
function Get-CharWidth {
    param([int]$CodePoint)
    if ($CodePoint -ge 0xD800 -and $CodePoint -le 0xDFFF) { return 1 }
    $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory([char]::ConvertFromUtf32($CodePoint), 0)
    if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { return 0 }
    if (Test-WideCodePoint $CodePoint) { return 2 }
    return 1
}

# Index から始まる 1 単位(ANSI エスケープまたは1文字)を返す
function Get-NextUnit {
    param([string]$Text, [int]$Index)
    $m = $script:ansiRegex.Match($Text, $Index)
    if ($m.Success) {
        return @{ Text = $m.Value; Width = 0; Next = $Index + $m.Length }
    }
    $ch = $Text[$Index]
    $len = 1
    $cp = [int]$ch
    if ([char]::IsHighSurrogate($ch) -and $Index + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$Index + 1])) {
        $cp = [char]::ConvertToUtf32($ch, $Text[$Index + 1])
        $len = 2
    }
    return @{ Text = $Text.Substring($Index, $len); Width = (Get-CharWidth $cp); Next = $Index + $len }
}

function Get-DisplayWidth {
    param([string]$Text)
    $w = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $u = Get-NextUnit $Text $i
        $w += $u.Width
        $i = $u.Next
    }
    return $w
}

function Format-TruncateVisible {
    param([string]$Text, [int]$Width)
    if ($Width -lt 1) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $u = Get-NextUnit $Text $i
        if ($u.Width -gt 0 -and $w + $u.Width -gt $Width) { break }
        [void]$sb.Append($u.Text)
        $w += $u.Width
        $i = $u.Next
    }
    return $sb.ToString()
}

function Format-Fit {
    param([string]$Text, [int]$Width)
    if ($Width -lt 1) { return '' }
    $t = Format-TruncateVisible $Text $Width
    $pad = $Width - (Get-DisplayWidth $t)
    if ($pad -gt 0) { $t += (' ' * $pad) }
    return $t
}

function Format-Wrap {
    param([string]$Text, [int]$Width)
    if ($Width -lt 1) { $Width = 1 }
    $lines = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $curW = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $u = Get-NextUnit $Text $i
        if ($u.Width -gt 0 -and $curW + $u.Width -gt $Width -and $curW -gt 0) {
            $lines.Add($cur.ToString())
            [void]$cur.Clear()
            $curW = 0
        }
        [void]$cur.Append($u.Text)
        $curW += $u.Width
        $i = $u.Next
    }
    if ($cur.Length -gt 0 -or $lines.Count -eq 0) { $lines.Add($cur.ToString()) }
    return , $lines
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

# run の保持する行に足し、多すぎたら古い行から捨てる(columns の描画用)
function Add-Lines {
    param([string]$RunName, $Texts)
    $st = $tracked[$RunName]
    foreach ($t in $Texts) { $st.lines.Add($t) }
    if ($st.lines.Count -gt $maxLines) {
        $st.lines.RemoveRange(0, $st.lines.Count - $maxLines)
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
    $decoded = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) { $decoded.Add((ConvertFrom-LogBytes $ln)) }
    Add-Lines $RunName $decoded
    if ($layout -eq 'stream' -and $tailLines -ne 0) {
        $from = [Math]::Max(0, $decoded.Count - $tailLines)
        for ($i = $from; $i -lt $decoded.Count; $i++) {
            Write-Line $RunName $decoded[$i]
        }
    }
    $st.lastNew = Get-Now
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
        $st.lines.Clear()
        if ($layout -eq 'stream') { Write-Line $RunName '--- log truncated' }
    }
    if ($size -eq $st.pos) { return }
    $data = Read-LogFrom $path $st.pos
    if ($null -eq $data) { return }
    $lines = Split-Lines $st $data
    if ($null -eq $lines) { return }
    $st.pos += $data.Length
    $decoded = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) { $decoded.Add((ConvertFrom-LogBytes $ln)) }
    Add-Lines $RunName $decoded
    if ($layout -eq 'stream') {
        foreach ($ln in $decoded) { Write-Line $RunName $ln }
    }
    if ($decoded.Count -gt 0) { $st.lastNew = Get-Now }
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
        if ($tracked.ContainsKey($n)) { continue }
        $order.Add($n)
        $tracked[$n] = @{
            pos = [long]0; buf = [byte[]]@(); raw = [byte[]]@(); enc = $null;
            lines = (New-Object System.Collections.Generic.List[string]);
            status = 'running'; exit = $null; lastNew = (Get-Now)
        }
        if ($layout -eq 'stream') { Write-Line $n "--- watching (updated $(Get-UpdateClock $n))" }
        Read-First $n
    }
}

function Invoke-Poll {
    Find-Runs
    $now = Get-Now
    foreach ($n in @($order)) {
        if (-not $tracked.ContainsKey($n)) { continue }
        $st = $tracked[$n]
        if ($st.status -ne 'running') { continue }
        $isDone = Test-Path -LiteralPath (Get-RunPath $n 'done')
        Read-New $n
        if ($isDone) {
            if ($st.buf.Length -gt 0) {
                $last = ConvertFrom-LogBytes $st.buf
                $st.buf = [byte[]]@()
                Add-Lines $n @($last)
                if ($layout -eq 'stream') { Write-Line $n $last }
            }
            $st.status = 'finished'
            $st.exit = Get-FinalExitValue $n
            if ($layout -eq 'stream') { Write-Line $n "--- finished ($($st.exit))" }
        }
    }
    if ($layout -eq 'stream') {
        foreach ($n in @($order)) {
            if (-not $tracked.ContainsKey($n)) { continue }
            $st = $tracked[$n]
            if ($st.status -ne 'running') { continue }
            if ($now - $st.lastNew -ge $noOutputEvery) {
                $old = [int]($now - $st.lastNew)
                Write-Line $n "--- no output for ${old}s (updated $(Get-UpdateClock $n))"
                $st.lastNew = $now
            }
        }
    }
}

# 列の 2 行目。幅に入らないときは `(<N>s ago)` を外し、それでも入らなければ先頭の `updated ` も外す
function Format-Header2 {
    param([string]$RunName, [int]$Width)
    $st = $tracked[$RunName]
    $epoch = Get-UpdateEpoch $RunName
    if ($null -eq $epoch) {
        $ago = 0
    } else {
        $ago = [Math]::Max(0, [int]((Get-Now) - $epoch))
    }
    $clock = Get-UpdateClock $RunName
    if ($st.status -eq 'finished') {
        $exitText = 'unknown'
        if ($null -ne $st.exit) { $exitText = $st.exit }
        $right = "finished ($exitText)"
    } else {
        $right = 'running'
    }
    $forms = @(
        "updated $clock (${ago}s ago) $right",
        "updated $clock $right",
        "$clock $right"
    )
    foreach ($form in $forms) {
        if ((Get-DisplayWidth $form) -le $Width) { return (Format-Fit $form $Width) }
    }
    return (Format-Fit $forms[2] $Width)
}

function Format-Column {
    param([string]$RunName, [int]$Width, [int]$Avail)
    $st = $tracked[$RunName]
    $name = Format-TruncateVisible $RunName $Width
    if ($useColor) {
        $color = 31 + ($order.IndexOf($RunName) % 6)
        $name = "$esc[${color}m$name$esc[0m"
    }
    $col = New-Object System.Collections.Generic.List[string]
    $col.Add((Format-Fit $name $Width))
    $col.Add((Format-Header2 $RunName $Width))
    $col.Add(('-' * $Width))
    $wrapped = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $st.lines) {
        foreach ($wl in (Format-Wrap $ln $Width)) { $wrapped.Add($wl) }
    }
    $tailCount = [Math]::Min($Avail, $wrapped.Count)
    if ($tailCount -lt 0) { $tailCount = 0 }
    for ($i = $wrapped.Count - $tailCount; $i -lt $wrapped.Count; $i++) {
        $col.Add((Format-Fit $wrapped[$i] $Width))
    }
    return , $col
}

function Get-ScreenSize {
    $w = 0
    $h = 0
    if ($null -ne $optWidth) {
        $w = $optWidth
    } else {
        try { $w = [Console]::WindowWidth } catch { $w = 0 }
    }
    if ($null -ne $optHeight) {
        $h = $optHeight
    } else {
        try { $h = [Console]::WindowHeight } catch { $h = 0 }
    }
    if ($w -le 0) { $w = 120 }
    if ($h -le 0) { $h = 30 }
    return @([int]$w, [int]$h)
}

function Build-Frame {
    $size = Get-ScreenSize
    $width = $size[0]
    $height = $size[1]
    $allruns = New-Object System.Collections.Generic.List[string]
    foreach ($r in $order) {
        if ($tracked.ContainsKey($r)) { $allruns.Add($r) }
    }
    $capacity = [int][Math]::Floor(($width + 3) / 33)
    if ($capacity -lt 1) { $capacity = 1 }
    $shown = New-Object System.Collections.Generic.List[string]
    if ($allruns.Count -le $capacity) {
        foreach ($r in $allruns) { $shown.Add($r) }
    } else {
        # 実行中を優先し、そのあと終わった run、残りは見つけた順
        foreach ($r in $allruns) {
            if ($tracked[$r].status -eq 'running' -and $shown.Count -lt $capacity) { $shown.Add($r) }
        }
        foreach ($r in $allruns) {
            if ($tracked[$r].status -eq 'finished' -and $shown.Count -lt $capacity) { $shown.Add($r) }
        }
        foreach ($r in $allruns) {
            if (-not $shown.Contains($r) -and $shown.Count -lt $capacity) { $shown.Add($r) }
        }
        $sorted = @($shown | Sort-Object { $allruns.IndexOf($_) })
        $shown = New-Object System.Collections.Generic.List[string]
        foreach ($r in $sorted) { $shown.Add($r) }
    }
    $overflow = New-Object System.Collections.Generic.List[string]
    foreach ($r in $allruns) {
        if (-not $shown.Contains($r)) { $overflow.Add($r) }
    }
    $frame = New-Object System.Collections.Generic.List[string]
    if ($shown.Count -eq 0) {
        $frame.Add((Format-TruncateVisible '(no runs)' $width))
        return , $frame
    }
    $n = $shown.Count
    $colW = [int][Math]::Floor(($width - 3 * ($n - 1)) / $n)
    if ($colW -lt 1) { $colW = 1 }
    $avail = $height - 3
    if ($overflow.Count -gt 0) { $avail -= 1 }
    if ($avail -lt 0) { $avail = 0 }
    $cols = New-Object System.Collections.Generic.List[object]
    foreach ($r in $shown) { $cols.Add((Format-Column $r $colW $avail)) }
    $sep = " $([char]0x2502) "
    for ($row = 0; $row -lt (3 + $avail); $row++) {
        $cells = New-Object System.Collections.Generic.List[string]
        foreach ($col in $cols) {
            $text = ''
            if ($row -lt $col.Count) { $text = $col[$row] }
            $cells.Add((Format-Fit $text $colW))
        }
        $frame.Add(($cells -join $sep))
    }
    if ($overflow.Count -gt 0) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($r in $overflow) { $parts.Add("$r (updated $(Get-UpdateClock $r))") }
        $line = "+$($overflow.Count) more: $($parts -join ', ')"
        if ((Get-DisplayWidth $line) -gt $width) {
            if ($width -gt 4) {
                $line = (Format-TruncateVisible $line ($width - 4)) + ' ...'
            } else {
                $line = Format-TruncateVisible $line $width
            }
        }
        $frame.Add($line)
    }
    return , $frame
}

function Render-Columns {
    param([bool]$AltScreen)
    $frame = Build-Frame
    if ($AltScreen) { $stdout.Write("$esc[H$esc[2J") }
    $stdout.Write((($frame -join "`n") + "`n"))
    $stdout.Flush()
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

# 出力が端末のときだけ、出力コードページを UTF-8(BOM なし)にする(日本語環境の 932 では、UTF-8 のバイト列が化ける)。
# 元の値は finally で戻す。リダイレクトされているときは変えない
$origOutputEncoding = $null
if (-not [Console]::IsOutputRedirected) {
    try {
        $origOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = $utf8
    } catch {
        $origOutputEncoding = $null
    }
}
# columns で端末に出すときは代替画面に切り替える(-Once とリダイレクトでは制御を入れない)
$alt = ($layout -eq 'columns') -and (-not $Once) -and (-not [Console]::IsOutputRedirected)
if ($alt) {
    $stdout.Write("$esc[?1049h$esc[H$esc[2J")
    $stdout.Flush()
}
try {
    while ($true) {
        Invoke-Poll
        if ($layout -eq 'columns') { Render-Columns $alt }
        if ($Once) { break }
        if ($runNames.Count -gt 0 -and @($runNames | Where-Object { -not ($tracked.ContainsKey($_) -and $tracked[$_].status -eq 'finished') }).Count -eq 0) { break }
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
    if ($alt) {
        try {
            $stdout.Write("$esc[?1049l")
            $stdout.Flush()
        } catch { }
    }
    if ($null -ne $origTreatCtrlC) { [Console]::TreatControlCAsInput = $origTreatCtrlC }
    if ($null -ne $origOutputEncoding) {
        try { [Console]::OutputEncoding = $origOutputEncoding } catch { }
    }
}
exit 0
