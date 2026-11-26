#!/usr/bin/env bash
# settle: the phone's `ui.settle` and loading signal on a real shell server
# (MCP-81, MCP-103, MCP-107).
#
#   bash tools/emulator/settle.sh --check   # rehearse: no device, no boot
#   bash tools/emulator/settle.sh           # boot, pair, prove, kill (one boot)
#   bash tools/emulator/settle.sh --ab      # the same, plus the tree-read A/B:
#     debug.contigua.ui_cache=keep (no cache clear) against the fix (MCP-107)
#
# Checks, all on native apps (the API 36 image has no Calculator and its
# browser exposes no page nodes; web spinners are not a loading signal, MCP-103):
#   0. the rig's stopwatch (an earlier run may have left it running) is
#      paused and reset through its own buttons, by ref;
#   1. a tap on the Clock's Alarm tab, found by its tree row, settles within 2 s;
#   2. a running stopwatch answers settled false, reason changes, at 2000 ms,
#      and is then stopped and reset;
#   3. a native indeterminate ProgressBar (Settings screens that scan or load)
#      is marked `loading` on its row and the reply, and a settle during it
#      answers reason loading;
#   4. a settle sent right after `window.open` or `link.open` never answers
#      `no_display` (a display with no window yet is still opening, MCP-107);
#   5. the debug log line names `contigua-ui-tree` as the thread a watch ran
#      its events on, whatever thread the listener fired on (MCP-107).
# Output is counts, codes, states, durations and class names only; a node's
# text is matched here to find a tab, never printed.
set -uo pipefail

MODE=boot
AB=()
case "${1:-}" in
  --check) MODE=check ;;
  --ab) AB=(--ab) ;;  # also the B1 regression A/B (debug.contigua.ui_cache), same boot
  "") ;;
  *) echo "[settle] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
OUT="${CONTIGUA_SETTLE_OUT:-$CACHE_DIR/settle}"
mkdir -p "$OUT"
CLIENT="$OUT/settle_proof.py"

cat > "$CLIENT" <<'PY'
import argparse, http.server, os, socket, subprocess, sys, threading, time

FAILS = []


def line(kind, tag, msg):
    print("%s [%s] %s" % (kind, tag, msg), flush=True)
    if kind == "FAIL":
        FAILS.append(tag)


def check(ok, tag, msg):
    line("PASS" if ok else "FAIL", tag, msg)


