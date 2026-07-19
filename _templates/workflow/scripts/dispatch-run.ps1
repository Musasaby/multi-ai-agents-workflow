param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [int]$Attempt = 1
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:XDG_CONFIG_HOME = ".agents/workflow/.config"
$env:XDG_DATA_HOME = ".agents/workflow/.config"
$runDir = ".agents/workflow/runs/$TaskId-$Attempt"
$null = New-Item -ItemType Directory -Force $runDir
$logPath = "$runDir/output.log"
$jsonlPath = "$runDir/output.jsonl"
$donePath = "$runDir/done"
Remove-Item -Force -ErrorAction SilentlyContinue $donePath
$promptPath = "$runDir/prompt.md"
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

function ConvertTo-HumanLine {
    param($obj)
    switch ($obj.type) {
        'assistant' {
            $lines = @()
            foreach ($block in $obj.message.content) {
                switch ($block.type) {
                    'text' { $lines += $block.text }
                    'tool_use' {
                        $inputJson = ($block.input | ConvertTo-Json -Compress -Depth 5)
                        if ($inputJson.Length -gt 300) { $inputJson = $inputJson.Substring(0, 300) + "...(truncated)" }
                        $lines += "[tool_use] $($block.name): $inputJson"
                    }
                    default { $lines += "[assistant:$($block.type)]" }
                }
            }
            return ($lines -join "`n")
        }
        'user' {
            $lines = @()
            foreach ($block in $obj.message.content) {
                if ($block.type -eq 'tool_result') {
                    $content = $block.content
                    if ($content -is [System.Array]) {
                        $text = ($content | ForEach-Object { $_.text }) -join "`n"
                    } else {
                        $text = "$content"
                    }
                    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + "...(truncated)" }
                    $lines += "[tool_result] $text"
                }
            }
            return ($lines -join "`n")
        }
        'result' {
            return "[result] exit_subtype=$($obj.subtype) result=$($obj.result)"
        }
        default {
            $compact = ($obj | ConvertTo-Json -Compress -Depth 5)
            if ($compact.Length -gt 300) { $compact = $compact.Substring(0, 300) + "...(truncated)" }
            return "[$($obj.type)] $compact"
        }
    }
}

try {
    $tokens = Split-CommandLine $config.child_agent.command_template
    $isStreamJson = $config.child_agent.command_template -match 'stream-json'
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
    $rest = if ($argList.Count -gt 1) { $argList[1..($argList.Count - 1)] } else { @() }

    if ($isStreamJson) {
        Remove-Item -Force -ErrorAction SilentlyContinue $jsonlPath, $logPath

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        foreach ($a in $rest) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $errAction = {
            $line = $Event.SourceEventArgs.Data
            if ($null -ne $line) {
                Add-Content -Path $Event.MessageData -Value $line -Encoding utf8
            }
        }
        $errJob = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errAction -MessageData $logPath

        try {
            $proc.Start() | Out-Null
            $proc.StandardInput.Close()
            $proc.BeginErrorReadLine()

            while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
                Add-Content -Path $jsonlPath -Value $line -Encoding utf8
                $human = $null
                try {
                    $obj = $line | ConvertFrom-Json
                    $human = ConvertTo-HumanLine $obj
                } catch {
                    $human = $line
                }
                if ($human) { Add-Content -Path $logPath -Value $human -Encoding utf8 }
            }
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
        } finally {
            Unregister-Event -SourceIdentifier $errJob.Name -ErrorAction SilentlyContinue
            Remove-Job -Id $errJob.Id -Force -ErrorAction SilentlyContinue
        }
    } else {
        if ($rest.Count -gt 0) {
            $null | & $exe @rest *> $logPath
        } else {
            $null | & $exe *> $logPath
        }
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    $endTime = (Get-Date).ToString("o")
    "EXIT:$exitCode`nEND:$endTime" | Out-File -Encoding utf8 $donePath
} catch {
    $endTime = (Get-Date).ToString("o")
    "EXIT:crashed:$($_.Exception.Message)`nEND:$endTime" | Out-File -Encoding utf8 $donePath
}
