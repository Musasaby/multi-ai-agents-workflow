"""tasks.md の解析と依存欄・グループの検証(POSIX版スクリプト共通)。

state-sync.sh / next-task.sh / dispatch-prompt-gen.sh から import して使う。
依存欄の厳密フォーマット: `- **依存**: なし` または `- **依存**: T1, T2`
グループ区切り行の厳密フォーマット: `<!-- グループ <名前> -->` または
`<!-- グループ <名前>: <説明> -->`(<名前> は空白と ':' を含まない文字列)
"""
import re

HEADING_RE = re.compile(r'^## (T\d+):\s*(.+)')
DEP_LINE_RE = re.compile(r'^(\s*-\s+\*\*依存\*\*:)[ \t]*(.*?)[ \t]*$')
TASK_ID_RE = re.compile(r'^T\d+$')
DEP_FORMAT_HINT = "expected 'なし' or comma-separated task IDs like 'T1, T2'"
GROUP_LINE_RE = re.compile(r'^<!--\s*グループ\s+([^:\s]+)(?:\s*:\s*(.*?))?\s*-->\s*$')
GROUP_FIELD_RE = re.compile(r'^(\s*-\s+\*\*グループ\*\*:)[ \t]*(.*?)[ \t]*$')
DEFAULT_GROUP = ''


class TaskFileError(Exception):
    pass


def split_lines(content):
    """改行コードを保持したまま行に分割する(CRLF の tasks.md をそのまま書き戻すため)。"""
    return content.splitlines(keepends=True)


def strip_eol(line):
    return line.rstrip('\r\n')


def parse_tasks(content):
    """tasks.md を解析し、出現順の [{'id','title','dep_raw','dep_line','group','group_raw'}] を返す。

    dep_raw は依存欄の値(依存行が無ければ None)、dep_line は lines 上の行番号。
    group は所属グループ名: タスク見出しより前にある直近のグループ区切りの名前(区切りが
    1つも無い、または最初の区切りより前のタスクは既定グループ DEFAULT_GROUP ='')。
    group_raw はタスク欄 '- **グループ**: <名前>' の値(欄が無ければ None)。欄があれば
    位置より優先する(名前が tasks.md の区切りに存在する場合のみ。不一致の検証は
    check_group_deps が行う)。同じIDの見出しが複数ある場合は後勝ち(従来の state-sync と同じ)。
    """
    lines = split_lines(content)
    tasks = {}
    order = []
    current = None
    current_group = DEFAULT_GROUP
    declared = set()
    for i, raw in enumerate(lines):
        line = strip_eol(raw).lstrip('﻿')
        m = GROUP_LINE_RE.match(line)
        if m:
            current_group = m.group(1)
            declared.add(current_group)
            continue
        if line.startswith('## '):
            m = HEADING_RE.match(line)
            if m:
                tid = m.group(1)
                if tid not in tasks:
                    order.append(tid)
                current = {'id': tid, 'title': m.group(2).strip(), 'dep_raw': None, 'dep_line': None,
                           'group': current_group, 'group_raw': None}
                tasks[tid] = current
            else:
                current = None
            continue
        if current is not None:
            if current['dep_raw'] is None:
                m = DEP_LINE_RE.match(line)
                if m:
                    current['dep_raw'] = m.group(2)
                    current['dep_line'] = i
            if current['group_raw'] is None:
                m = GROUP_FIELD_RE.match(line)
                if m:
                    current['group_raw'] = m.group(2)
    # グループ欄による上書き(欄の名前が区切りに存在する場合のみ)
    for t in (tasks[tid] for tid in order):
        if t['group_raw'] is not None and t['group_raw'] in declared:
            t['group'] = t['group_raw']
    return [tasks[tid] for tid in order]


def group_order(content):
    """tasks.md 上に出現するグループの順序を返す。

    戻り値は [既定グループ(''), 区切り名...] のリスト(区切り名は最初に出現した順、重複なし)。
    """
    names = [DEFAULT_GROUP]
    for raw in split_lines(content):
        m = GROUP_LINE_RE.match(strip_eol(raw).lstrip('﻿'))
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return names


