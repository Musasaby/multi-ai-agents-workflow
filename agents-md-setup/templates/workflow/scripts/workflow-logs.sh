#!/bin/bash
set -uo pipefail

# 複数の子エージェント run の output.log を、1つの画面に表示する(tail -f の複数 run 版)。
# Usage: workflow-logs.sh [--run <ID>-<N>]... [--tail <行数>] [--interval <秒>] [--duration <秒>]
#        [--once] [--layout <columns|stream>] [--width <桁>] [--height <行>]
#   --run       指定した名前の run だけを追う(複数指定可。形式は ^[A-Za-z0-9_-]+-[0-9]+$)。
#               ディレクトリがまだ無ければ現れるまで待つ
#   --tail      stream で run を初めて見つけたとき、output.log の末尾から出す行数(既定 20)
#   --interval  run の探し直しとログ確認・再描画の間隔(秒。既定 1。0 より大きい数だけ。0・0.0 は使い方の誤り)
#   --duration  指定した秒数で終了する
#   --once      対象の run を1回だけ描いて終了する(stream は末尾の行、columns は1画面)
#   --layout    表示のしかた。columns=run ごとに横へ列を並べる / stream=全 run の行を1列に流す。
#               既定は stdout が端末なら columns、そうでなければ stream(パイプ・テストでは stream のまま)
#   --width     画面の幅(桁)。無ければ端末の幅、取れなければ 120
#   --height    画面の高さ(行)。無ければ端末の高さ、取れなければ 30
# 対象の run: --run があればその名前の run。無ければ .agents/workflow/runs/*/ のうち
#   guard.sha256 があり done が無いもの(--interval ごとに探し直し、新しい run を加える)。
#   output.log(無ければ guard.sha256)の最終更新が child_agent.timeout_seconds 秒
#   (.agents/workflow/config.json。読めない・正の整数でなければ 1800)より前の run は、
#   止まった run(kill・クラッシュで done が無い)として対象にしない。--run 指定の run には当てない
# 最終更新: run の output.log(無ければ guard.sha256)の更新時刻(ローカル時刻)。
#   stream は run を最初に見つけたときに `[<run>] --- watching (updated HH:MM:SS)`、
#   新しい行が 60 秒出ないごとに `[<run>] --- no output for <N>s (updated HH:MM:SS)` を出す。
# columns レイアウト: run を見つけた順に左から並べる。列の幅は画面の幅を列の数で割り、列の間に ` │ ` を挟む。
#   列の幅が 30 桁に満たなくなる数の run があるときは、入るだけの列を出し、入らない run は最下行に
#   `+<N> more: <run> (updated HH:MM:SS) ...` で出す。終わった run の列は、新しい run が入りきらなくなるまで
#   残し、入りきらなければ終わった run から外す。各列の 1 行目は run の名前(色は stream と同じ規則)、
#   2 行目は `updated HH:MM:SS (<N>s ago)` と running / finished (<EXIT の値)。列の幅に入らないときは
#   `(<N>s ago)` を外し、それでも入らなければ先頭の `updated ` も外し、最後は列の幅で切る。
#   3 行目は区切りの線、4 行目から下はその run のログの末尾を列の幅で折り返して出す。
#   全角は 2 桁、ANSI エスケープは除いて数える。
#   列に入れる行は制御文字を整える: \r は最後の \r より後ろだけ残し、SGR(色)以外の ANSI・C0 制御文字・DEL は消し、
#   タブは空白 4 個にする。行を切ったときは色を戻す \x1b[0m を足す。
#   再描画は --interval ごとに画面全体。端末では代替画面(ESC[?1049h)に切り替え、終了時(Ctrl+C を含む)に戻す。
#   --once のときは ESC の制御を入れずに1画面だけ出す(テスト用)。
# 文字コード: output.log の先頭が BOM FF FE なら UTF-16LE(Windows PowerShell 5.1 の `*>`)として、
#   EF BB BF なら UTF-8 の BOM を除いて読む。それ以外は UTF-8。2バイト単位に満たない端数は次の読み込みに回す
# stream の出力: 各行の先頭に `[<run>] ` を付ける。stdout が端末で環境変数 NO_COLOR が空か未設定なら、
#   接頭辞に run ごとに違う色(ANSI 31〜36)を付ける。初回は末尾の --tail 行、以後は追記された完成した行だけ。
#   output.log が短くなったら先頭から読み直し `[<run>] --- log truncated` を出す。
#   done が現れたら残りの行(末尾の改行の無い行を含む)と `[<run>] --- finished (<EXIT の値>)` を出し、
#   その run の追跡をやめる(EXIT: 行がまだ無ければ 0.1 秒おきに最大 10 回読み直す)。開始時に stderr へ `Watching: ...` を出す
# 終わり方: --once は1回描いて終了 / --duration は指定秒数で終了 /
#   --run 指定時は指定した run がすべて終わったら終了 / それ以外は Ctrl+C まで続ける(traceback は出さない)
# exit: 0=正常に終わった(Ctrl+C を含む) / 1=使い方不備(未知の引数・値の無いオプション・形式不正・数値でない値)・python3 が無い

