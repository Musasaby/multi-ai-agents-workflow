# 利用先で npx skills update のあとに実行し、npx skills で導入済みかと、配置済みスクリプトとの差分を確かめる。
# 必ずテンプレート側のコピー(利用先では .agents/skills/agents-md-setup/templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-update.ps1
# 最後の行: Next: continue / confirm / escalate reason=<not-npx|sync-failed>
# exit: 0=配置済みスクリプトとの差分なし / 1=使い方不備・git の外 /
#       2=npx skills で導入されていない(ルートに skills-lock.json が無い) /
#       3=配置済みスクリプトに差分あり / 22=配置済みスクリプトとの差分確認(workflow-sync-scripts)の失敗
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine("Unknown argument: $($args[0])")
    exit 1
}

$templateScripts = $PSScriptRoot
$templateRoot = Split-Path $templateScripts -Parent
Push-Location $templateScripts
$root = "$(git rev-parse --show-toplevel 2>$null)".Trim()
Pop-Location
if (-not $root) {
    [Console]::Error.WriteLine("Not inside a git repository: $templateScripts")
    exit 1
}
$destRoot = Join-Path $root '.agents/workflow'
if ((Test-Path $destRoot) -and ((Resolve-Path $templateRoot).Path.TrimEnd('\', '/') -eq (Resolve-Path $destRoot).Path.TrimEnd('\', '/'))) {
    [Console]::Error.WriteLine("Run this script from the template copy (.agents/skills/agents-md-setup/templates/workflow/scripts/), not from .agents/workflow/scripts/")
    exit 1
}

Set-Location $root

if (-not (Test-Path -LiteralPath (Join-Path $root 'skills-lock.json') -PathType Leaf)) {
    [Console]::Error.WriteLine("skills-lock.json not found: install the skills with 'npx skills add' (see README: git subtree からの移行手順)")
    Write-Output "Next: escalate reason=not-npx"
    exit 2
}

& pwsh -NoProfile -File (Join-Path $templateScripts 'workflow-sync-scripts.ps1')
$syncCode = $LASTEXITCODE
if ($syncCode -eq 0) { Write-Output "Next: continue"; exit 0 }
if ($syncCode -eq 3) { Write-Output "Next: confirm"; exit 3 }
[Console]::Error.WriteLine("workflow-sync-scripts.ps1 failed (exit $syncCode)")
Write-Output "Next: escalate reason=sync-failed"
exit 22
