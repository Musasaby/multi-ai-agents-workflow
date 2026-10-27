#!/bin/bash
set -uo pipefail

# 複数の子エージェント run の output.log を、1つの画面に流し続ける(tail -f の複数 run 版)。
# Usage: workflow-logs.sh [--run <ID>-<N>]... [--tail <行数>] [--interval <秒>] [--duration <秒>] [--once]
#   --run       指定した名前の run だけを追う(複数指定可。形式は ^[A-Za-z0-9_-]+-[0-9]+$)。
#               ディレクトリがまだ無ければ現れるまで待つ
#   --tail      run を初めて見つけたとき、output.log の末尾から出す行数(既定 20)
#   --interval  run の探し直しとログ確認の間隔(秒。既定 1。0 より大きい数だけ。0・0.0 は使い方の誤り)
#   --duration  指定した秒数で終了する
#   --once      対象の run の末尾を出して終了する
# 対象の run: --run があればその名前の run。無ければ .agents/workflow/runs/*/ のうち
#   guard.sha256 があり done が無いもの(--interval ごとに探し直し、新しい run を加える)。
#   output.log(無ければ guard.sha256)の最終更新が child_agent.timeout_seconds 秒
#   (.agents/workflow/config.json。読めない・正の整数でなければ 1800)より前の run は、
#   止まった run(kill・クラッシュで done が無い)として対象にしない。--run 指定の run には当てない
# 文字コード: output.log の先頭が BOM FF FE なら UTF-16LE(Windows PowerShell 5.1 の `*>`)として、
#   EF BB BF なら UTF-8 の BOM を除いて読む。それ以外は UTF-8。2バイト単位に満たない端数は次の読み込みに回す
# 出力: 各行の先頭に `[<run>] ` を付ける。stdout が端末で環境変数 NO_COLOR が空か未設定なら、接頭辞に
#   run ごとに違う色(ANSI 31〜36)を付ける。初回は末尾の --tail 行、以後は追記された完成した行だけ。
#   output.log が短くなったら先頭から読み直し `[<run>] --- log truncated` を出す。
#   done が現れたら残りの行(末尾の改行の無い行を含む)と `[<run>] --- finished (<EXIT の値>)` を出し、
#   その run の追跡をやめる(EXIT: 行がまだ無ければ 0.1 秒おきに最大 10 回読み直す)。開始時に stderr へ `Watching: ...` を出す
# 終わり方: --once は末尾を出して終了 / --duration は指定秒数で終了 /
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
import sys
import time

USAGE = ("Usage: workflow-logs.sh [--run <ID>-<N>]... [--tail <lines>] "
         "[--interval <sec>] [--duration <sec>] [--once]")
RUNS_DIR = os.path.join(".agents", "workflow", "runs")
RUN_RE = re.compile(r"^[A-Za-z0-9_-]+-[0-9]+$")
NUM_RE = re.compile(r"^[0-9]+(\.[0-9]+)?$")


def usage_error(msg=None):
    if msg:
        print(msg, file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(1)


def parse(argv):
    opts = {"runs": [], "tail": 20, "interval": 1.0, "duration": None, "once": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--once":
            opts["once"] = True
            i += 1
            continue
        if a not in ("--run", "--tail", "--interval", "--duration"):
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
        else:
            if not NUM_RE.match(v):
                usage_error("Invalid %s: %s" % (a, v))
            opts[a[2:]] = float(v)
            if a == "--interval" and opts["interval"] <= 0:
                usage_error("Invalid --interval: %s (must be greater than 0)" % v)
    return opts


opts = parse(sys.argv[1:])
out = open(sys.stdout.fileno(), "w", encoding="utf-8", errors="replace",
           newline="\n", closefd=False)
use_color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
tracked = {}
finished = set()
order = []


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
    for name in ("output.log", "guard.sha256"):
        try:
            return time.time() - os.path.getmtime(run_path(run, name)) > limit
        except OSError:
            continue
    return False


def run_path(run, name):
    return os.path.join(RUNS_DIR, run, name)


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
                 and (n in tracked or not is_stale(n, limit))]
    for n in names:
        if n in tracked or n in finished:
            continue
        order.append(n)
        tracked[n] = {"pos": 0, "buf": b"", "raw": b"", "enc": None}
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
    st = tracked[run]
    try:
        with open(run_path(run, "output.log"), "rb") as f:
            data = f.read()
    except OSError:
        return
    lines = split_lines(st, data)
    if lines is None:
        return
    st["pos"] = len(data)
    if opts["tail"] == 0:
        lines = []
    else:
        lines = lines[-opts["tail"]:]
    for ln in lines:
        emit(run, decode(ln))


def read_new(run):
    st = tracked[run]
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
    for ln in lines:
        emit(run, decode(ln))


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
    for run in list(tracked):
        is_done = os.path.exists(run_path(run, "done"))
        read_new(run)
        if is_done:
            st = tracked.pop(run)
            if st["buf"]:
                emit(run, decode(st["buf"]))
            emit(run, "--- finished (%s)" % final_exit_value(run))
            finished.add(run)


def main():
    print("Watching: .agents/workflow/runs (Ctrl+C to stop)", file=sys.stderr)
    deadline = time.time() + opts["duration"] if opts["duration"] is not None else None
    while True:
        poll()
        if opts["once"]:
            return
        if opts["runs"] and all(r in finished for r in opts["runs"]):
            return
        if deadline is not None and time.time() >= deadline:
            return
        wait = opts["interval"]
        if deadline is not None:
            wait = min(wait, max(0.0, deadline - time.time()))
        time.sleep(wait)


try:
    main()
except (KeyboardInterrupt, BrokenPipeError):
    pass
sys.exit(0)
PY
