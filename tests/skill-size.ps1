# skill のサイズ上限と references のリンク先を検査する。
#   (1) リポジトリルート直下の agent-*/SKILL.md・agents-md-setup/SKILL.md・workflow-update/SKILL.md の
#       バイト数が FileLimit 以下であること
#   (2) 実装ループで読み込む agent-workflow・agent-dispatch・agent-review-commit の合計が LoopLimit 以下であること
#   (3) SKILL.md と references/*.md の中の `references/<名前>.md`(`<skill名>/references/<名前>.md` も可)の
#       リンク先が存在すること。`references/<CLI>.md` のように < を含む書き方は対象外
#   FAIL が 1 件でもあれば exit 1、無ければ SKILL SIZE OK を出して exit 0。
param(
    [int]$LoopLimit = 30000,
    [int]$FileLimit = 18000
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$failed = $false

$skillFiles = @(
    Get-ChildItem -Path $root -Directory |
        Where-Object { $_.Name -like 'agent-*' -or $_.Name -eq 'agents-md-setup' -or $_.Name -eq 'workflow-update' } |
        Sort-Object Name |
        ForEach-Object { Join-Path $_.FullName 'SKILL.md' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)

$loopSkills = @('agent-workflow', 'agent-dispatch', 'agent-review-commit')
$loopTotal = 0
foreach ($f in $skillFiles) {
    $rel = $f.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
    $size = (Get-Item -LiteralPath $f).Length
    Write-Host "SKILL size: $rel $size"
    if ($size -gt $FileLimit) {
        Write-Host "FAIL: $rel $size > $FileLimit"
        $failed = $true
    }
    if ($loopSkills -contains (Split-Path -Leaf (Split-Path -Parent $f))) { $loopTotal += $size }
}
Write-Host "Loop total: $loopTotal / $LoopLimit"
if ($loopTotal -gt $LoopLimit) {
    Write-Host "FAIL: loop total $loopTotal > $LoopLimit"
    $failed = $true
}

$mdFiles = @()
foreach ($f in $skillFiles) {
    $mdFiles += $f
    $refDir = Join-Path (Split-Path -Parent $f) 'references'
    if (Test-Path -LiteralPath $refDir -PathType Container) {
        $mdFiles += @(Get-ChildItem -LiteralPath $refDir -Filter '*.md' -File | Sort-Object Name | ForEach-Object { $_.FullName })
    }
}
$pattern = '`(?:([\w-]+)/)?references/([\w.-]+\.md)'
$linkPattern = '\]\(([^)\s#]*references/[\w.-]+\.md)(?:#[^)]*)?\)'
foreach ($f in $mdFiles) {
    $dir = Split-Path -Parent $f
    $skillDir = if ((Split-Path -Leaf $dir) -eq 'references') { Split-Path -Parent $dir } else { $dir }
    $rel = $f.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
    $text = [System.IO.File]::ReadAllText($f)
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $base = if ($m.Groups[1].Success) { Join-Path $root $m.Groups[1].Value } else { $skillDir }
        $target = Join-Path (Join-Path $base 'references') $m.Groups[2].Value
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $shown = $target.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
            Write-Host "FAIL: broken reference $rel -> $shown"
            $failed = $true
        }
    }
    # Markdown リンク [説明](相対パス/references/x.md#見出し)。リンクを含むファイルのディレクトリからの相対パスで解決する
    foreach ($m in [regex]::Matches($text, $linkPattern)) {
        $target = [System.IO.Path]::GetFullPath((Join-Path $dir $m.Groups[1].Value))
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $shown = $target.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
            Write-Host "FAIL: broken reference $rel -> $shown"
            $failed = $true
        }
    }
}

if ($failed) { exit 1 }
Write-Host "SKILL SIZE OK"
exit 0
