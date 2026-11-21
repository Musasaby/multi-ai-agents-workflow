# test-workflow-run.ps1 / test-workflow-run-retry.ps1 の共通の準備関数(PowerShell版)。
# 単体では実行しない。lib.ps1 を読み込んだ後に読み込んで使う。

function Invoke-Git {
    Push-Location $script:Proj
    & git @args 2>$null
    Pop-Location
}

function Get-LastLine { param([string]$Text) return ($Text -split "`n" | Select-Object -Last 1) }

# runs/<run>/done が現れるまで最大120秒待つ(0.5秒ごと)
function Wait-Done {
    param([string]$RunId)
    for ($i = 0; $i -lt 240; $i++) {
        if (Test-Path "$script:Proj/.agents/workflow/runs/$RunId/done") { return }
        Start-Sleep -Milliseconds 500
    }
}

function Set-StateBranch {
    param([string]$Branch)
    $path = "$script:Proj/.agents/workflow/state.json"
    $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $state.branch = $Branch
    Write-Utf8File $path ($state | ConvertTo-Json -Depth 10)
}

# exit 2(-MaxWait)の間は呼び直す。最大60回
function Invoke-UntilNotWait {
    for ($i = 0; $i -lt 60; $i++) {
        Invoke-Script workflow-run.ps1 -MaxWait 5 -Interval 1
        if ($script:Code -ne 2) { return }
    }
}

# 子のスタブの本文を差し替える(config は同じ絶対パスを指したまま)
function Set-ChildBody {
    param([string]$Body)
    Write-Utf8File "$script:Proj/.agents/child-stub.sh" ("#!/bin/bash`n" + ($Body -replace "`r`n", "`n") + "`n")
}

# レビュー役のスタブの本文を差し替える(config は同じ絶対パスを指したまま)
function Set-ReviewBody {
    param([string]$Body)
    Write-Utf8File "$script:Proj/.agents/review-stub.sh" ("#!/bin/bash`n" + ($Body -replace "`r`n", "`n") + "`n")
}

# ファイルの Number 行目を返す(1 始まり。無ければ空文字列)
function Get-FileLine {
    param([string]$Path, [int]$Number)
    if (-not (Test-Path $Path)) { return '' }
    $lines = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -split "`n"
    if ($Number -lt 1 -or $Number -gt $lines.Count) { return '' }
    return ($lines[$Number - 1] -replace "`r", '')
}

# worktree.txt の `path ` 行の値を返す(無ければ空文字列)
function Get-WorktreePath {
    param([string]$Path)
    $line = @([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -split "`n" |
        Where-Object { $_ -like 'path *' } | Select-Object -First 1)
    if ($line.Count -eq 0) { return '' }
    return ($line[0].Substring(5) -replace "`r", '')
}

# release-child が現れるまで待ってから完了報告を出す子(最大60秒)
function Set-SlowChild {
    Write-Utf8File "$script:Proj/.agents/child-stub.sh" @'
#!/bin/bash
for i in $(seq 1 120); do [ -f "$(dirname "$0")/release-child" ] && break; sleep 0.5; done
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
printf 'line\n' >> "$id.txt"
echo "## 完了報告"
echo "- 変更ファイル: $id.txt"
echo "- テスト結果: 全件パス"
'@
}

# config.json の review.mode を消し、max_parallel を $MaxParallel にする
function Set-BreakPrecondition {
    param([int]$MaxParallel)
    $path = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($MaxParallel -eq 0) {
        $cfg.review.PSObject.Properties.Remove('mode')
    } else {
        $cfg.review | Add-Member -NotePropertyName mode -NotePropertyValue 'dispatch' -Force
        $cfg.max_parallel = $MaxParallel
    }
    Write-Utf8File $path ($cfg | ConvertTo-Json -Depth 10)
}

# T1.txt・T2.txt をコミットし、workflow-run を使える config.json と子のスタブを用意する
function Initialize-Runner {
    Invoke-Git switch -q -c develop/t
    Write-Utf8File "$script:Proj/T1.txt" "one`n"
    Write-Utf8File "$script:Proj/T2.txt" "one`n"
    Invoke-Git add T1.txt T2.txt
    Invoke-Git commit -q -m "add T1 T2"
    Set-Tasks @'
# タスク一覧: test

## T1: 一番目
- **目的**: a
- **対象**: T1.txt を直す
- **参照ファイル**:
  - `T1.txt`(変更対象)
- **依存**: なし

## T2: 二番目
- **目的**: b
- **対象**: T2.txt を直す
- **参照ファイル**:
  - `T2.txt`(変更対象)
- **依存**: なし
'@
    Set-State 'T1:pending' 'T2:pending'
    Set-StateBranch develop/t
    Set-GhStubResult -Stdout '[]'
    # 子は worktree の中で動く(.agents/ は worktree に無い)ため、スタブは絶対パスで指定する。
    # カレントディレクトリ(worktree)の親ディレクトリ名(T1-1)からタスクIDを取り、<ID>.txt に1行足す
    Write-Utf8File "$script:Proj/.agents/child-stub.sh" @'
#!/bin/bash
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
printf 'line\n' >> "$id.txt"
echo "## 完了報告"
echo "- 変更ファイル: $id.txt"
echo "- テスト結果: 全件パス"
'@
    # レビュー役。カレントディレクトリ(worktree)の親ディレクトリ名(review-<ID>-<N>)からタスクIDを取る
    Write-Utf8File "$script:Proj/.agents/review-stub.sh" @'
#!/bin/bash
run_name="$(basename "$(dirname "$PWD")")"
id="${run_name%-*}"
id="${id#review-}"
n="${run_name##*-}"
# .agents/review-fail-<ID> があれば、レビュー不合格として次の試行の fix-notes.md を書く
root="$(cd "$PWD/../../../.." && pwd)"
if [ -f "$root/review-fail-$id" ]; then
    rm -f "$root/review-fail-$id"
    mkdir -p "$root/workflow/runs/$id-$((n + 1))"
    printf '# 修正依頼\n\nレビューの指摘を直してください。\n' > "$root/workflow/runs/$id-$((n + 1))/fix-notes.md"
    echo "## 完了報告"
    echo "- Verdict: fail"
    echo "- 指摘: 1件(修正が必要)"
    echo "- 要約: $id を直す"
    echo "- type: feat"
    echo "- fix-notes: あり"
    echo "- 理解確認: なし"
    exit 0
fi
echo "## 完了報告"
echo "- Verdict: pass"
echo "- 指摘: 0件(なし)"
echo "- 要約: $id を変える"
echo "- type: feat"
echo "- fix-notes: なし"
echo "- 理解確認: なし"
'@
    $bash = ((Get-Command bash).Source -replace '\\', '/')
    $child = ("$script:Proj/.agents/child-stub.sh" -replace '\\', '/')
    $review = ("$script:Proj/.agents/review-stub.sh" -replace '\\', '/')
    $cfgPath = "$script:Proj/.agents/workflow/config.json"
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg.max_parallel = 2
    $cfg.verify_before_commit = $false
    $cfg.review = [pscustomobject]@{
        mode = 'dispatch'
        command_template = '"' + $bash + '" "' + $review + '" "{prompt}"'
    }
    $cfg.child_agent.command_template = '"' + $bash + '" "' + $child + '" "{prompt}"'
    Write-Utf8File $cfgPath ($cfg | ConvertTo-Json -Depth 10)
}
