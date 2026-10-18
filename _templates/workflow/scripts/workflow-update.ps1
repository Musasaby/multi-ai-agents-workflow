# 利用先で .agents/skills/ を upstream から git subtree pull で更新し、配置済みスクリプトとの差分を知らせる。
# 必ずテンプレート側のコピー(利用先では .agents/skills/_templates/workflow/scripts/)から実行する。
#
# Usage:
#   workflow-update.ps1
# 最後の行: Next: continue / confirm / escalate reason=<dirty-tree|conflict|subtree-failed>
# exit: 0=更新済みで配置済みスクリプトとの差分なし / 1=使い方不備・git の外 /
#       2=コンフリクト(CONFLICT <パス> を出力) / 3=更新済みで配置済みスクリプトに差分あり /
#       20=作業ツリーが汚れている / 21=subtree pull の失敗(コンフリクト以外)
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
    [Console]::Error.WriteLine("Run this script from the template copy (.agents/skills/_templates/workflow/scripts/), not from .agents/workflow/scripts/")
    exit 1
}

Set-Location $root

$dirty = @(git status --porcelain)
if ($dirty.Count -gt 0) {
    $dirty | ForEach-Object { [Console]::Error.WriteLine("$_") }
    Write-Output "Next: escalate reason=dirty-tree"
    exit 20
}

$url = ''
$branch = ''
try {
    $cfg = [System.IO.File]::ReadAllText((Join-Path $destRoot 'config.json'), [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    if ($cfg.upstream) {
        if ($cfg.upstream.url) { $url = "$($cfg.upstream.url)" }
        if ($cfg.upstream.branch) { $branch = "$($cfg.upstream.branch)" }
    }
} catch {
    # 読めなければデフォルト値で続行する
}
if (-not $url) { $url = 'https://github.com/Musasaby/multi-ai-agents-workflow.git' }
if (-not $branch) { $branch = 'main' }
Write-Output "Upstream: $url $branch"

git subtree pull --prefix=.agents/skills $url $branch --squash -m "chore: .agents/skills を upstream から更新"
if ($LASTEXITCODE -ne 0) {
    $conflicts = @(git diff --name-only --diff-filter=U)
    if ($conflicts.Count -gt 0) {
        $conflicts | ForEach-Object { Write-Output "CONFLICT $_" }
        Write-Output "Next: escalate reason=conflict"
        exit 2
    }
    Write-Output "Next: escalate reason=subtree-failed"
    exit 21
}

& pwsh -NoProfile -File (Join-Path $templateScripts 'workflow-sync-scripts.ps1')
if ($LASTEXITCODE -eq 3) {
    Write-Output "Next: confirm"
    exit 3
}
Write-Output "Next: continue"
exit 0
