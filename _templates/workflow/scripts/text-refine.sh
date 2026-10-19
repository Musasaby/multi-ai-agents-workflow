#!/bin/bash
set -euo pipefail

# yomiyasu(文章推敲 skill)への依頼文を config.json の text_refine から機械生成する(推敲そのものは親が行う)。
# 引数: <target> <input>
#       target は summary / confirm / commit / pr_body / task_done のいずれか
# stdout: 推敲しないとき "Refine: off"、(skill 未設定なら導入検出の "Found: <場所>" と "Hint: ..."、)"Next: continue"。
#       推敲するとき "Refine: <skill>"、"Output: <出力パス>"、"Request: <依頼文>"、"Next: refine"
# exit: 0=出力あり / 1=使い方・入力不備

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1

USAGE="Usage: text-refine.sh <summary|confirm|commit|pr_body|task_done> <input>"

if [ "$#" -ne 2 ]; then
    echo "$USAGE" >&2
    exit 1
fi

TARGET="$1"
INPUT="$2"

case "$TARGET" in
    summary|confirm|commit|pr_body|task_done) ;;
    *)
        echo "$USAGE" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
ROOT="$(pwd)"

CONFIG_PATH="$ROOT/.agents/workflow/config.json"

to_py_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

python3 - "$TARGET" "$INPUT" "$(to_py_path "$ROOT")" "$(to_py_path "$CONFIG_PATH")" "$(to_py_path "$HOME")" <<'PY'
import json, os, re, sys

sys.stdout.reconfigure(newline='\n')

target, input_path, root, config_path, home = sys.argv[1:6]

DEFAULT_TARGETS = ['summary', 'confirm', 'commit', 'pr_body', 'task_done']
READERS = {
    'expert': '同じ分野の専門家',
    'informed': '分野は違うが技術に詳しい人',
    'general': '専門知識のない人',
}
KINDS = {
    'summary': 'ワークフローの完了をユーザーに伝える報告です',
    'task_done': 'タスク1件の完了をユーザーに伝える報告です',
    'confirm': 'ユーザーに判断を求める確認の依頼です',
    'commit': 'コミットメッセージの説明の1行です',
    'pr_body': 'PR説明です',
}
KEEP_BASE = 'コマンド・パス・タスクID・コミットハッシュ・URL・括弧書きの補足'
KEEP_EXTRA = {
    'summary': '、「状況・起きたこと・次にすること」の3つのまとまりとその順番',
    'task_done': '、「状況・起きたこと・次にすること」の3つのまとまりとその順番',
    'confirm': '、「状況・起きたこと・次にすること」の3つのまとまりとその順番',
    'commit': '、1行のまま改行しないこと',
    'pr_body': '、見出しと節の順番、要件一覧とテスト計画の項目',
}

# 設定の読み込み(ファイル・キーが無い・読めなければ skill=null 扱い)
cfg = {}
try:
    with open(config_path, encoding='utf-8-sig') as f:
        loaded = json.load(f)
    if isinstance(loaded, dict) and isinstance(loaded.get('text_refine'), dict):
        cfg = loaded['text_refine']
except (OSError, ValueError):
    cfg = {}

skill = cfg.get('skill')
targets = cfg.get('targets')
if not isinstance(targets, list):
    targets = DEFAULT_TARGETS
reader = cfg.get('reader')
if reader not in READERS:
    reader = 'informed'

skill_set = isinstance(skill, str) and skill.strip() != ''


def list_dirs(path):
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return []
    return [n for n in names if os.path.isdir(os.path.join(path, n))]


def is_yomiyasu(skill_md):
    try:
        with open(skill_md, encoding='utf-8-sig') as f:
            lines = f.read().splitlines()
    except (OSError, ValueError):
        return False
    if not lines or lines[0].strip() != '---':
        return False
    for line in lines[1:]:
        if line.strip() == '---':
            break
        if re.match(r'^name:\s*["\']?yomiyasu["\']?\s*$', line):
            return True
    return False


def detect():
    found = []

    def add(label):
        if label not in found:
            found.append(label)

    def check(base_dir, label_prefix, rel):
        md = os.path.join(base_dir, 'skills', 'yomiyasu', 'SKILL.md')
        if is_yomiyasu(md):
            add(label_prefix + rel + ('/' if rel else '') + 'skills/yomiyasu/SKILL.md')

    # プロジェクト
    check(root, '', '')
    for d1 in list_dirs(root):
        if d1 in ('.git', 'node_modules'):
            continue
        d1_path = os.path.join(root, d1)
        check(d1_path, '', d1)
        if d1.startswith('.'):
            for d2 in list_dirs(d1_path):
                check(os.path.join(d1_path, d2), '', d1 + '/' + d2)

    # ホーム
    for d1 in list_dirs(home):
        if not d1.startswith('.'):
            continue
        d1_path = os.path.join(home, d1)
        check(d1_path, '~/', d1)
        for d2 in list_dirs(d1_path):
            d2_path = os.path.join(d1_path, d2)
            check(d2_path, '~/', d1 + '/' + d2)
            for d3 in list_dirs(d2_path):
                check(os.path.join(d2_path, d3), '~/', d1 + '/' + d2 + '/' + d3)

    # Claude Code のプラグイン
    plugins_json = os.path.join(home, '.claude', 'plugins', 'installed_plugins.json')
    try:
        with open(plugins_json, encoding='utf-8-sig') as f:
            plugins = json.load(f).get('plugins')
        if isinstance(plugins, dict):
            for key in plugins:
                if key.startswith('yomiyasu@'):
                    add('~/.claude/plugins/installed_plugins.json (' + key + ')')
    except (OSError, ValueError, AttributeError):
        pass
    return found


if not skill_set or target not in targets:
    print('Refine: off')
    if not skill_set:
        found = detect()
        for place in found:
            print('Found: ' + place)
        if found:
            print('Hint: yomiyasu is installed but text_refine.skill is not set')
    print('Next: continue')
    sys.exit(0)

if not os.path.exists(input_path):
    print('not found: ' + input_path, file=sys.stderr)
    sys.exit(1)

base, ext = os.path.splitext(input_path)
output_path = base + '.refined' + ext
if os.path.exists(output_path):
    os.remove(output_path)

request = (
    '{inp} を {skill} で推敲し、本文だけを {out} に書いてください。{kind}。読者は{reader}です。'
    '質問はせず、意味・条件・数値を変えないでください。次のものは変えないでください: {keep}。'
).format(
    inp=input_path, skill=skill, out=output_path, kind=KINDS[target],
    reader=READERS[reader], keep=KEEP_BASE + KEEP_EXTRA[target],
)

print('Refine: ' + skill)
print('Output: ' + output_path)
print('Request: ' + request)
print('Next: refine')
PY
