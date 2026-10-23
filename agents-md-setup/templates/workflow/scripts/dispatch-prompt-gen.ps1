param(
    [string]$TaskId,
    [int]$Attempt = 1,
    [switch]$Pr
)
Set-Location $PSScriptRoot\..\..\..
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Get-Location
$TasksPath = "$Root/.agents/workflow/tasks.md"
$StatePath = "$Root/.agents/workflow/state.json"
$ConfigPath = "$Root/.agents/workflow/config.json"
$RunsBase = "$Root/.agents/workflow/runs"
. "$PSScriptRoot/tasklib.ps1"

# --- PR mode: PR作成を子に単発依頼するプロンプトを生成する ---
# 対象タスク = state.json で done かつ commit が git log origin/<base>..HEAD に含まれるもの。
# 出力先は runs/pr-<連番>-1/prompt.md。stdout に "RunId: pr-<連番>" を出す。
if ($Pr) {
    $baseBranch = Get-BaseBranch (Read-WorkflowConfig $ConfigPath)
    $branch = "$(git branch --show-current)".Trim()
    if (-not $branch -or $branch -eq 'main' -or $branch -eq $baseBranch) {
        [Console]::Error.WriteLine("PR mode must be run on a work branch (current: '$branch')")
        exit 1
    }
    # ローカルの main は古いことがあるため、origin を fetch して origin/<base> と比較する
    # (古いと、マージ済みの無関係なコミットが対象・PR 本文の要約に混ざる)
    $baseRef = "origin/$baseBranch"
    git remote get-url origin *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Remote 'origin' not found (PR mode compares with $baseRef)")
        exit 1
    }
    git fetch -q origin $baseBranch *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Failed to fetch origin $baseBranch (cannot compare with the latest $baseRef)")
        exit 1
    }
    git rev-parse --verify --quiet $baseRef *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Base ref '$baseRef' not found")
        exit 1
    }
    if (-not (Test-Path $StatePath)) {
        [Console]::Error.WriteLine("state.json not found: $StatePath")
        exit 1
    }
    $commits = @(git log "$baseRef..HEAD" --format=%H)
    $selected = @()
    $selectedIds = @()
    foreach ($t in (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).tasks) {
        $c = $t.commit
        if ($t.status -eq 'done' -and $c -and @($commits | Where-Object { $_.StartsWith($c) }).Count -gt 0) {
            $selected += "- $($t.id): $($t.title) (commit $c)"
            $selectedIds += $t.id
        }
    }
    if ($selected.Count -eq 0) {
        [Console]::Error.WriteLine("No done tasks whose commit is in $baseRef..HEAD (nothing to include in the PR)")
        exit 1
    }
    $reqLines = @()
    if (Test-Path $TasksPath) {
        try {
            $prLines = @(Split-TaskLines ([System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8)))
            $reqLines = @(Get-PrRequirementLines (Read-TaskList $prLines) $prLines $selectedIds)
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            exit 1
        }
    }
    $requirementList = if ($reqLines.Count -gt 0) { $reqLines -join "`n" } else { '- なし(tasks.md に要件の節が無い、またはこの PR のタスクに対応する要件が無い)' }
    $prN = 1
    if (Test-Path $RunsBase) {
        Get-ChildItem -Path $RunsBase -Directory | Where-Object { $_.Name -match '^pr-(\d+)-1$' } | ForEach-Object {
            $n = [int]$Matches[1]
            if ($n -ge $prN) { $prN = $n + 1 }
        }
    }
    $prRunDir = "$RunsBase/pr-$prN-1"
    $null = New-Item -ItemType Directory -Force $prRunDir
    $text = Get-Content "$PSScriptRoot/dispatch-pr-prompt-template.md" -Raw -Encoding UTF8
    $text = $text.Replace('{task_list}', ($selected -join "`n"))
    $text = $text.Replace('{requirement_list}', $requirementList)
    $text = $text.Replace('{branch}', $branch)
    $text = $text.Replace('{base_branch}', $baseBranch)
    $text = $text.Replace('{base_ref}', $baseRef)
    $text = $text.Replace('{run_dir}', ".agents/workflow/runs/pr-$prN-1")
    [System.IO.File]::WriteAllText("$prRunDir/prompt.md", $text, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Generated: $prRunDir/prompt.md"
    Write-Output "RunId: pr-$prN"
    exit 0
}

