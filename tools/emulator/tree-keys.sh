#!/usr/bin/env bash
# tree-keys: a row's `k` on a real shell server (MCP-71; docs/design/mcp-plan.md B2).
#
#   bash tools/emulator/tree-keys.sh --check   # rehearse: no device, no boot
#   bash tools/emulator/tree-keys.sh           # boot, pair, prove, kill (one boot)
#
# The API 36 image has no Calculator, so the idle screen is the Clock's Alarm tab:
#   1. the tab is found by its tree row and tapped, and the display settles;
#   2. two reads of the idle tab give every node the same `k` (a node is matched
#      across reads by its role, view id, labels and box), the keys are unique
#      integers within each reply, and no row carries a `ref`;
#   3. the counts of `heading` and `covered` rows are printed (no check: what an
#      app marks is the app's).
# Output is counts, keys and durations only; a node's text is matched here to
# find the tab and to pair nodes, never printed.
set -uo pipefail

MODE=boot
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "[tree-keys] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
OUT="${CONTIGUA_TREE_KEYS_OUT:-$CACHE_DIR/tree-keys}"
mkdir -p "$OUT"
CLIENT="$OUT/tree_keys_proof.py"

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


def identity(node):
    """What pairs one node across two reads of an idle screen."""
    return (node.get("role"), node.get("id"), node.get("text"), node.get("desc"),
            tuple(node.get("box") or ()), node.get("l"))


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
    line("INFO", "apps", "%d apps listed, clock=%s" % (len(apps), bool(clock)))
    if not clock:
        line("FAIL", "MCP-71", "no Clock app on this image")
        return 1
    client.send_json({"t": "window.open", "stream": 1, "pkg": clock, "w": 720, "h": 1280, "dpi": 320})
    opened = expect(client, proto, deckctl, "window.opened", 40)
    line("INFO", "open", "window.opened stream=%s" % opened.get("stream"))
    time.sleep(3)

    tab = None
    deadline = time.time() + 15
    while tab is None and time.time() < deadline:
        for node in tree(client, deckctl, 1).get("nodes") or []:
            if any((node.get(k) or "").strip() in ("Alarm", "Alarms") for k in ("text", "desc")) and node.get("at"):
                tab = node
                break
        else:
            time.sleep(0.5)
    if tab is None:
        line("FAIL", "MCP-71", "no Alarm tab row found")
        return 1
    tap(client, proto, 1, tab["at"])
    s = request(client, deckctl, {"t": "ui.settle", "stream": 1, "quietMs": 300, "timeoutMs": 2000}, 8)
    line("INFO", "settle", "Alarm tab: settled=%s waitedMs=%s" % (s.get("settled"), s.get("waitedMs")))
    time.sleep(1)

    one, two = tree(client, deckctl, 1), tree(client, deckctl, 1)
    rows1, rows2 = one.get("nodes") or [], two.get("nodes") or []
    for name, rows in (("read 1", rows1), ("read 2", rows2)):
        keys = [n.get("k") for n in rows]
        check(bool(rows) and all(isinstance(k, int) for k in keys) and len(set(keys)) == len(keys),
              "MCP-71", "%s: %d rows, every k a unique integer" % (name, len(rows)))
        check(all("ref" not in n for n in rows), "MCP-71", "%s: no row carries a ref" % name)
    by1 = {}
    for n in rows1:
        by1.setdefault(identity(n), []).append(n.get("k"))
    same = differ = unmatched = 0
    for n in rows2:
        ks = by1.get(identity(n))
        if not ks:
            unmatched += 1
        elif n.get("k") in ks:
            same += 1
        else:
            differ += 1
    check(len(rows1) == len(rows2) and differ == 0 and unmatched == 0 and same == len(rows2), "MCP-71",
          "two reads of the idle Alarm tab: rows %d/%d, same k %d, different k %d, unmatched %d, k %s"
          % (len(rows1), len(rows2), same, differ, unmatched, [n.get("k") for n in rows2]))
    line("INFO", "MCP-72", "heading rows: %d" % sum(1 for n in rows2 if n.get("heading") is True))
    line("INFO", "MCP-73", "covered rows: %d (window: %d)" % (
        sum(1 for n in rows2 if "covered" in n), sum(1 for n in rows2 if n.get("covered") == "window")))

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

if device_present; then echo "[tree-keys] abort: $SERIAL already up (not this run's)"; exit 2; fi
kill_emu() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap kill_emu EXIT
T0=$(date +%s)
bash "$REPO_ROOT/tools/emulator/start.sh" --no-build > "$OUT/start.log" 2>&1 \
  || { tail -30 "$OUT/start.log"; echo "[tree-keys] start.sh failed"; exit 1; }
echo "[tree-keys] booted in $(( $(date +%s) - T0 ))s"
STATE="$CACHE_DIR/deckctl-state-$(date +%s).json"
paired=0
for attempt in 1 2 3 4; do
  bash "$REPO_ROOT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
  if "$PYTHON" "$REPO_ROOT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" \
       --serial "$SERIAL" --adb "$ADB" pair > "$OUT/pair-$attempt.log" 2>&1; then paired=1; break; fi
  sleep 4
done
[ "$paired" = 1 ] || { echo "[tree-keys] pairing failed"; tail -5 "$OUT"/pair-*.log; exit 1; }
echo "[tree-keys] paired"
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" --wt "$REPO_ROOT"
rc=$?
echo "[tree-keys] total $(( $(date +%s) - T0 ))s"
exit $rc
