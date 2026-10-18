# 子CLIプロファイルの解決(PowerShell版スクリプト共通)。dot-source して Get-ChildProfile -Root <root> を使う。
# childprofile.py の load_profile と同じ解決処理。
# 組み込み定義は同じディレクトリの child-profiles.json、利用先定義は
# <root>/.agents/workflow/child-profiles.json(同名エントリは組み込みを丸ごと置き換える)。

$script:ChildProfileScriptDir = $PSScriptRoot
$script:ChildProfilePatternKeys = @('tool_activity_pattern', 'tool_call_pattern', 'permission_denied_pattern', 'provider_error_pattern')

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

function Get-ChildProfile {
    param([Parameter(Mandatory)][string]$Root)

    $name = ''
    $commandTemplate = ''
    try {
        $config = Get-Content -LiteralPath (Join-Path $Root '.agents/workflow/config.json') -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $child = if ($config -is [pscustomobject]) { $config.child_agent } else { $null }
        if ($child -is [pscustomobject]) {
            if ($child.profile -is [string]) { $name = $child.profile }
            if ($child.command_template -is [string]) { $commandTemplate = $child.command_template }
        }
    } catch {
        $name = ''
        $commandTemplate = ''
    }
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
