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
# 未知の引数・-Ref の値が無いときは stderr に使い方を出して exit 1 する。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- 引数 ---
$refArg = $null
$i = 0
while ($i -lt $args.Count) {
    if ("$($args[$i])" -ceq '-Ref' -and ($i + 1) -lt $args.Count) {
        $refArg = "$($args[$i + 1])"
        $i += 2
    } else {
        [Console]::Error.WriteLine('Usage: git-state.sh [--ref <refname>]')
        exit 1
    }
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