if (-not $TaskId) {
    [Console]::Error.WriteLine("Usage: dispatch-prompt-gen.ps1 -TaskId <TaskId> [-Attempt <n>] | dispatch-prompt-gen.ps1 -Pr")
    exit 1
}
# パスや埋め込みに使うため、タスクIDと試行回数の形式を検証する
if ($TaskId -cnotmatch '^[A-Za-z0-9_-]+$' -or $Attempt -lt 1) {
    [Console]::Error.WriteLine("Invalid TaskId/Attempt: '$TaskId' '$Attempt'")
    exit 1
}
$RunDir = "$RunsBase/$TaskId-$Attempt"
$PromptPath = "$RunDir/prompt.md"
$TemplatePath = "$PSScriptRoot/dispatch-prompt-template.md"

if (-not (Test-Path $TasksPath)) {
    Write-Error "tasks.md not found: $TasksPath"
    exit 1
}

$taskSection = $null
$inSection = $false
$sectionLines = @()

foreach ($line in (Get-Content $TasksPath -Raw -Encoding UTF8 -ErrorAction Stop) -split "`n") {
    if ($line -match '^## ') {
        if ($inSection) { break }
        if ($line -match "^## ${TaskId}:") {
            $inSection = $true
        }
    }
    if ($inSection) { $sectionLines += $line }
}

if (-not $inSection -or $sectionLines.Count -eq 0) {
    Write-Error "Task '$TaskId' not found in $TasksPath"
    exit 1
}

$taskSection = ($sectionLines -join "`n").TrimEnd()

$title = $null
foreach ($line in $sectionLines) {
    if ($line -match "^## ${TaskId}:\s*(.+)") {
        $title = $Matches[1].Trim()
        break
    }
}

# 依存欄の検証(不正なトークンは黙って捨てずにエラーにする)
$allTasks = @(Read-TaskList @(Split-TaskLines ([System.IO.File]::ReadAllText($TasksPath, [System.Text.Encoding]::UTF8))))
$targetTask = $allTasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
try {
    $deps = @(Get-TaskDeps $targetTask)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$unknownDeps = @($deps | Where-Object { $_ -notin $allTasks.id })
if ($unknownDeps.Count -gt 0) {
    [Console]::Error.WriteLine("${TaskId}: depends on unknown task(s) $($unknownDeps -join ', ') (not found in tasks.md)")
    exit 1
}

# 作業量のしきい値(config.json の task_sizing。値が無ければ既定値、不正値は警告して既定値)
$sizingDefaults = [ordered]@{ max_acceptance_criteria = 5; max_changed_files = 3; max_reference_files = 5 }
$sizingConfig = $null
try { $sizingConfig = (Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).task_sizing } catch {}
$sizing = @{}
foreach ($key in $sizingDefaults.Keys) {
    $v = if ($sizingConfig -is [pscustomobject]) { $sizingConfig.$key } else { $null }
    if ($null -ne $v -and -not (($v -is [int] -or $v -is [long]) -and $v -ge 1)) {
        [Console]::Error.WriteLine("WARN: config task_sizing.${key} is not a positive integer (using $($sizingDefaults[$key]))")
        $v = $null
    }
    $sizing[$key] = if ($null -eq $v) { $sizingDefaults[$key] } else { [int]$v }
}

# 参照ファイル欄の検証
# `- **参照ファイル**:` の下の箇条書き(`` - `<パス>` `` + 任意の説明。`<パス>:10-40` のような
# 行範囲は可)を、子が最初に読むファイルとして扱う。存在しないパスはエラー、欄が無い・
# しきい値(max_reference_files)を超える場合は警告のみ。値に `なし` と書いた場合は検証しない。
$refStart = -1
for ($i = 0; $i -lt $sectionLines.Count; $i++) {
    if ($sectionLines[$i].TrimEnd("`r") -match '^(\s*)-\s+\*\*参照ファイル\*\*:\s*(.*?)\s*$') {
        $refStart = $i; $refIndent = $Matches[1].Length; $refInline = $Matches[2]
        break
    }
}
if ($refStart -lt 0) {
    [Console]::Error.WriteLine("WARN: ${TaskId}: no '- **参照ファイル**:' field (the child may read many files before starting)")
} elseif ($refInline -ne 'なし') {
    # 同じ行に書かれたパス(`- **参照ファイル**: `a.txt`, `b.sh``)も受け付ける
    $refPaths = @([regex]::Matches($refInline, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value -replace ':\d+(-\d+)?$', '' })
    for ($i = $refStart + 1; $i -lt $sectionLines.Count; $i++) {
        $line = $sectionLines[$i].TrimEnd("`r")
        if (-not $line.Trim()) { continue }
        if (($line.Length - $line.TrimStart().Length) -le $refIndent) { break }
        if ($line -match '^\s*-\s+`([^`]+)`') { $refPaths += ($Matches[1] -replace ':\d+(-\d+)?$', '') }
    }
    if ($refPaths.Count -eq 0) {
        [Console]::Error.WriteLine("${TaskId}: '- **参照ファイル**:' has no items (write '- ``<path>``' items below the field or ``<path>`` on the same line, or 'なし')")
        exit 1
    }
    $missingRefs = @($refPaths | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingRefs.Count -gt 0) {
        [Console]::Error.WriteLine("${TaskId}: reference file(s) not found: $($missingRefs -join ', ')")
        exit 1
    }
    if ($refPaths.Count -gt $sizing['max_reference_files']) {
        [Console]::Error.WriteLine("WARN: ${TaskId}: $($refPaths.Count) reference files (keep it to a few)")
    }
}

# --- 作業量の警告(タスクが1応答で処理しきれなそうなら計画の段階で気付けるようにする) ---
# 1) 受け入れ基準がしきい値(max_acceptance_criteria)を超える、2) (変更対象)の参照ファイルがしきい値
# (max_changed_files)を超える。どちらも警告のみで生成は続ける。
function Find-BulletField {
    # `- **<名前>**:` の行位置・インデント・同一行の値(無ければ $null)を返す
    param([string[]]$Lines, [string]$Name)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].TrimEnd("`r") -match ('^(\s*)-\s+\*\*' + [regex]::Escape($Name) + '\*\*:\s*(.*?)\s*$')) {
            return [pscustomobject]@{ Start = $i; Indent = $Matches[1].Length; Inline = $Matches[2] }
        }
    }
    return $null
}
$acField = Find-BulletField $sectionLines '受け入れ基準'
if ($acField) {
    $acCount = 0
    for ($i = $acField.Start + 1; $i -lt $sectionLines.Count; $i++) {
        $line = $sectionLines[$i].TrimEnd("`r")
        if (-not $line.Trim()) { continue }
        if (($line.Length - $line.TrimStart().Length) -le $acField.Indent) { break }
        if ($line -match '^\s*-\s+\[[ xX]\]') { $acCount++ }
    }
    if ($acCount -gt $sizing['max_acceptance_criteria']) {
        [Console]::Error.WriteLine("WARN: ${TaskId}: $acCount acceptance criteria (more than $($sizing['max_acceptance_criteria']); consider splitting the task)")
    }
}
$changedRefCount = 0
if ($refStart -ge 0) {
    # 参照ファイル欄は既存の検証で走査済み。同じ行の値と欄の下の行から変更対象を数える
    $changedRefCount += [regex]::Matches($refInline, '[(（]変更対象').Count
    for ($i = $refStart + 1; $i -lt $sectionLines.Count; $i++) {
        $line = $sectionLines[$i].TrimEnd("`r")
        if (-not $line.Trim()) { continue }
        if (($line.Length - $line.TrimStart().Length) -le $refIndent) { break }
        $changedRefCount += [regex]::Matches($line, '[(（]変更対象').Count
    }
}
if ($changedRefCount -gt $sizing['max_changed_files']) {
    [Console]::Error.WriteLine("WARN: ${TaskId}: $changedRefCount reference files marked 変更対象 (more than $($sizing['max_changed_files']); consider splitting the task)")
}

