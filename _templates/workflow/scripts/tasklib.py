"""tasks.md の解析と依存欄の検証(POSIX版スクリプト共通)。

state-sync.sh / next-task.sh / dispatch-prompt-gen.sh から import して使う。
依存欄の厳密フォーマット: `- **依存**: なし` または `- **依存**: T1, T2`
"""
import re

HEADING_RE = re.compile(r'^## (T\d+):\s*(.+)')
DEP_LINE_RE = re.compile(r'^(\s*-\s+\*\*依存\*\*:)[ \t]*(.*?)[ \t]*$')
TASK_ID_RE = re.compile(r'^T\d+$')
DEP_FORMAT_HINT = "expected 'なし' or comma-separated task IDs like 'T1, T2'"


class TaskFileError(Exception):
    pass


def split_lines(content):
    """改行コードを保持したまま行に分割する(CRLF の tasks.md をそのまま書き戻すため)。"""
    return content.splitlines(keepends=True)


def strip_eol(line):
    return line.rstrip('\r\n')


def parse_tasks(content):
    """tasks.md を解析し、出現順の [{'id','title','dep_raw','dep_line'}] を返す。

    dep_raw は依存欄の値(依存行が無ければ None)、dep_line は lines 上の行番号。
    同じIDの見出しが複数ある場合は後勝ち(従来の state-sync と同じ)。
    """
    lines = split_lines(content)
    tasks = {}
    order = []
    current = None
    for i, raw in enumerate(lines):
        line = strip_eol(raw).lstrip('﻿')
        if line.startswith('## '):
            m = HEADING_RE.match(line)
            if m:
                tid = m.group(1)
                if tid not in tasks:
                    order.append(tid)
                current = {'id': tid, 'title': m.group(2).strip(), 'dep_raw': None, 'dep_line': None}
                tasks[tid] = current
            else:
                current = None
            continue
        if current is not None and current['dep_raw'] is None:
            m = DEP_LINE_RE.match(line)
            if m:
                current['dep_raw'] = m.group(2)
                current['dep_line'] = i
    return [tasks[tid] for tid in order]


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
