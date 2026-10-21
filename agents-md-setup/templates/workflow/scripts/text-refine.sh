#!/bin/bash
set -euo pipefail

# yomiyasu(文章推敲 skill)への依頼文を config.json の text_refine から機械生成する(推敲そのものは親が行う)。
# 引数: <target> <input> [--check]
#       target は summary / confirm / commit / pr_body / task_done / tasks のいずれか
#       --check は推敲済みファイルに対する yomiyasu の記録を探し、判断が要る候補を出す
# stdout: 推敲しないとき "Refine: off"、(skill 未設定なら導入検出の "Found: <場所>" と "Hint: ..."、)"Next: continue"。
#       推敲するとき "Refine: <skill>"、"Output: <出力パス>"、"Request: <依頼文>"、"Next: refine"
#       --check のとき: 推敲しない/yomiyasu 以外なら "Refine: off"/"Refine: <skill>"+"Check: skipped"、"Next: continue"。
#       yomiyasu なら "Refine: <skill>"、"Output: <出力パス>"、"Record: <記録>"、"Candidates: N"、"Candidate: <キー> <抜粋>"...。
#       判断が全部あれば "Next: continue" と "Text:" 以降に推敲済みの本文、足りなければ "Undecided: <キー>" と "Next: decide-candidates"、
#       確かめられなければ "Unchecked: <理由>" と "Next: escalate reason=refine-unchecked"
#       tasks の --check は先に推敲前後の構造(見出し・依存・要件ID 等の機械パースする行)を比べ、
#       同じなら "Structure: same"(yomiyasu なら続けて記録を確かめ、候補が全部判断済みのとき "Next: continue" だけで "Text:" は出さない)、
#       違えば "Changed: L<行> <抜粋>"、"Refined: L<行> <抜粋>"、"Next: escalate reason=refine-structure-changed"
# exit: 0=出力あり / 1=使い方・入力不備 / 2=--check で判断待ちの候補あり / 3=--check で確かめられない / 4=--check で tasks の構造が変わった

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1

USAGE="Usage: text-refine.sh <summary|confirm|commit|pr_body|task_done|tasks> <input> [--check]"

if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
    echo "$USAGE" >&2
    exit 1
fi

TARGET="$1"
INPUT="$2"
CHECK=0
if [ "$#" -eq 3 ]; then
    if [ "$3" != "--check" ]; then
        echo "$USAGE" >&2
        exit 1
    fi
    CHECK=1
fi

case "$TARGET" in
    summary|confirm|commit|pr_body|task_done|tasks) ;;
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

python3 - "$TARGET" "$INPUT" "$(to_py_path "$ROOT")" "$(to_py_path "$CONFIG_PATH")" "$(to_py_path "$HOME")" "$CHECK" <<'PY'
import glob, hashlib, json, os, re, sys

sys.stdout.reconfigure(newline='\n')

target, input_path, root, config_path, home = sys.argv[1:6]
check = sys.argv[6] == '1'