def check_group_deps(tasks, order):
    """グループ欄と、依存先が後のグループに属する依存を検証する。エラーはすべて集めて TaskFileError。

    order は group_order(content) の戻り値(先頭が既定グループ '')。依存先が自分より後の
    グループに属する依存は、そのタスクが永久に実行できないためエラーにする。
    """
    idx = {}
    for i, name in enumerate(order):
        if name not in idx:
            idx[name] = i
    group_of = {t['id']: t['group'] for t in tasks}
    errors = []
    for t in tasks:
        raw = t['group_raw']
        if raw is not None:
            if raw == '':
                errors.append(t['id'] + ": group field ('- **グループ**: ...') is empty")
                continue
            if raw not in idx:
                errors.append(t['id'] + ": unknown group '" + raw
                              + "' (not declared by any '<!-- グループ <名前> -->' line in tasks.md)")
                continue
        try:
            deps = parse_deps(t)
        except TaskFileError:
            continue  # 依存欄の不備は resolve_deps が報告する
        my_idx = idx.get(t['group'], 0)
        for d in deps:
            d_group = group_of.get(d)
            if d_group is None:
                continue  # 存在しない依存先は resolve_deps が報告する
            if idx.get(d_group, 0) > my_idx:
                errors.append("Later-group dependency: " + t['id'] + " (group '" + t['group']
                              + "') depends on " + d + " (group '" + d_group
                              + "'); a task must not depend on a task in a later group")
    if errors:
        raise TaskFileError('\n'.join(errors))


def parse_deps(task):
    """依存欄を検証してタスクIDのリストを返す。不正なら TaskFileError。"""
    tid = task['id']
    raw = task['dep_raw']
    if raw is None:
        raise TaskFileError(tid + ": dependency line ('- **依存**: ...') is missing")
    if raw == 'なし':
        return []
    deps = []
    for token in raw.split(','):
        token = token.strip()
        if not TASK_ID_RE.match(token):
            raise TaskFileError(
                "Invalid dependency in " + tid + ": '" + token + "' (" + DEP_FORMAT_HINT
                + "; write notes in the 目的 field, not in 依存)")
        if token == tid:
            raise TaskFileError(tid + ": depends on itself")
        if token not in deps:
            deps.append(token)
    return deps


def resolve_deps(tasks, check_cycles=True):
    """全タスクの依存欄を検証し {id: [deps]} を返す。エラーはすべて集めて TaskFileError にする。"""
    ids = {t['id'] for t in tasks}
    graph = {}
    errors = []
    for t in tasks:
        try:
            deps = parse_deps(t)
        except TaskFileError as e:
            errors.append(str(e))
            continue
        for d in deps:
            if d not in ids:
                errors.append(t['id'] + ": depends on unknown task '" + d + "' (not found in tasks.md)")
        graph[t['id']] = deps
    if errors:
        raise TaskFileError('\n'.join(errors))
    if check_cycles:
        cycle = find_cycle(graph, [t['id'] for t in tasks])
        if cycle:
            raise TaskFileError('Dependency cycle detected: ' + ' -> '.join(cycle))
    return graph


def find_cycle(graph, order):
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {tid: WHITE for tid in order}
    stack = []

    def visit(tid):
        color[tid] = GRAY
        stack.append(tid)
        for d in graph.get(tid, []):
            if color.get(d) == GRAY:
                return stack[stack.index(d):] + [d]
            if color.get(d) == WHITE:
                found = visit(d)
                if found:
                    return found
        stack.pop()
        color[tid] = BLACK
        return None

    for tid in order:
        if color[tid] == WHITE:
            found = visit(tid)
            if found:
                return found
    return None


def format_deps(deps):
    return ', '.join(deps) if deps else 'なし'


def rewrite_dep_line(lines, task, deps):
    """lines 上の task の依存行を deps で書き換える(行頭インデント・改行コードは保持)。"""
    i = task['dep_line']
    raw = lines[i]
    eol = raw[len(strip_eol(raw)):]
    m = DEP_LINE_RE.match(strip_eol(raw))
    lines[i] = m.group(1) + ' ' + format_deps(deps) + eol
