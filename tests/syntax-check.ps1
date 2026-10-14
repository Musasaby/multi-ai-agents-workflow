# このリポジトリの品質ゲート(子エージェントの検証コマンド)。リポジトリルートから実行する。
#   1. _templates/workflow/scripts と tests の .ps1 をパースし、.sh を bash -n で構文チェックする
#   2. git 管理下と未追跡(.gitignore 対象外)のテキストファイルについて、改行コードと BOM を検査する
#      - CRLF を含むファイルは失敗(.gitattributes で全ファイル LF に固定している)
#      - 非 ASCII 文字を含む .ps1 に BOM が無ければ失敗(Windows PowerShell 5.1 が UTF-8 と認識しないため)
#      - .sh / .py に BOM があれば失敗(bash / python が先頭行を正しく読めないため)
# 検査対象はリポジトリルートの正本(`.agents/` 配下のミラーは検査しない)。
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path "$PSScriptRoot/..")
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$failed = $false

$scriptDirs = @("_templates/workflow/scripts", "tests")

foreach ($dir in $scriptDirs) {
    foreach ($f in Get-ChildItem "$dir/*.ps1") {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            Write-Host "PARSE ERROR: $dir/$($f.Name)"
            $errs | ForEach-Object { Write-Host "  $($_.Extent.StartLineNumber): $($_.Message)" }
            $failed = $true
        } else {
            Write-Host "OK (ps1): $dir/$($f.Name)"
        }
    }
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
    foreach ($dir in $scriptDirs) {
        foreach ($f in Get-ChildItem "$dir/*.sh") {
            & bash -n "$dir/$($f.Name)"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "SYNTAX ERROR: $dir/$($f.Name)"
                $failed = $true
            } else {
                Write-Host "OK (sh): $dir/$($f.Name)"
            }
        }
    }
} else {
    Write-Host "bash が見つからないため .sh の構文チェックをスキップ"
}

# 改行コード・BOM の検査(git 管理下 + 未追跡の新規ファイル)
# core.quotepath=off: 日本語名のファイルが引用符付きの8進表記になり、検査から漏れるのを防ぐ
$files = @(git -c core.quotepath=off ls-files) + @(git -c core.quotepath=off ls-files --others --exclude-standard) | Sort-Object -Unique
foreach ($rel in $files) {
    if (-not (Test-Path -LiteralPath $rel -PathType Leaf)) { continue }  # 削除済み
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $rel).Path)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }  # バイナリ
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasCrlf = $false
    $hasNonAscii = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 0x7F) { $hasNonAscii = $true }
        if ($bytes[$i] -eq 0x0D -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) { $hasCrlf = $true }
        if ($hasCrlf -and $hasNonAscii) { break }
    }
    if ($hasCrlf) {
        Write-Host "EOL ERROR (CRLF を含む。LF で保存すること): $rel"
        $failed = $true
    }
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($ext -eq '.ps1' -and $hasNonAscii -and -not $hasBom) {
        Write-Host "BOM ERROR (非 ASCII 文字を含む .ps1 は BOM 付き UTF-8 で保存すること): $rel"
        $failed = $true
    }
    if (($ext -eq '.sh' -or $ext -eq '.py') -and $hasBom) {
        Write-Host "BOM ERROR ($ext は BOM なしで保存すること): $rel"
        $failed = $true
    }
}
Write-Host "EOL/BOM: $($files.Count) files checked"

if ($failed) { exit 1 } else { Write-Host "ALL CHECKS PASSED"; exit 0 }