DEFAULT_TARGETS = ['summary', 'confirm', 'commit', 'pr_body', 'task_done', 'tasks']
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
    'tasks': '子エージェントへの実装依頼と利用者の承認に使うタスク定義です。推敲するのは、要件の本文・前提・解釈・対象外と、各タスクの目的欄・受け入れ基準の文です',
}
KEEP_BASE = 'コマンド・パス・タスクID・コミットハッシュ・URL・括弧書きの補足'
KEEP_EXTRA = {
    'summary': '、「状況・起きたこと・次にすること」の3つのまとまりとその順番',
    'task_done': '、「状況・起きたこと・次にすること」の3つのまとまりとその順番',
    'confirm': '、「状況・起きたこと・次にすること」の3つのまとまりとその順番',
    'commit': '、1行のまま改行しないこと',
    'pr_body': '、見出しと節の順番、要件一覧とテスト計画の項目',
    'tasks': '、見出し・グループの区切り行・依存・要件・グループ・参照ファイルの行と参照ファイルの箇条・要件ID(R1: 等)・コードブロックの中身・識別子',
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
    if not skill_set and not check:
        found = detect()
        for place in found:
            print('Found: ' + place)
        if found:
            print('Hint: yomiyasu is installed but text_refine.skill is not set')
    print('Next: continue')
    sys.exit(0)

base, ext = os.path.splitext(input_path)
output_path = base + '.refined' + ext
decisions_path = base + '.decisions' + ext


def unchecked(reason):
    print('Unchecked: ' + reason)
    print('Next: escalate reason=refine-unchecked')
    sys.exit(3)


def load_json(path):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def excerpt(s):
    s = re.sub(r'\s+', ' ', s if isinstance(s, str) else '').strip()
    return s[:40] + '…' if len(s) >= 41 else s


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def structure(text):
    keys = []
    in_code = False
    in_bullets = False
    for no, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.rstrip()
        if line.lstrip().startswith('```'):
            keys.append((no, line))
            in_code = not in_code
            in_bullets = False
            continue
        if in_code:
            keys.append((no, line))
            continue
        if in_bullets:
            if re.match(r'^\s*-\s+(?!\*\*)', line):
                keys.append((no, line))
                continue
            in_bullets = False
        if line.startswith('#') or line.startswith('<!--'):
            keys.append((no, line))
            continue
        m = re.match(r'^\s*-\s+\*\*(依存|要件|グループ|参照ファイル)\*\*:', line)
        if m:
            keys.append((no, line))
            in_bullets = m.group(1) == '参照ファイル'
            continue
        m = re.match(r'^- R\d+:', line)
        if m:
            keys.append((no, m.group(0)))
    return keys


def read_text(path):
    with open(path, encoding='utf-8-sig') as f:
        return f.read()


def check_structure():
    if not os.path.isfile(input_path):
        unchecked('input not found')
    if not os.path.isfile(output_path):
        unchecked('output not found')
    before = structure(read_text(input_path))
    after = structure(read_text(output_path))
    for i in range(max(len(before), len(after))):
        b = before[i] if i < len(before) else None
        a = after[i] if i < len(after) else None
        if b is None or a is None or b[1] != a[1]:
            print('Changed: L%s %s' % (b[0] if b else '-', excerpt(b[1] if b else '')))
            print('Refined: L%s %s' % (a[0] if a else '-', excerpt(a[1] if a else '')))
            print('Next: escalate reason=refine-structure-changed')
            sys.exit(4)
    print('Structure: same')


def run_check():
    is_tasks = target == 'tasks'
    if is_tasks:
        print('Refine: ' + skill)
        print('Output: ' + output_path)
        check_structure()
    if skill.strip() not in ('yomiyasu', 'yomiyasu:yomiyasu'):
        if not is_tasks:
            print('Refine: ' + skill)
        print('Check: skipped')
        print('Next: continue')
        sys.exit(0)
    if not is_tasks:
        print('Refine: ' + skill)
        print('Output: ' + output_path)
    if not os.path.isfile(output_path):
        unchecked('output not found')
    with open(output_path, 'rb') as f:
        raw = f.read()
    h = hashlib.sha256(raw).hexdigest()
    state = os.environ.get('YOMIYASU_STATE_DIR') or os.path.join(root, '.yomiyasu')
    best = None
    best_key = None
    for rec_path in glob.glob(os.path.join(state, 'runs', '*', 'attempt-*.json')):
        rec = load_json(rec_path)
        if not isinstance(rec, dict) or rec.get('format') != 'yomiyasu-check-record':
            continue
        inputs = rec.get('inputs')
        final = inputs.get('final') if isinstance(inputs, dict) else None
        if not isinstance(final, dict) or final.get('sha256') != h:
            continue
        created = rec.get('created_at')
        attempt = rec.get('attempt')
        if not isinstance(created, str) or not is_int(attempt):
            continue
        key = (created, attempt)
        if best_key is None or key > best_key:
            best, best_key, best_path = rec, key, rec_path
    if best is None:
        unchecked('no record for sha256:' + h[:12])
    print('Record: ' + os.path.relpath(best_path, state).replace(os.sep, '/'))

    def find_report(name):
        checks = best.get('checks')
        if not isinstance(checks, list):
            return None
        for c in checks:
            if isinstance(c, dict) and c.get('name') == name and c.get('status') == 'ran':
                rp = c.get('report')
                if not isinstance(rp, str):
                    return False
                data = load_json(os.path.join(state, rp))
                return data if isinstance(data, dict) else False
        return None

    lint = find_report('lint')
    if not lint or not isinstance(lint.get('findings'), list):
        unchecked('lint report missing')
    candidates = []
    for fd in lint['findings']:
        if not isinstance(fd, dict):
            continue
        line = fd.get('line')
        key = 'L%s %s' % (line if is_int(line) else '-', fd.get('rule'))
        candidates.append((key, excerpt(fd.get('snippet'))))
    diff = find_report('diff')
    if diff is False:
        unchecked('diff report missing')
    if diff is not None:
        risks = diff.get('meaning_risks')
        for r in risks if isinstance(risks, list) else []:
            if not isinstance(r, dict):
                continue
            line = r.get('new_line')
            if not is_int(line):
                line = r.get('old_line')
            sub = r.get('subkind') or r.get('kind')
            key = 'L%s meaning_risk:%s' % (line if is_int(line) else '-', sub)
            candidates.append((key, excerpt(r.get('new') or r.get('old'))))
    print('Candidates: %d' % len(candidates))
    for key, ex in candidates:
        print('Candidate: ' + key + ' ' + ex)
    if candidates:
        print('Decisions: ' + decisions_path)
        try:
            with open(decisions_path, encoding='utf-8-sig') as f:
                decided = f.read()
        except OSError:
            decided = ''
        undecided = [k for k, _ in candidates if k not in decided]
        for k in undecided:
            print('Undecided: ' + k)
        if undecided:
            print('Next: decide-candidates')
            sys.exit(2)
    print('Next: continue')
    if is_tasks:
        sys.exit(0)
    print('Text:')
    print(raw.decode('utf-8').rstrip(chr(13) + chr(10)))
    sys.exit(0)


if check:
    run_check()

if not os.path.exists(input_path):
    print('not found: ' + input_path, file=sys.stderr)
    sys.exit(1)

if os.path.exists(output_path):
    os.remove(output_path)
if os.path.exists(decisions_path):
    os.remove(decisions_path)

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
