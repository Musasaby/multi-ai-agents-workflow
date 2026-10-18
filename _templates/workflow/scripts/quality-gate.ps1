# config.json の quality_gate.steps を定義順に実行し、品質ゲートの合否を判定する。
# Usage: quality-gate.ps1 [-OutDir <ディレクトリ>]
#   各ステップの出力は <OutDir>/<name>.log に書く(UTF-8)
#   (-OutDir が無ければ .agents/workflow/runs/quality-gate-<YYYYMMDD-HHMMSS>/ を作る)
#   command が空のステップは SKIP。blocking のステップが失敗しても後続を実行する
# exit: 0=PASS / 1=使い方不備・config が読めない / 2=FAIL(blocking のステップが失敗) / 3=実行するステップが0件
param([string]$OutDir)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$configPath = '.agents/workflow/config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    [Console]::Error.WriteLine("config.json not found: $configPath")
    exit 1
}

$steps = @()
try {
    $config = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $configPath).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $qg = $config.quality_gate
    if ($null -ne $qg -and $null -ne $qg.steps) {
        foreach ($s in @($qg.steps)) {
            $command = if ($null -eq $s.command) { '' } else { ([string]$s.command) -replace "[`t`r`n]", ' ' }
            $steps += [pscustomobject]@{
                Name     = [string]$s.name
                Command  = $command
                Blocking = -not ($s.blocking -is [bool] -and $s.blocking -eq $false)
            }
        }
    }
} catch {
    [Console]::Error.WriteLine("Cannot read quality_gate.steps: $($_.Exception.Message)")
    exit 1
}

# 実行するステップ(command が空でないもの)が0件なら NO-STEPS
$runnable = @($steps | Where-Object { $_.Command -ne '' })
if ($runnable.Count -eq 0) {
    Write-Output 'Result: NO-STEPS'
    Write-Output 'Next: escalate reason=no-steps'
    exit 3
}

if (-not $OutDir) {
    $OutDir = ".agents/workflow/runs/quality-gate-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
try {
    $null = New-Item -ItemType Directory -Force -Path $OutDir -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("Cannot create out-dir: $OutDir")
    exit 1
}

$failed = @()
$blockingFailed = $false
foreach ($step in $steps) {
    $label = if ($step.Blocking) { 'blocking' } else { 'non-blocking' }
    if ($step.Command -eq '') {
        Write-Output "SKIP $($step.Name) ($label): "
        continue
    }
    $log = Join-Path $OutDir (($step.Name -replace '[^A-Za-z0-9._-]', '_') + '.log')
    $null | & pwsh -NoProfile -Command $step.Command *> $log   # 標準入力は空にする(sh 版の < /dev/null 相当)
    if ($LASTEXITCODE -eq 0) {
        Write-Output "PASS $($step.Name) ($label): $($step.Command)"
    } else {
        Write-Output "FAIL $($step.Name) ($label): $($step.Command)"
        $failed += [pscustomobject]@{ Name = $step.Name; Log = $log }
        if ($step.Blocking) { $blockingFailed = $true }
    }
}

foreach ($f in $failed) {
    Write-Output "--- $($f.Name) (last 20 lines)"
    Get-Content -LiteralPath $f.Log -Tail 20 -Encoding UTF8 | ForEach-Object { Write-Output $_ }
}

Write-Output "Logs: $OutDir"
if ($blockingFailed) {
    Write-Output 'Result: FAIL'
    Write-Output 'Next: escalate reason=quality-gate'
    exit 2
}
Write-Output 'Result: PASS'
Write-Output 'Next: continue'
exit 0