if ! command -v python3 > /dev/null 2>&1; then
    echo "python3 is required but was not found" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

exec python3 - "$@" <<'PY'
import json
import os
import re
import shutil
import sys
import time
import unicodedata

USAGE = ("Usage: workflow-logs.sh [--run <ID>-<N>]... [--tail <lines>] "
         "[--interval <sec>] [--duration <sec>] [--once] "
         "[--layout <columns|stream>] [--width <cols>] [--height <rows>]")
RUNS_DIR = os.path.join(".agents", "workflow", "runs")
RUN_RE = re.compile(r"^[A-Za-z0-9_-]+-[0-9]+$")
NUM_RE = re.compile(r"^[0-9]+(\.[0-9]+)?$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)")
SGR_RE = re.compile(r"\x1b\[[0-9;]*m")
MAX_LINES = 2000
NO_OUTPUT_EVERY = 60


def usage_error(msg=None):
    if msg:
        print(msg, file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(1)


def parse(argv):
    opts = {"runs": [], "tail": 20, "interval": 1.0, "duration": None,
            "once": False, "layout": None, "width": None, "height": None}
    takes_value = ("--run", "--tail", "--interval", "--duration",
                   "--layout", "--width", "--height")
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--once":
            opts["once"] = True
            i += 1
            continue
        if a not in takes_value:
            usage_error("Unknown argument: %s" % a)
        if i + 1 >= len(argv):
            usage_error("Missing value for %s" % a)
        v = argv[i + 1]
        i += 2
        if a == "--run":
            if not RUN_RE.match(v):
                usage_error("Invalid --run: %s" % v)
            if v not in opts["runs"]:
                opts["runs"].append(v)
        elif a == "--tail":
            if not re.match(r"^[0-9]+$", v):
                usage_error("Invalid --tail: %s" % v)
            opts["tail"] = int(v)
        elif a == "--layout":
            if v not in ("columns", "stream"):
                usage_error("Invalid --layout: %s" % v)
            opts["layout"] = v
        elif a in ("--width", "--height"):
            if not re.match(r"^[0-9]+$", v):
                usage_error("Invalid %s: %s" % (a, v))
            n = int(v)
            if n <= 0:
                usage_error("Invalid %s: %s (must be a positive integer)" % (a, v))
            opts[a[2:]] = n
        else:
            if not NUM_RE.match(v):
                usage_error("Invalid %s: %s" % (a, v))
            opts[a[2:]] = float(v)
            if a == "--interval" and opts["interval"] <= 0:
                usage_error("Invalid --interval: %s (must be greater than 0)" % v)
    return opts


opts = parse(sys.argv[1:])
if opts["layout"] is None:
    opts["layout"] = "columns" if sys.stdout.isatty() else "stream"
layout = opts["layout"]

out = open(sys.stdout.fileno(), "w", encoding="utf-8", errors="replace",
           newline="\n", closefd=False)
use_color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
runs = {}
order = []


def run_path(run, name):
    return os.path.join(RUNS_DIR, run, name)


def emit(run, text):
    if use_color:
        color = 31 + order.index(run) % 6
        prefix = "\033[%dm[%s]\033[0m " % (color, run)
    else:
        prefix = "[%s] " % run
    out.write(prefix + text + "\n")
    out.flush()


def decode(b):
    return b.decode("utf-8", errors="replace").rstrip("\r")


def clock_of(mt):
    if mt is None:
        return "--:--:--"
    return time.strftime("%H:%M:%S", time.localtime(mt))


def update_mtime(run):
    for name in ("output.log", "guard.sha256"):
        try:
            return os.path.getmtime(run_path(run, name))
        except OSError:
            continue
    return None


def stale_limit():
    try:
        with open(os.path.join(".agents", "workflow", "config.json"), encoding="utf-8-sig") as f:
            v = json.load(f)["child_agent"]["timeout_seconds"]
        if isinstance(v, int) and not isinstance(v, bool) and v > 0:
            return v
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return 1800


def is_stale(run, limit):
    mt = update_mtime(run)
    return mt is not None and time.time() - mt > limit


def add_lines(run, texts):
    st = runs[run]
    st["lines"].extend(texts)
    if len(st["lines"]) > MAX_LINES:
        del st["lines"][:-MAX_LINES]


def discover():
    if opts["runs"]:
        names = [r for r in opts["runs"] if os.path.isdir(os.path.join(RUNS_DIR, r))]
    else:
        try:
            entries = sorted(os.listdir(RUNS_DIR))
        except OSError:
            entries = []
        limit = stale_limit()
        names = [n for n in entries
                 if os.path.isfile(run_path(n, "guard.sha256"))
                 and not os.path.exists(run_path(n, "done"))
                 and (n in runs or not is_stale(n, limit))]
    for n in names:
        if n in runs:
            continue
        order.append(n)
        runs[n] = {"pos": 0, "buf": b"", "raw": b"", "enc": None, "lines": [],
                   "status": "running", "exit": None, "last_new": time.time()}
        if layout == "stream":
            emit(n, "--- watching (updated %s)" % clock_of(update_mtime(n)))
        first_read(n)


def split_lines(st, data):
    """data を読み込み済みの続きとして受け取り、完成した行を返す。BOM 判定に足りなければ None"""
    if st["enc"] is None:
        if not data or (len(data) < 3 and data[0] in (0xFF, 0xEF)):
            return None
        if data[:2] == b"\xff\xfe":
            st["enc"] = "utf-16-le"
            data = data[2:]
        elif data[:3] == b"\xef\xbb\xbf":
            st["enc"] = "utf-8"
            data = data[3:]
        else:
            st["enc"] = "utf-8"
    if st["enc"] == "utf-16-le":
        raw = st["raw"] + data
        n = len(raw) // 2 * 2
        if n >= 2 and 0xD8 <= raw[n - 1] <= 0xDB:
            n -= 2
        st["raw"] = raw[n:]
        data = raw[:n].decode("utf-16-le", errors="replace").encode("utf-8")
    st["buf"] += data
    parts = st["buf"].split(b"\n")
    st["buf"] = parts[-1]
    return parts[:-1]


def first_read(run):
    st = runs[run]
    try:
        with open(run_path(run, "output.log"), "rb") as f:
            data = f.read()
    except OSError:
        return
    lines = split_lines(st, data)
    if lines is None:
        return
    st["pos"] = len(data)
    decoded = [decode(ln) for ln in lines]
    add_lines(run, decoded)
    if layout == "stream":
        if opts["tail"] == 0:
            shown = []
        else:
            shown = decoded[-opts["tail"]:]
        for ln in shown:
            emit(run, ln)
    st["last_new"] = time.time()


def read_new(run):
    st = runs[run]
    path = run_path(run, "output.log")
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size < st["pos"]:
        st["pos"] = 0
        st["buf"] = b""
        st["raw"] = b""
        st["enc"] = None
        st["lines"] = []
        if layout == "stream":
            emit(run, "--- log truncated")
    if size == st["pos"]:
        return
    try:
        with open(path, "rb") as f:
            f.seek(st["pos"])
            data = f.read()
    except OSError:
        return
    lines = split_lines(st, data)
    if lines is None:
        return
    st["pos"] += len(data)
    decoded = [decode(ln) for ln in lines]
    add_lines(run, decoded)
    if layout == "stream":
        for ln in decoded:
            emit(run, ln)
    if decoded:
        st["last_new"] = time.time()


def exit_value(run):
    try:
        with open(run_path(run, "done"), "rb") as f:
            text = f.read().decode("utf-8", errors="replace").lstrip("\ufeff")
    except OSError:
        return None
    m = re.search(r"^EXIT:(.*?)\r?$", text, re.M)
    return m.group(1).strip() if m else None


def final_exit_value(run):
    for i in range(11):
        v = exit_value(run)
        if v is not None:
            return v
        if i < 10:
            time.sleep(0.1)
    return "unknown"


def poll():
    discover()
    now = time.time()
    for run in list(runs):
        st = runs[run]
        if st["status"] != "running":
            continue
        is_done = os.path.exists(run_path(run, "done"))
        read_new(run)
        if is_done:
            if st["buf"]:
                last = decode(st["buf"])
                st["buf"] = b""
                add_lines(run, [last])
                if layout == "stream":
                    emit(run, last)
            st["status"] = "finished"
            st["exit"] = final_exit_value(run)
            if layout == "stream":
                emit(run, "--- finished (%s)" % st["exit"])
    if layout == "stream":
        for run in list(runs):
            st = runs[run]
            if st["status"] != "running":
                continue
            if now - st["last_new"] >= NO_OUTPUT_EVERY:
                old = int(now - st["last_new"])
                emit(run, "--- no output for %ds (updated %s)"
                     % (old, clock_of(update_mtime(run))))
                st["last_new"] = now


def char_width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def display_width(text):
    text = ANSI_RE.sub("", text)
    return sum(char_width(ch) for ch in text)


def sanitize(text):
    if "\r" in text:
        text = text.rsplit("\r", 1)[1]
    parts = []
    i = 0
    n = len(text)
    while i < n:
        m = ANSI_RE.match(text, i)
        if m:
            if SGR_RE.fullmatch(m.group(0)):
                parts.append(m.group(0))
            i = m.end()
            continue
        ch = text[i]
        if ch == "\t":
            parts.append(" " * 4)
        elif ord(ch) < 0x20 or ord(ch) == 0x7f:
            pass
        else:
            parts.append(ch)
        i += 1
    return "".join(parts)


def wrap(text, width):
    if width < 1:
        width = 1
    lines = []
    cur = ""
    cur_w = 0
    i = 0
    n = len(text)
    while i < n:
        m = ANSI_RE.match(text, i)
        if m:
            cur += m.group(0)
            i = m.end()
            continue
        ch = text[i]
        w = char_width(ch)
        if cur_w + w > width and cur_w > 0:
            lines.append(cur)
            cur = ""
            cur_w = 0
        cur += ch
        cur_w += w
        i += 1
    if cur or not lines:
        lines.append(cur)
    return lines


def truncate_visible(text, width):
    if width < 1:
        return ""
    out_text = ""
    w = 0
    i = 0
    n = len(text)
    while i < n:
        m = ANSI_RE.match(text, i)
        if m:
            out_text += m.group(0)
            i = m.end()
            continue
        ch = text[i]
        cw = char_width(ch)
        if w + cw > width:
            break
        out_text += ch
        w += cw
        i += 1
    return out_text


def fit(text, width):
    if width < 1:
        return ""
    text = truncate_visible(text, width)
    w = display_width(text)
    if "\x1b[" in text:
        text += "\x1b[0m"
    return text + " " * (width - w)


def header2(run, width):
    st = runs[run]
    mt = update_mtime(run)
    ago = 0 if mt is None else max(0, int(time.time() - mt))
    clock = clock_of(mt)
    if st["status"] == "finished":
        right = "finished (%s)" % (st["exit"] if st["exit"] is not None else "unknown")
    else:
        right = "running"
    forms = [
        "updated %s (%ds ago) %s" % (clock, ago, right),
        "updated %s %s" % (clock, right),
        "%s %s" % (clock, right),
    ]
    for form in forms:
        if display_width(form) <= width:
            return fit(form, width)
    return fit(forms[-1], width)


def build_column(run, width, avail):
    st = runs[run]
    name = truncate_visible(run, width)
    if use_color:
        name = "\033[%dm%s\033[0m" % (31 + order.index(run) % 6, name)
    col = [fit(name, width), header2(run, width), "-" * width]
    tail = []
    if avail > 0:
        for ln in reversed(st["lines"]):
            tail = wrap(sanitize(ln), width) + tail
            if len(tail) >= avail:
                break
        tail = tail[-avail:]
    for ln in tail:
        col.append(fit(ln, width))
    return col


def screen_size():
    try:
        ts = shutil.get_terminal_size(fallback=(120, 30))
    except OSError:
        ts = os.terminal_size((120, 30))
    w = opts["width"] or ts.columns
    h = opts["height"] or ts.lines
    return max(1, w), max(1, h)


def build_frame():
    width, height = screen_size()
    allruns = [r for r in order if r in runs]
    capacity = (width + 3) // 33
    if capacity < 1:
        capacity = 1
    if len(allruns) <= capacity:
        shown = list(allruns)
    else:
        shown = []
        for r in allruns:
            if runs[r]["status"] == "running" and len(shown) < capacity:
                shown.append(r)
        for r in allruns:
            if runs[r]["status"] == "finished" and len(shown) < capacity:
                shown.append(r)
        for r in allruns:
            if r not in shown and len(shown) < capacity:
                shown.append(r)
        shown.sort(key=lambda r: allruns.index(r))
    overflow = [r for r in allruns if r not in shown]
    if not shown:
        return [truncate_visible("(no runs)", width)]
    n = len(shown)
    col_w = (width - 3 * (n - 1)) // n
    if col_w < 1:
        col_w = 1
    avail = height - 3 - (1 if overflow else 0)
    if avail < 0:
        avail = 0
    cols = [build_column(r, col_w, avail) for r in shown]
    sep = " \u2502 "
    frame = []
    for row in range(3 + avail):
        cells = []
        for col in cols:
            text = col[row] if row < len(col) else ""
            cells.append(fit(text, col_w))
        frame.append(sep.join(cells))
    if overflow:
        parts = ["%s (updated %s)" % (r, clock_of(update_mtime(r))) for r in overflow]
        line = "+%d more: %s" % (len(overflow), ", ".join(parts))
        if display_width(line) > width:
            if width > 4:
                line = truncate_visible(line, width - 4) + " ..."
            else:
                line = truncate_visible(line, width)
        frame.append(line)
    return frame


def render_columns(alt):
    frame = build_frame()
    if alt:
        out.write("\033[H\033[2J")
        out.write("\n".join(frame))
    else:
        out.write("\n".join(frame) + "\n")
    out.flush()


def main():
    print("Watching: .agents/workflow/runs (Ctrl+C to stop)", file=sys.stderr)
    alt = layout == "columns" and not opts["once"] and sys.stdout.isatty()
    if alt:
        out.write("\033[?1049h\033[H\033[2J")
        out.flush()
    try:
        deadline = time.time() + opts["duration"] if opts["duration"] is not None else None
        while True:
            poll()
            if layout == "columns":
                render_columns(alt)
            if opts["once"]:
                return
            if opts["runs"] and all(r in runs and runs[r]["status"] == "finished"
                                    for r in opts["runs"]):
                return
            if deadline is not None and time.time() >= deadline:
                return
            wait = opts["interval"]
            if deadline is not None:
                wait = min(wait, max(0.0, deadline - time.time()))
            time.sleep(wait)
    finally:
        if alt:
            out.write("\033[?1049l")
            out.flush()


try:
    main()
except (KeyboardInterrupt, BrokenPipeError):
    pass
sys.exit(0)
PY
