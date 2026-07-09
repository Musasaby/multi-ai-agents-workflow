param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
Set-Location $PSScriptRoot\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:XDG_CONFIG_HOME = ".agents/workflow/.config"
$env:XDG_DATA_HOME = ".agents/workflow/.config"
$logDir = ".agents/workflow/logs"
$null = New-Item -ItemType Directory -Force $logDir
$logPath = "$logDir/$TaskId-$Attempt.log"
$donePath = "$logDir/$TaskId-$Attempt.done"
Remove-Item -Force -ErrorAction SilentlyContinue $donePath
$promptPath = ".agents/workflow/.dispatch-prompt-$TaskId.md"
if (-not (Test-Path $promptPath)) { $promptPath = ".agents/workflow/.dispatch-prompt.md" }
$prompt = Get-Content $promptPath -Raw
$config = Get-Content ".agents/workflow/config.json" -Raw | ConvertFrom-Json

function Split-CommandLine {
    param([string]$cmd)
    $tokens = @()
    $current = ""
    $inQuotes = $false
    for ($i = 0; $i -lt $cmd.Length; $i++) {
        $c = $cmd[$i]
        if ($c -eq '"') {
            $inQuotes = !$inQuotes
        } elseif ($c -eq ' ' -and !$inQuotes) {
            if ($current -ne "") { $tokens += $current; $current = "" }
        } else {
            $current += $c
        }
    }
    if ($current -ne "") { $tokens += $current }
    return $tokens
}

try {
    $tokens = Split-CommandLine $config.child_agent.command_template
    $argList = @()
    foreach ($token in $tokens) {
        $arg = $token
        if ($arg.Length -ge 2 -and $arg[0] -eq '"' -and $arg[-1] -eq '"') {
            $arg = $arg.Substring(1, $arg.Length - 2)
        }
        $arg = $arg.Replace("{prompt}", $prompt)
        $argList += $arg
    }
    $exe = $argList[0]
    if ($argList.Count -gt 1) {
        $rest = $argList[1..($argList.Count - 1)]
        $null | & $exe @rest *> $logPath
    } else {
        $null | & $exe *> $logPath
    }
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $endTime = (Get-Date).ToString("o")
    "EXIT:$exitCode`nEND:$endTime" | Out-File -Encoding utf8 $donePath
} catch {
    $endTime = (Get-Date).ToString("o")
    "EXIT:crashed:$($_.Exception.Message)`nEND:$endTime" | Out-File -Encoding utf8 $donePath
}
