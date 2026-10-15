# sh / ps1 のテストケース名の差を機械的に検出する(Issue の C-2)。
#   行頭の test_case "<名前>"(.sh)と Invoke-TestCase "<名前>"(.ps1)からケース名を取り出し、
#   オプション名を正規化(--kebab-case → -KebabCase)してから比較する。
#   意図的な差は tests/case-parity-allow.txt(1 行 1 件で <テストファイル名>: <ケース名>、
#   # 以降はコメント、ケース名が * の行は当該ファイルの全ケースを許可)で管理する。
#   片方にしか無いテストファイルも、その全ケースを「片側にだけある」として検出する。
#   差があれば <テストファイル名>: sh にだけある: <ケース名> の形で全件出して exit 1。
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Convert-OptionName {
    param([string]$Name)
    [regex]::Replace($Name, '--[a-zA-Z0-9][a-zA-Z0-9-]*', {
        param($m)
        "-" + (($m.Value.Substring(2) -split '-' | ForEach-Object {
            if ($_) { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) } else { $_ }
        }) -join '')
    })
}

function Get-CaseNames {
    param([string]$Path, [string]$Pattern)
    @(foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match $Pattern) { Convert-OptionName $Matches[1] }
    })
}

$allow = @{}
foreach ($line in [System.IO.File]::ReadAllLines("$PSScriptRoot/case-parity-allow.txt")) {
    $trimmed = ($line -replace '#.*$', '').Trim()
    if ($trimmed -eq '') { continue }
    $i = $trimmed.IndexOf(':')
    if ($i -lt 1) { Write-Host "case-parity-allow.txt の行が不正: $line"; exit 1 }
    $key = $trimmed.Substring(0, $i).Trim()
    $allow[$key] = @($allow[$key]) + $trimmed.Substring($i + 1).Trim()
}

$patterns = @(
    @{ Ext = "sh"; Pattern = '^\s*test_case\s+"([^"]+)"' }
    @{ Ext = "ps1"; Pattern = '^\s*Invoke-TestCase\s+"([^"]+)"' }
)
$cases = @{}
foreach ($p in $patterns) {
    foreach ($f in Get-ChildItem "test-*.$($p.Ext)") {
        $cases["$($f.BaseName).$($p.Ext)"] = (Get-CaseNames $f.FullName $p.Pattern)
    }
}

$diffs = @()
foreach ($shFile in ($cases.Keys | Where-Object { $_ -like '*.sh' } | Sort-Object)) {
    $ps1File = ($shFile -replace '\.sh$', '') + ".ps1"
    $shNames = @($cases[$shFile])
    $ps1Names = if ($cases.ContainsKey($ps1File)) { @($cases[$ps1File]) } else { @() }
    $shAllow = @($allow[$shFile])
    $ps1Allow = @($allow[$ps1File])
    foreach ($n in ($shNames | Sort-Object -Unique)) {
        if ($ps1Names -notcontains $n -and $shAllow -notcontains '*' -and $shAllow -notcontains $n) {
            $diffs += "${shFile}: sh にだけある: $n"
        }
    }
    foreach ($n in ($ps1Names | Sort-Object -Unique)) {
        if ($shNames -notcontains $n -and $ps1Allow -notcontains '*' -and $ps1Allow -notcontains $n) {
            $diffs += "${ps1File}: ps1 にだけある: $n"
        }
    }
}
$ps1OnlyFiles = $cases.Keys | Where-Object { $_ -like '*.ps1' -and -not $cases.ContainsKey(($_ -replace '\.ps1$', '') + ".sh") }
foreach ($f in $ps1OnlyFiles) {
    $fAllow = @($allow[$f])
    foreach ($n in ($cases[$f] | Sort-Object -Unique)) {
        if ($fAllow -notcontains '*' -and $fAllow -notcontains $n) {
            $diffs += "${f}: ps1 にだけある: $n"
        }
    }
}

if ($diffs.Count -gt 0) {
    Write-Host "CASE PARITY ERRORS:"
    $diffs | ForEach-Object { Write-Host "  $_" }
    exit 1
}
$total = 0
foreach ($v in $cases.Values) { $total += $v.Count }
Write-Host "OK (case parity): $($cases.Count) files, $total cases, parity with case-parity-allow.txt"
exit 0
