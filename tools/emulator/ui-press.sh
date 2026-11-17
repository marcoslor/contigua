#!/usr/bin/env bash
# ui-press: `ui.press` on a real shell server (MCP-86/MCP-108; docs/design/mcp-plan.md B3).
#
#   bash tools/emulator/ui-press.sh --check   # rehearse: no device, no boot
#   bash tools/emulator/ui-press.sh           # boot, pair, prove, kill (one boot)
#
# The API 36 image has no Calculator, so the app is the Clock:
#   1. a press by k (with the tree's label) of a bottom tab not showing makes
#      that tab show;
#   2. a press of a third tab with a stale expect answers `changed` and the
#      shown tab stays (nothing was pressed);
#   3. a key the phone never issued answers `gone`.
# Output is codes, keys, roles and boxes only; a label is compared, never printed.
set -uo pipefail

MODE=boot
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "[ui-press] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
OUT="${CONTIGUA_UI_PRESS_OUT:-$CACHE_DIR/ui-press}"
mkdir -p "$OUT"
CLIENT="$OUT/ui_press_proof.py"

cat > "$CLIENT" <<'PY'
import argparse, os, sys, time

FAILS = []


def line(kind, tag, msg):
    print("%s [%s] %s" % (kind, tag, msg), flush=True)
    if kind == "FAIL":
        FAILS.append(tag)


def check(ok, tag, msg):
    line("PASS" if ok else "FAIL", tag, msg)


SEQ = [100]
PROTO = [None]


