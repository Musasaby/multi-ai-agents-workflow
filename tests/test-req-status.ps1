# req-status(要件ごとの状態一覧, PowerShell版)
. "$PSScriptRoot/lib.ps1"

# commit 付きの state.json を書く: Set-StateCommit 'T1:done:abcdef1234567' 'T2:pending' ...
# (lib.ps1 の Set-State は commit を null 固定にするため、ここで定義する)
function Set-StateCommit {
    $tasks = foreach ($item in $args) {
        $parts = $item -split ':'
        $commit = if ($parts.Count -gt 2) { $parts[2] } else { $null }
        [ordered]@{ id = $parts[0]; title = "$($parts[0]) title"; status = $parts[1]; retries = 0; commit = $commit }
    }
    $state = [ordered]@{ source = 'test'; branch = 'main'; updated_at = 'x'; tasks = @($tasks) }
    Write-Utf8File "$script:Proj/.agents/workflow/state.json" ($state | ConvertTo-Json -Depth 10)
}

Write-Host "test-req-status.ps1"

Invoke-TestCase "req-status: 要件ごとの状態と集計を出す" {
    Set-Tasks @'
## 要件
- R1: 一つ目
- R2: 二つ目
- R3: 三つ目

## T1: a
- **要件**: R1
- **依存**: なし

## T2: b
- **要件**: R1, R3
- **依存**: T1

## T3: c
- **要件**: R2
- **依存**: なし

## T4: d
- **要件**: なし
- **依存**: なし
'@
    Set-StateCommit 'T1:done:abcdef1234567' 'T2:pending' 'T3:done:1234567abcdef' 'T4:in_review'
    Invoke-Script req-status.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Out "Requirement R1 [partial]: T1(done abcdef1), T2(pending) | 一つ目" "R1 行"
    Assert-Contains $script:Out "Requirement R2 [done]: T3(done 1234567) | 二つ目" "R2 行"
    Assert-Contains $script:Out "Requirement R3 [pending]: T2(pending) | 三つ目" "R3 行"
    Assert-Contains $script:Out "Requirement なし: T4(in_review)" "なし行"
    Assert-Contains $script:Out "Summary: done=1 partial=1 pending=1" "集計行"
}

Invoke-TestCase "req-status: 要件の節が無ければその旨を出してexit 0" {
    Set-Tasks @'
## T1: a
- **依存**: なし
'@
    Set-State 'T1:pending'
    Invoke-Script req-status.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Eq "No requirements section" $script:Out "節が無い旨"
}

Invoke-TestCase "req-status: どのタスクにも対応しない要件はexit 1" {
    Set-Tasks @'
## 要件
- R1: 一つ目
- R2: 二つ目

## T1: a
- **要件**: R1
- **依存**: なし
'@
    Set-State 'T1:pending'
    Invoke-Script req-status.ps1
    Assert-Eq 1 $script:Code "exit 1"
    Assert-Contains $script:Err "Uncovered requirement: R2" "未対応の要件"
}

Invoke-TestCase "req-status: state.json に無いタスクは missing と出す" {
    Set-Tasks @'
## 要件
- R1: 一つ目

## T1: a
- **要件**: R1
- **依存**: なし

## T2: b
- **要件**: R1
- **依存**: T1
'@
    Set-StateCommit 'T1:done:abcdef1234567'
    Invoke-Script req-status.ps1
    Assert-Eq 0 $script:Code "exit: $($script:Err)"
    Assert-Contains $script:Out "T2(missing)" "state.json に無いタスクは missing"
}

Show-Summary
