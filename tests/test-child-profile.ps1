# childprofile.ps1(子CLIプロファイルの解決, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# Set-ChildAgent <profile|""> <command_template>: config.json の child_agent を書き換える
function Set-ChildAgent {
    param([string]$Profile, [string]$CommandTemplate)
    $path = "$script:Proj/.agents/workflow/config.json"
    $config = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($Profile) {
        $config.child_agent | Add-Member -NotePropertyName profile -NotePropertyValue $Profile -Force
    } else {
        $config.child_agent.PSObject.Properties.Remove('profile')
    }
    $config.child_agent | Add-Member -NotePropertyName command_template -NotePropertyValue $CommandTemplate -Force
    Write-Utf8File $path (($config | ConvertTo-Json -Depth 10) + "`n")
}

# Invoke-Profile: Get-ChildProfile を呼び $script:Prof / $script:Err / $script:Code を設定する
function Invoke-Profile {
    $script:Prof = $null
    $script:Err = ''
    $script:Code = 0
    . "$script:Proj/.agents/workflow/scripts/childprofile.ps1"
    try {
        $script:Prof = Get-ChildProfile -Root $script:Proj
    } catch {
        $script:Code = 1
        $script:Err = $_.Exception.Message
    }
}

Write-Host "test-child-profile.ps1"

Invoke-TestCase "profile: 未指定は auto で、command_template に stream-json があれば claude-stream-json の出力形式" {
    Set-ChildAgent "" 'claude -p "{prompt}" --output-format stream-json --verbose'
    Invoke-Profile
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "auto" $script:Prof.Name "name"
    Assert-Eq "claude-stream-json" $script:Prof.OutputFormat "output_format resolved from command_template"
    Assert-Eq "False" $script:Prof.AgentsMdImports "agents_md_imports"
    Set-ChildAgent "" 'opencode run "{prompt}"'
    Invoke-Profile
    Assert-Eq "text" $script:Prof.OutputFormat "output_format is text without stream-json"
}

Invoke-TestCase "profile: 利用先の child-profiles.json が同名の組み込み定義を置き換える" {
    Write-Utf8File "$script:Proj/.agents/workflow/child-profiles.json" "{`"opencode`": {`"output_format`": `"text`", `"permission_denied_pattern`": `"^DENIED: `"}}`n"
    Set-ChildAgent "opencode" 'opencode run "{prompt}"'
    Invoke-Profile
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "opencode" $script:Prof.Name "name"
    Assert-Eq "" $script:Prof.ToolActivityPattern "tool_activity_pattern is empty (replaced)"
    Assert-Eq "^DENIED: " $script:Prof.PermissionDeniedPattern "permission_denied_pattern from project"
}

Invoke-TestCase "profile: 未定義の名前は exit 1" {
    Set-ChildAgent "nope" 'opencode run "{prompt}"'
    Invoke-Profile
    Assert-Eq 1 $script:Code "unknown profile rejected"
    Assert-Contains $script:Err "Unknown child profile: nope (defined: auto, claude-stream-json, opencode, plain)" "message"
}

Show-Summary
