# 子CLIプロファイルの解決(PowerShell版スクリプト共通)。dot-source して Get-ChildProfile -Root <root> を使う。
# childprofile.py の load_profile と同じ解決処理。
# 組み込み定義は同じディレクトリの child-profiles.json、利用先定義は
# <root>/.agents/workflow/child-profiles.json(同名エントリは組み込みを丸ごと置き換える)。

$script:ChildProfileScriptDir = $PSScriptRoot
$script:ChildProfilePatternKeys = @('tool_activity_pattern', 'tool_call_pattern', 'permission_denied_pattern', 'provider_error_pattern')
$script:ChildProfileReviewPrefix = 'review-'
$script:ChildProfileReviewKeys = @('command_template', 'profile', 'subagent', 'subagent_model')

function Read-ChildProfileDefinitions {
    param([string]$Path)
    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { throw 'empty JSON' }
    } catch {
        throw "Cannot read child profiles: $Path ($($_.Exception.Message))"
    }
    if ($data -isnot [pscustomobject]) {
        throw "Child profiles must be a JSON object: $Path"
    }
    $result = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($prop in $data.PSObject.Properties) {
        if ($prop.Value -isnot [pscustomobject]) {
            throw "Child profile must be a JSON object: $($prop.Name) ($Path)"
        }
        $result[$prop.Name] = $prop.Value
    }
    return $result
}

function Get-AgentConfig {
    param([Parameter(Mandatory)][string]$Root, [string]$TaskId = '')

    $result = @{}
    try {
        $config = Get-Content -LiteralPath (Join-Path $Root '.agents/workflow/config.json') -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $result
    }
    if ($config -isnot [pscustomobject]) { return $result }
    $child = $config.child_agent
    if ($child -is [pscustomobject]) {
        foreach ($prop in $child.PSObject.Properties) { $result[$prop.Name] = $prop.Value }
    }
    if ($TaskId -and $TaskId.StartsWith($script:ChildProfileReviewPrefix, [StringComparison]::Ordinal)) {
        $review = $config.review
        foreach ($key in $script:ChildProfileReviewKeys) {
            $value = if (($review -is [pscustomobject]) -and $review.PSObject.Properties[$key]) { $review.$key } else { $null }
            $result[$key] = if ($value -is [string]) { $value } else { '' }
        }
    }
    return $result
}

function Get-ChildProfile {
    param([Parameter(Mandatory)][string]$Root, [string]$Name = '', [string]$TaskId = '')

    $override = $Name
    $config = Get-AgentConfig -Root $Root -TaskId $TaskId
    $name = if ($config['profile'] -is [string]) { $config['profile'] } else { '' }
    $commandTemplate = if ($config['command_template'] -is [string]) { $config['command_template'] } else { '' }
    if ($override) { $name = $override }
    if (-not $name) { $name = 'auto' }

    $definitions = Read-ChildProfileDefinitions (Join-Path $script:ChildProfileScriptDir 'child-profiles.json')
    $custom = Join-Path $Root '.agents/workflow/child-profiles.json'
    if (Test-Path -LiteralPath $custom -PathType Leaf) {
        $overrides = Read-ChildProfileDefinitions $custom
        foreach ($key in $overrides.Keys) { $definitions[$key] = $overrides[$key] }
    }

    if (-not $definitions.ContainsKey($name)) {
        [string[]]$names = @($definitions.Keys)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        throw "Unknown child profile: $name (defined: $($names -join ', '))"
    }
    $entry = $definitions[$name]

    $outputFormat = if ($entry.PSObject.Properties['output_format']) { $entry.output_format } else { '' }
    if ($outputFormat -is [string] -and $outputFormat -ceq 'auto') {
        $outputFormat = if ($commandTemplate.Contains('stream-json')) { 'claude-stream-json' } else { 'text' }
    }
    if ($outputFormat -isnot [string] -or ($outputFormat -cne 'text' -and $outputFormat -cne 'claude-stream-json')) {
        throw "Invalid output_format in child profile ${name}: $outputFormat"
    }

    $patterns = @{}
    foreach ($key in $script:ChildProfilePatternKeys) {
        $value = if ($entry.PSObject.Properties[$key]) { $entry.$key } else { '' }
        if ($value -isnot [string]) { $value = '' }
        if ($value.Contains("`n") -or $value.Contains("`r")) {
            throw "Pattern must be a single line: $name.$key"
        }
        $patterns[$key] = $value
    }
    $imports = $entry.PSObject.Properties['agents_md_imports'] -and ($entry.agents_md_imports -is [bool]) -and $entry.agents_md_imports

    return [pscustomobject]@{
        Name                    = $name
        OutputFormat            = $outputFormat
        ToolActivityPattern     = $patterns['tool_activity_pattern']
        ToolCallPattern         = $patterns['tool_call_pattern']
        PermissionDeniedPattern = $patterns['permission_denied_pattern']
        ProviderErrorPattern    = $patterns['provider_error_pattern']
        AgentsMdImports         = [bool]$imports
    }
}
