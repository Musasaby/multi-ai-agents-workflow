# カレントディレクトリのリポジトリの git 状態を4行で出力する。何も書き換えない。
# dispatch-run が子の起動時にこの出力を git-state.txt に記録し、dispatch-check が
# 実行後の出力と比べて、子がリポジトリのどこを変えたか(HEAD・ブランチ・参照・設定)を特定する。
# 出力形式(この順に4行。項目の取得に失敗したら値を "-" にする):
#   head <HEAD コミットの SHA-1(git rev-parse --verify -q HEAD)>
#   branch <HEAD の参照名(git symbolic-ref -q HEAD。例: refs/heads/main)>
#   refs <参照一覧の SHA-256(16進小文字)>: 参照一覧は
#        git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash の出力。
#        refs/remotes は push で正当に変わるため含めない
#   config <git rev-parse --git-path config が指すファイルの SHA-256(16進小文字)>
# git リポジトリの中でなければ(git rev-parse --git-dir が失敗したら)stderr に
# "not a git repository" を出して exit 1 する。
#   -Ref <refname> を付けると、refs 行はその参照だけ
#   (git for-each-ref --format='%(objectname) %(refname)' <refname> の出力。無ければ空の出力)のハッシュにする。
#   ほかのブランチの参照が変わっても変わらない。ほかの行は変わらない
#   -Run <自分の run のブランチの参照名> -Parent <親の作業ブランチの参照名> を付けると、refs 行は既定の参照一覧から
#   次の行を除いたもののハッシュにする(worktree は ref を本体と共有しているため、ほかの run や親の動きを除く)
#     - 参照名が refs/heads/agents-run/ で始まり、-Run の値と一致しない行(ほかの run のブランチ)
#     - 参照名が -Parent の値と一致する行(-Parent が - か空なら何も除かない)
#   -Run と -Parent は両方そろって使う。-Ref とは一緒に使えない
# 未知の引数・値が無いオプション・-Run と -Parent の片方だけ・-Ref との併用は、
# stderr に使い方を出して exit 1 する。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- 引数 ---
$usage = 'Usage: git-state.sh [--ref <refname> | --run <refname> --parent <refname>]'
$refArg = $null
$runArg = $null
$parentArg = $null
$i = 0
while ($i -lt $args.Count) {
    $name = "$($args[$i])"
    if (($i + 1) -ge $args.Count) {
        [Console]::Error.WriteLine($usage)
        exit 1
    }
    if ($name -ceq '-Ref') { $refArg = "$($args[$i + 1])" }
    elseif ($name -ceq '-Run') { $runArg = "$($args[$i + 1])" }
    elseif ($name -ceq '-Parent') { $parentArg = "$($args[$i + 1])" }
    else {
        [Console]::Error.WriteLine($usage)
        exit 1
    }
    $i += 2
}
if (($null -ne $runArg) -ne ($null -ne $parentArg) -or ($null -ne $refArg -and $null -ne $runArg)) {
    [Console]::Error.WriteLine($usage)
    exit 1
}

# --- リポジトリ判定 ---
$null = git rev-parse --git-dir 2> $null
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('not a git repository')
    exit 1
}

# --- head ---
$head = "$(git rev-parse --verify -q HEAD)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $head) { $head = '-' }

# --- branch ---
$branch = "$(git symbolic-ref -q HEAD)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $branch) { $branch = '-' }

# --- refs ---
$lines = if ($null -ne $refArg) {
    @(git for-each-ref --format='%(objectname) %(refname)' $refArg)
} elseif ($null -ne $runArg) {
    @(git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash | Where-Object {
        $n = ("$_" -split ' ', 2)[1]
        -not ($n.StartsWith('refs/heads/agents-run/', [System.StringComparison]::Ordinal) -and $n -cne $runArg) -and
        -not ($parentArg -and $parentArg -ne '-' -and $n -ceq $parentArg)
    })
} else {
    @(git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash)
}
$text = if ($lines.Count -gt 0) { ($lines -join "`n") + "`n" } else { '' }
$refs = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()

# --- config(git rev-parse --git-path config が指すファイル。無ければ -) ---
$f = "$(git rev-parse --git-path config)".Trim()
$config = if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() } else { '-' }

Write-Output "head $head"
Write-Output "branch $branch"
Write-Output "refs $refs"
Write-Output "config $config"
exit 0