# AGENTS.md が @ 参照だけのファイルなら警告する(プロファイルの agents_md_imports が false の子CLIは @ を展開しないため、子にルールが届かない)
if (Test-Path AGENTS.md -PathType Leaf) {
    $agentsLines = @(Get-Content AGENTS.md -Encoding UTF8 | Where-Object { $_.Trim() })
    if (-not ($agentsLines | Where-Object { $_.Trim() -notmatch '^@' })) {
        # 解決に失敗しても prompt-gen は止めず、展開しない(false)とみなす
        . "$PSScriptRoot/childprofile.ps1"
        $profileName = 'unknown'
        $profileImports = $false
        try {
            $childProfile = Get-ChildProfile -Root (Get-Location).Path
            if ($childProfile.Name) { $profileName = $childProfile.Name }
            $profileImports = ($childProfile.AgentsMdImports -eq $true)
        } catch { }
        if (-not $profileImports) {
            [Console]::Error.WriteLine("WARN: AGENTS.md only contains '@' references; the child CLI (profile: $profileName) does not expand them, so the child cannot read the rules")
        }
    }
}

if ($deps.Count -gt 0) {
    if (-not (Test-Path $StatePath)) {
        Write-Error "state.json not found: $StatePath"
        exit 1
    }
    $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $missing = @()
    foreach ($depId in $deps) {
        $depTask = $state.tasks | Where-Object { $_.id -eq $depId }
        if (-not $depTask -or $depTask.status -ne 'done') {
            $missing += "${depId}: status is not done"
        }
    }

    foreach ($depId in $deps) {
        if ($depId -notin ($missing | ForEach-Object { $_ -replace ':.*', '' })) {
            $maxAttempt = 0
            $depRunBase = "$RunsBase/$depId-*"
            if (Test-Path $RunsBase) {
                Get-ChildItem -Path $RunsBase -Directory -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match "^${depId}-(\d+)$"
                } | ForEach-Object {
                    $n = [int]$Matches[1]
                    if ($n -gt $maxAttempt) { $maxAttempt = $n }
                }
            }
            $reportPath = "$RunsBase/$depId-$maxAttempt/report.md"
            if (-not (Test-Path $reportPath)) {
                $missing += "${depId}: report.md not found at runs/${depId}-${maxAttempt}/report.md"
            }
        }
    }

    if ($missing.Count -gt 0) {
        Remove-Item -Force -ErrorAction SilentlyContinue $PromptPath
        Write-Error "Handoff guard failed:`n$($missing -join "`n")"
        exit 2
    }
}

$handoffReports = ''
if ($deps.Count -gt 0) {
    $handoffLines = @('## 前提タスクの成果(引き継ぎ)', '')
    foreach ($depId in $deps) {
        $depTitle = ''
        $stateData = $null
        if (Test-Path $StatePath) {
            $stateData = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $depEntry = $stateData.tasks | Where-Object { $_.id -eq $depId }
            if ($depEntry) { $depTitle = $depEntry.title }
        }
        $maxAttempt = 0
        if (Test-Path $RunsBase) {
            Get-ChildItem -Path $RunsBase -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match "^${depId}-(\d+)$"
            } | ForEach-Object {
                $n = [int]$Matches[1]
                if ($n -gt $maxAttempt) { $maxAttempt = $n }
            }
        }
        $reportPath = "$RunsBase/$depId-$maxAttempt/report.md"
        $reportContent = Get-Content $reportPath -Raw -Encoding UTF8
        $handoffLines += "### ${depId}: ${depTitle}"
        $handoffLines += $reportContent.TrimEnd()
        $handoffLines += ''
    }
    $handoffReports = $handoffLines -join "`n"
}