class Phone(object):
    def __init__(self, client, proto, deckctl):
        self.client, self.proto, self.deckctl = client, proto, deckctl
        self.lock = threading.Lock()
        self.msgs = []
        self.closed = False
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            frame = self.client.recv(0.5)
            if frame is self.deckctl.TIMEOUT:
                continue
            if frame is None:
                self.closed = True
                return
            if frame.type == self.proto.TYPE_JSON:
                with self.lock:
                    self.msgs.append(self.proto.unpack_json(frame))

    def wait(self, pred, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for i, m in enumerate(self.msgs):
                    if pred(m):
                        del self.msgs[i]
                        return m
            if self.closed:
                raise RuntimeError("the phone closed the session")
            time.sleep(0.01)
        return None

    def request(self, obj, timeout):
        self.client.send_json(obj)
        return self.wait(lambda m: m.get("t") == obj["t"] and m.get("seq") == obj.get("seq"), timeout)

    def tap(self, stream, at):
        p = self.proto
        self.client.send_raw(p.pack_touch(stream, p.TOUCH_DOWN, 0, at[0], at[1]))
        time.sleep(0.05)
        self.client.send_raw(p.pack_touch(stream, p.TOUCH_UP, 0, at[0], at[1]))


SEQ = [100]


def seq():
    SEQ[0] += 1
    return SEQ[0]


def tree(phone, stream):
    return phone.request({"t": "ui.tree", "stream": stream, "seq": seq()}, 8) or {}


def send_settle(phone, stream, quiet, timeout):
    s = seq()
    phone.client.send_json({"t": "ui.settle", "stream": stream, "seq": s, "quietMs": quiet, "timeoutMs": timeout})
    return s, time.time()


def await_settle(phone, s, started, timeout):
    r = phone.wait(lambda m: m.get("t") == "ui.settle" and m.get("seq") == s, timeout / 1000.0 + 6) or {}
    r["_rtt"] = int((time.time() - started) * 1000)
    return r


def settle(phone, stream, quiet, timeout):
    s, started = send_settle(phone, stream, quiet, timeout)
    return await_settle(phone, s, started, timeout)


def describe(r):
    return "ok=%s settled=%s reason=%s waitedMs=%s events=%s code=%s rtt_ms=%s" % (
        r.get("ok"), r.get("settled"), r.get("reason"), r.get("waitedMs"), r.get("events"),
        r.get("code"), r.get("_rtt"))


def find(phone, stream, labels, timeout=15):
    """The row (with `at`) of the first node whose text or desc is one of [labels]."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for node in tree(phone, stream).get("nodes") or []:
            for key in ("text", "desc"):
                if (node.get(key) or "").strip() in labels and node.get("at"):
                    return node
        time.sleep(0.5)
    return None


def is_opened(stream):
    return lambda m: m.get("t") in ("window.opened", "error") and m.get("stream") == stream


def open_window(phone, msg, stream):
    phone.client.send_json(msg)
    return phone.wait(is_opened(stream), 40)


def close(phone, stream):
    phone.client.send_json({"t": "window.close", "stream": stream})
    phone.wait(lambda m: m.get("t") == "window.closed" and m.get("stream") == stream, 15)


SIZE = {"w": 720, "h": 1280, "dpi": 320}

# Native screens that show an indeterminate ProgressBar while they scan or load.
SPINNERS = [
    "com.android.settings/.Settings$NetworkProviderSettingsActivity",
    "com.android.settings/.Settings$WifiSettingsActivity",
    "com.android.settings/.Settings$ManageApplicationsActivity",
    "com.android.settings/.Settings$StorageDashboardActivity",
    "com.android.settings/.Settings$BluetoothSettingsActivity",
]


def opening_settle(phone, stream, msg, tag):
    """Decision 1: a settle right after an open never answers no_display."""
    phone.client.send_json(msg)
    s0, t0 = send_settle(phone, stream, 300, 2000)   # before window.opened: no stream yet, or opening
    early = await_settle(phone, s0, t0, 2000)
    opened = phone.wait(is_opened(stream), 40)
    s1, t1 = send_settle(phone, stream, 300, 2000)   # the moment window.opened arrives
    late = await_settle(phone, s1, t1, 2000)
    check(early.get("code") != "no_display", "MCP-107", "%s, settle sent with the open: %s" % (tag, describe(early)))
    check(opened is not None and opened.get("t") == "window.opened" and late.get("ok") is True,
          "MCP-107", "%s, settle sent at window.opened: %s" % (tag, describe(late)))
    return opened


def ab(phone, adb, streams, tag):
    """The B1 regression A/B: the same ui.tree with the node-cache clear
    skipped (debug.contigua.ui_cache=keep, the branch before the fix) and
    with it (the fix). Counts only."""
    counts = {}
    for rnd in range(3):
        for mode in ("keep", "clear"):
            adb("shell", "setprop", "debug.contigua.ui_cache", mode)
            for stream in streams:
                t = tree(phone, stream)
                counts.setdefault((mode, stream), []).append(len(t.get("nodes") or []))
    adb("shell", "setprop", "debug.contigua.ui_cache", "clear")
    for (mode, stream), ns in sorted(counts.items()):
        line("INFO", "AB", "%s mode=%s stream=%d nodes=%s" % (tag, mode, stream, ns))
    return counts


def stopwatch_reset(phone, stream):
    """Leave the rig's stopwatch stopped at zero: Pause if it runs, then Reset, by ref."""
    pause = find(phone, stream, ("Pause", "Stop"), 3)
    if pause:
        phone.tap(stream, pause["at"])
        time.sleep(0.8)
    reset = find(phone, stream, ("Reset",), 3)
    if reset:
        phone.tap(stream, reset["at"])
        time.sleep(0.8)
    return bool(pause), bool(reset)


def main():
    ap = argparse.ArgumentParser()
    for name in ("--host", "--state", "--wt", "--adb", "--serial", "--out"):
        ap.add_argument(name, required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--ab", action="store_true")
    args = ap.parse_args()
    sys.path.insert(0, os.path.join(args.wt, "tools", "fakephone"))
    import deckctl
    import proto

    # A local blank page for link.open, served to the emulator through adb reverse.
    with open(os.path.join(args.out, "blank.html"), "w") as fp:
        fp.write("<!doctype html><title>settle</title><p>settle</p>")
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    http_port = sock.getsockname()[1]
    sock.close()
    handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=args.out, **kw)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", http_port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    adb = lambda *a: subprocess.run([args.adb, "-s", args.serial] + list(a), capture_output=True, timeout=30)
    adb("reverse", "tcp:%d" % http_port, "tcp:%d" % http_port)

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, None, busy_retries=40)
    client.send_json({"t": "apps.list"})
    apps = [a.get("pkg") or "" for a in deckctl.expect_json(client, "apps", timeout=20).get("apps", [])]
    phone = Phone(client, proto, deckctl)
    clock = next((p for p in apps if "deskclock" in p), None)
    line("INFO", "apps", "%d apps listed, clock=%s" % (len(apps), bool(clock)))

    # 4a. window.open: a settle with the open and one at window.opened.
    if clock:
        opening_settle(phone, 1, dict(SIZE, t="window.open", stream=1, pkg=clock), "window.open")
    else:
        line("FAIL", "MCP-81", "no Clock app on this image")
        return 1

    settle(phone, 1, 300, 2000)  # let the launch finish first
    if args.ab:
        o = open_window(phone, dict(SIZE, t="window.open", stream=9, pkg="com.android.settings"), 9)
        time.sleep(3)
        c = ab(phone, adb, (1, 9), "after open")
        whole = all(min(c[("clear", s_)]) > 1 for s_ in (1, 9))
        check(whole, "MCP-107", "with the cache cleared every read is whole (min rows %s)" % (
            [min(c[("clear", s_)]) for s_ in (1, 9)]))

    # 0. The rig's stopwatch, left running by an earlier run, is stopped and reset.
    sw = find(phone, 1, ("Stopwatch",))
    if sw:
        phone.tap(1, sw["at"])
        time.sleep(1.5)
        paused, reset = stopwatch_reset(phone, 1)
        line("INFO", "rig", "stopwatch at start: was running=%s, reset=%s" % (paused, reset))
    else:
        line("FAIL", "MCP-81", "no Stopwatch tab row found")

    # 1. A tap on the Alarm tab (a static list), by its row, settles within 2 s.
    tab = find(phone, 1, ("Alarm", "Alarms"))
    if tab:
        phone.tap(1, tab["at"])
        r = settle(phone, 1, 300, 2000)
        check(r.get("ok") is True and r.get("settled") is True and (r.get("waitedMs") or 9999) < 2000,
              "MCP-81", "Alarm tab tap (row %s): %s" % (tab.get("role"), describe(r)))
        check((r.get("events") or 0) >= 1, "MCP-107",
              "the tap's content changes were counted on the virtual display (events=%s)" % r.get("events"))
    else:
        line("FAIL", "MCP-81", "no Alarm tab row found")

    if args.ab:
        # Events have flowed (the tap, the settle): the A/B again.
        ab(phone, adb, (1, 9), "after a settle")
        close(phone, 9)

    # 2. A running stopwatch: settled false, reason changes, at 2000 ms; then stop and reset it.
    sw = find(phone, 1, ("Stopwatch",))
    running = False
    if sw:
        phone.tap(1, sw["at"])
        time.sleep(1.5)
        start = find(phone, 1, ("Start",))
        if start:
            phone.tap(1, start["at"])
            time.sleep(1.0)
            running = True
    if running:
        r = settle(phone, 1, 300, 2000)
        check(r.get("ok") is True and r.get("settled") is False and r.get("reason") == "changes"
              and abs((r.get("waitedMs") or 0) - 2000) <= 50, "MCP-81", "running stopwatch: " + describe(r))
        paused, reset = stopwatch_reset(phone, 1)
        check(paused and reset, "rig", "stopwatch stopped=%s and reset=%s by ref" % (paused, reset))
    else:
        line("FAIL", "MCP-81", "could not start the stopwatch (tab=%s)" % bool(sw))
    close(phone, 1)

    # 4b. link.open: the same two settles.
    opened = opening_settle(phone, 2, dict(SIZE, t="link.open", stream=2, url="http://127.0.0.1:%d/blank.html" % http_port), "link.open")
    close(phone, 2)

    # 3. A native indeterminate ProgressBar: loading on the row and the reply,
    #    and a settle during it says loading.
    stream, caught, proved = 10, 0, False
    for component in SPINNERS:
        for attempt in range(2):
            stream += 1
            opened = open_window(phone, dict(SIZE, t="window.open", stream=stream,
                                              pkg=component.split("/")[0], activity=component), stream)
            if not opened or opened.get("t") != "window.opened":
                line("INFO", "MCP-103", "%s: open answered %s %s" % (component.split("$")[-1],
                     opened and opened.get("t"), opened and opened.get("code")))
                break
            deadline = time.time() + 12
            while time.time() < deadline:
                t = tree(phone, stream)
                rows = [n for n in t.get("nodes") or [] if n.get("loading")]
                if not rows and not t.get("loading"):
                    time.sleep(0.1)
                    continue
                caught += 1
                check(t.get("loading") is True and len(rows) >= 1, "MCP-103",
                      "%s: reply loading=%s, %d loading rows, roles %s" % (
                          component.split("$")[-1], t.get("loading"), len(rows), sorted({n.get("role") for n in rows})))
                r = settle(phone, stream, 300, 2000)
                after = tree(phone, stream)
                line("INFO", "MCP-107", "%s: settle during the spinner: %s; tree after loading=%s" % (
                    component.split("$")[-1], describe(r), after.get("loading")))
                if r.get("ok") is True and r.get("settled") is False and r.get("reason") == "loading":
                    proved = True
                elif r.get("settled") is True:
                    # The spinner went away inside the settle: settled is right then.
                    check(not after.get("loading"), "MCP-107",
                          "a settled display has no loading signal in the next read")
                break
            close(phone, stream)
            if proved:
                break
        if proved:
            break
    if caught == 0:
        line("FAIL", "MCP-103", "no native indeterminate ProgressBar was caught on any candidate screen")
    else:
        check(proved, "MCP-107", "a settle during a native spinner answered reason loading (%d spinner reads)" % caught)

    adb("reverse", "--remove", "tcp:%d" % http_port)
    server.shutdown()
    print("RESULT %s (%d failed: %s)" % ("PASS" if not FAILS else "FAIL", len(FAILS), ",".join(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
PY

if [ "$MODE" = check ]; then
  rc=0
  bash -n "$0" || { echo "CHECK FAIL: bash -n"; rc=1; }
  "$PYTHON" -m py_compile "$CLIENT" || { echo "CHECK FAIL: py_compile"; rc=1; }
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; rc=1; }
  [ "$rc" = 0 ] && echo "CHECK OK"
  exit $rc
fi

if device_present; then echo "[settle] abort: $SERIAL already up (not this run's)"; exit 2; fi
kill_emu() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap kill_emu EXIT
T0=$(date +%s)
bash "$REPO_ROOT/tools/emulator/start.sh" --no-build > "$OUT/start.log" 2>&1 \
  || { tail -30 "$OUT/start.log"; echo "[settle] start.sh failed"; exit 1; }
echo "[settle] booted in $(( $(date +%s) - T0 ))s"
STATE="$CACHE_DIR/deckctl-state-$(date +%s).json"
paired=0
for attempt in 1 2 3 4; do
  bash "$REPO_ROOT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
  if "$PYTHON" "$REPO_ROOT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" \
       --serial "$SERIAL" --adb "$ADB" pair > "$OUT/pair-$attempt.log" 2>&1; then paired=1; break; fi
  sleep 4
done
[ "$paired" = 1 ] || { echo "[settle] pairing failed"; tail -5 "$OUT"/pair-*.log; exit 1; }
echo "[settle] paired"
emu logcat -c >/dev/null 2>&1 || true
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" --wt "$REPO_ROOT" \
  --adb "$ADB" --serial "$SERIAL" --out "$OUT" ${AB[@]+"${AB[@]}"}
rc=$?
emu logcat -d -s ContiguaSvc:I 2>/dev/null | grep -E "ui\.settle|ui\.tree" > "$OUT/logcat-ui.txt" || true
echo "[settle] logcat ui lines: $(wc -l < "$OUT/logcat-ui.txt"); total $(( $(date +%s) - T0 ))s"
# MCP-107: the debug build logs, once, the listener's thread and the thread the
# watch ran the event on; the watch's must be its own looper.
thread_line=$(grep -m1 "ui.settle: event thread=" "$OUT/logcat-ui.txt" | sed 's/.*ui.settle: //')
if [ -z "$thread_line" ]; then
  echo "FAIL [MCP-107] no event-thread line in the log"; rc=1
elif [[ "$thread_line" == *"watch thread=contigua-ui-tree"* ]]; then
  echo "ok [MCP-107] $thread_line"
else
  echo "FAIL [MCP-107] $thread_line"; rc=1
fi
exit $rc