def expect(client, proto, deckctl, want, timeout):
    """The next JSON message of type [want], skipping video and other frames."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is deckctl.TIMEOUT:
            break
        if frame is None:
            raise RuntimeError("the phone closed the session")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == want or (msg.get("t") == "error" and want != "ui.tree"):
            return msg
    return {}


def request(client, deckctl, obj, timeout):
    SEQ[0] += 1
    obj = dict(obj, seq=SEQ[0])
    client.send_json(obj)
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = expect(client, PROTO[0], deckctl, obj["t"], max(0.1, deadline - time.time()))
        if not msg or msg.get("seq") == obj["seq"]:
            return msg
    return {}


def tree(client, deckctl, stream):
    return request(client, deckctl, {"t": "ui.tree", "stream": stream}, 8)


def tap(client, proto, stream, at):
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, at[0], at[1]))
    time.sleep(0.05)
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, at[0], at[1]))


NAMES = {"Alarm": "alarm", "Alarms": "alarm", "Timer": "timer", "Timers": "timer",
         "Clock": "clock", "Stopwatch": "stopwatch", "Bedtime": "bedtime"}


def name(node):
    for k in ("text", "desc"):
        v = NAMES.get((node.get(k) or "").strip())
        if v:
            return v
    return None


def tabs(rows):
    """The navigation tabs: a clickable or selectable row named like a tab, lowest on screen wins per name."""
    out = {}
    for n in rows:
        if name(n) and n.get("at") and (n.get("click") or "sel" in n):
            if name(n) not in out or n["box"][1] > out[name(n)]["box"][1]:
                out[name(n)] = n
    return out


def shown(rows):
    """Which tab shows: the selected tab, else the title row at the top named like one."""
    for n in tabs(rows).values():
        if n.get("sel"):
            return name(n)
    titles = sorted((n for n in rows if name(n) and n.get("box") and not n.get("click")), key=lambda n: n["box"][1])
    return name(titles[0]) if titles else None


def main():
    ap = argparse.ArgumentParser()
    for name in ("--host", "--state", "--wt"):
        ap.add_argument(name, required=True)
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    sys.path.insert(0, os.path.join(args.wt, "tools", "fakephone"))
    import deckctl
    import proto
    PROTO[0] = proto

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, None, busy_retries=40)
    client.send_json({"t": "apps.list"})
    apps = [a.get("pkg") or "" for a in expect(client, proto, deckctl, "apps", 20).get("apps", [])]
    clock = next((p for p in apps if "deskclock" in p), None)
    if not clock:
        line("FAIL", "MCP-86", "no Clock app on this image")
        return 1
    client.send_json({"t": "window.open", "stream": 1, "pkg": clock, "w": 720, "h": 1280, "dpi": 320})
    expect(client, proto, deckctl, "window.opened", 40)
    time.sleep(3)
    rows, deadline = [], time.time() + 15
    while time.time() < deadline:
        rows = tree(client, deckctl, 1).get("nodes") or []
        if len(tabs(rows)) >= 2 and shown(rows):
            break
        time.sleep(0.5)
    found, now = tabs(rows), shown(rows)
    line("INFO", "tabs", "%d tabs %s, showing %s" % (len(found), sorted(found), now))
    others = [t for t in ("timer", "alarm", "stopwatch", "clock") if t in found and t != now]
    if not now or len(others) < 2:
        line("FAIL", "MCP-86", "fewer than two other tabs, or no shown tab")
        return 1
    target, stale = found[others[0]], found[others[1]]
    label = lambda n: (n.get("text") or n.get("desc") or "")

    def settle():
        request(client, deckctl, {"t": "ui.settle", "stream": 1, "quietMs": 300, "timeoutMs": 2000}, 8)
        time.sleep(0.5)
        return shown(tree(client, deckctl, 1).get("nodes") or [])

    # 1. A press by k with the tree's label lands on another tab: it shows after.
    r = request(client, deckctl, {"t": "ui.press", "stream": 1, "k": target["k"], "expect": label(target)}, 8)
    check(r.get("ok") is True and r.get("box") == target.get("box"), "MCP-86",
          "press k=%s (%s tab): ok=%s code=%s role=%s box=%s" % (target["k"], others[0], r.get("ok"), r.get("code"), r.get("role"), r.get("box")))
    check(label(r) == label(target), "MCP-108", "the reply names the label it pressed (match=%s)" % (label(r) == label(target)))
    after = settle()
    check(after == others[0], "MCP-86", "showing %s before, %s after the press" % (now, after))

    # 2. A stale expect presses nothing: the tab shown stays.
    r = request(client, deckctl, {"t": "ui.press", "stream": 1, "k": stale["k"], "expect": "Item 3"}, 8)
    check(r.get("ok") is False and r.get("code") == "changed" and r.get("now") == label(stale), "MCP-86",
          "stale expect on k=%s (%s tab): ok=%s code=%s now_is_label=%s" % (stale["k"], others[1], r.get("ok"), r.get("code"), r.get("now") == label(stale)))
    again = settle()
    check(again == others[0], "MCP-86", "showing %s after the refused press (unchanged: %s)" % (again, again == others[0]))

    # 3. A key the phone never issued is gone.
    r = request(client, deckctl, {"t": "ui.press", "stream": 1, "k": 999999}, 8)
    check(r.get("code") == "gone", "MCP-86", "unknown k: code=%s" % r.get("code"))

    client.send_json({"t": "window.close", "stream": 1})
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

if device_present; then echo "[ui-press] abort: $SERIAL already up (not this run's)"; exit 2; fi
kill_emu() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap kill_emu EXIT
T0=$(date +%s)
bash "$REPO_ROOT/tools/emulator/start.sh" --no-build > "$OUT/start.log" 2>&1 \
  || { tail -30 "$OUT/start.log"; echo "[ui-press] start.sh failed"; exit 1; }
echo "[ui-press] booted in $(( $(date +%s) - T0 ))s"
STATE="$CACHE_DIR/deckctl-state-$(date +%s).json"
paired=0
for attempt in 1 2 3 4; do
  bash "$REPO_ROOT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
  if "$PYTHON" "$REPO_ROOT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" \
       --serial "$SERIAL" --adb "$ADB" pair > "$OUT/pair-$attempt.log" 2>&1; then paired=1; break; fi
  sleep 4
done
[ "$paired" = 1 ] || { echo "[ui-press] pairing failed"; tail -5 "$OUT"/pair-*.log; exit 1; }
echo "[ui-press] paired"
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" --wt "$REPO_ROOT"
rc=$?
echo "[ui-press] total $(( $(date +%s) - T0 ))s"
exit $rc