$fixNotes = ''
if ($Attempt -ge 2) {
    $fixNotesPath = "$RunDir/fix-notes.md"
    if (-not (Test-Path $fixNotesPath)) {
        Write-Error "fix-notes.md not found: $fixNotesPath"
        exit 3
    }
    $fixContent = Get-Content $fixNotesPath -Raw -Encoding UTF8
    $fixNotes = "## レビュー指摘事項(最優先で対応)`n$($fixContent.TrimEnd())"
}

# config.json が無い・壊れている場合は POSIX 版と同じく exit 1 にする(空の検証指示で続行しない)
try {
    $config = Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("config.json could not be read: $ConfigPath ($($_.Exception.Message))")
    exit 1
}
# config の検証コマンド(command が空のステップは載せない)。1つも無ければ空にし、
# テンプレート側の「受け入れ基準に書かれた確認手順」だけを子に実行させる
$verifyLines = @()
$verifyCmds = @()
$cdc = if ($config.quality_gate) { "$($config.quality_gate.child_dispatch_command)".Trim() } else { '' }
if ($cdc) {
    $verifyLines += "- $cdc"
    $verifyCmds += $cdc
} elseif ($config.quality_gate -and $config.quality_gate.steps) {
    foreach ($step in $config.quality_gate.steps) {
        $cmd = "$($step.command)".Trim()
        $name = if ($step.name) { $step.name } else { 'check' }
        if ($step.blocking -and $cmd) { $verifyLines += "- ${name}: $cmd"; $verifyCmds += $cmd }
    }
}
# 同じコマンドを2回載せない(子が別物と誤解して迷わないように)
$tc = "$($config.test_command)".Trim()
if ($tc -and $tc -cnotin $verifyCmds) { $verifyLines += "- $tc" }

$verifyInstruction = $verifyLines -join "`n"

if (-not (Test-Path $RunDir)) {
    $null = New-Item -ItemType Directory -Path $RunDir -Force
}

if (Test-Path $PromptPath) {
    Remove-Item -Force $PromptPath
}

$template = Get-Content $TemplatePath -Raw -Encoding UTF8
$generated = $template.Replace('{fix_notes}', $fixNotes)
$generated = $generated.Replace('{task_section}', $taskSection)
$generated = $generated.Replace('{handoff_reports}', $handoffReports)
$generated = $generated.Replace('{verify_instruction}', $verifyInstruction)

[System.IO.File]::WriteAllText($PromptPath, $generated, [System.Text.UTF8Encoding]::new($false))
Write-Output "Generated: $PromptPath"
exit 0
