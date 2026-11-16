#!/bin/bash
# End-to-end self-check for tools/fakephone.
#
# Starts fakephone on a fixed port (no mDNS, auto-allow), pairs with deckctl,
# exercises every deckctl subcommand, validates the recorded H.264 with
# ffprobe, checks the JSON Lines event log, and verifies no ffmpeg/dns-sd
# processes survive the shutdown. Exits 0 only if every check passed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PD_FAKE_TLS_PYTHON:-}"
[ -n "$PY" ] || PY="$(command -v python3.11 || echo /usr/bin/python3)"
FFPROBE="$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fakephone-selfcheck.XXXXXX")"
PORT_FILE="$WORK/port"

FH_PID=""
BUSY_PID=""

die() { echo "SELFCHECK FAIL: $*" >&2; exit 1; }
note() { echo "-- $*"; }

cleanup() {
    [ -n "$FH_PID" ] && kill "$FH_PID" 2>/dev/null
    [ -n "$BUSY_PID" ] && kill "$BUSY_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

# --- start fakephone -------------------------------------------------------
# TMPDIR=$WORK so any leaked ffmpeg keeps our scratch path in its argv,
# which makes orphan detection unambiguous.
TMPDIR="$WORK" "$PY" "$HERE/fakephone.py" \
    --port 0 --no-mdns --auto-allow \
    --state "$WORK/state.json" --events "$WORK/events.jsonl" \
    >"$WORK/fh.out" 2>"$WORK/fh.err" &
FH_PID=$!

for _ in $(seq 1 100); do
    grep -q "listening on" "$WORK/fh.err" 2>/dev/null && break
    sleep 0.1
done
PORT="$("$PY" -c "
import re,sys
m=re.search(r'listening on 0\.0\.0\.0:(\d+)', open('$WORK/fh.err').read())
print(m.group(1) if m else '')
")"
[ -n "$PORT" ] || die "fakephone did not report its port ($(cat "$WORK/fh.err"))"
note "fakephone pid=$FH_PID port=$PORT"

DECK=("$PY" "$HERE/deckctl.py" --host 127.0.0.1 --port "$PORT" \
      --state "$WORK/deck.json" --pair)

# --- deckctl subcommands ---------------------------------------------------
note "apps (pairs, writes the key)"
"${DECK[@]}" apps > "$WORK/apps.txt" 2>"$WORK/apps.err" \
    || die "apps failed: $(cat "$WORK/apps.err")"
grep -q "com.android.settings" "$WORK/apps.txt" || die "apps list missing com.android.settings"
grep -q "com.whatsapp" "$WORK/apps.txt" || die "apps list missing com.whatsapp"
note "apps again (reuses the stored key)"
"${DECK[@]}" apps > /dev/null 2>"$WORK/apps2.err" \
    || die "second apps failed: $(cat "$WORK/apps2.err")"

note "icon"
"${DECK[@]}" icon com.android.settings --out "$WORK/icon.png" > /dev/null 2>"$WORK/icon.err" \
    || die "icon failed: $(cat "$WORK/icon.err")"
"$PY" -c "
import struct,sys
d=open('$WORK/icon.png','rb').read()
assert d[:8]==b'\x89PNG\r\n\x1a\n', 'not a PNG'
w,h=struct.unpack('>II', d[16:24])
assert (w,h)==(96,96), 'icon is %dx%d' % (w,h)
" || die "icon is not a 96x96 PNG"

note "open 1080x2340 (3s)"
"${DECK[@]}" open com.android.settings --w 1080 --h 2340 --dpi 450 --seconds 3 \
    --out "$WORK/open.h264" > "$WORK/open.txt" 2>"$WORK/open.err" \
    || die "open failed: $(cat "$WORK/open.err")"
cat "$WORK/open.txt"
PROBE="$("$FFPROBE" -v error -show_entries stream=codec_name,width,height -of csv=p=0 "$WORK/open.h264")"
echo "$PROBE" | grep -q "^h264,1080,2340$" || die "ffprobe said '$PROBE', expected 'h264,1080,2340'"

note "resize-test"
"${DECK[@]}" resize-test > "$WORK/resize.txt" 2>"$WORK/resize.err" \
    || die "resize-test failed: $(cat "$WORK/resize.err")"
cat "$WORK/resize.txt"

note "input-test"
"${DECK[@]}" input-test > "$WORK/input.txt" 2>"$WORK/input.err" \
    || die "input-test failed: $(cat "$WORK/input.err")"
cat "$WORK/input.txt"

note "pause-test"
"${DECK[@]}" pause-test > "$WORK/pause.txt" 2>"$WORK/pause.err" \
    || die "pause-test failed: $(cat "$WORK/pause.err")"
cat "$WORK/pause.txt"

note "latency"
"${DECK[@]}" latency --count 20 > "$WORK/latency.txt" 2>"$WORK/latency.err" \
    || die "latency failed: $(cat "$WORK/latency.err")"
cat "$WORK/latency.txt"

note "quality-test (window.quality + a socket stall)"
"${DECK[@]}" quality-test com.android.settings --w 720 --h 1280 --dpi 320 \
    --base-seconds 2 --seconds 2 --stall 1.5 --recover-seconds 2 --motion 0 \
    > "$WORK/quality.txt" 2>"$WORK/quality.err" \
    || die "quality-test failed: $(cat "$WORK/quality.err")"
cat "$WORK/quality.txt"
grep -q "phase quality" "$WORK/quality.txt" || die "quality-test printed no quality phase"
grep -q "phase stall" "$WORK/quality.txt" || die "quality-test printed no stall phase"
grep -q "window.quality" "$WORK/fh.err" || die "fakephone did not log window.quality"

# --- ui.settle (MCP-81 fake-phone selfcheck) --------------------------------
note "ui-settle (answers settled after --settle-ms)"
"${DECK[@]}" ui-settle > "$WORK/settle.txt" 2>"$WORK/settle.err" \
    || die "ui-settle failed: $(cat "$WORK/settle.err")"
cat "$WORK/settle.txt"
"$PY" - "$WORK/settle.txt" <<'PY' || die "ui-settle reply assertions failed"
import re
import sys

line = open(sys.argv[1]).read().strip()
m = re.search(r"ok=True settled=True waitedMs=(\d+) events=(\d+) reason=None elapsed_ms=(\d+)", line)
assert m, "unexpected ui-settle line: %r" % line
assert int(m.group(1)) >= 120, "waitedMs < 120: %s" % m.group(1)
assert int(m.group(2)) == 0, "events != 0: %s" % m.group(2)
assert int(m.group(3)) < 300, "answered after %s ms, not within 300" % m.group(3)
print("  settle waitedMs=%s" % m.group(1))
PY

# --- second simultaneous session must be rejected --------------------------
note "busy: a second session is rejected while the first keeps streaming"
"${DECK[@]}" open --phone --w 1080 --h 2340 --dpi 450 --seconds 4 \
    --out "$WORK/busy1.h264" > "$WORK/busy1.txt" 2>"$WORK/busy1.err" &
BUSY_PID=$!
sleep 1.5
if "${DECK[@]}" apps > "$WORK/busy2.txt" 2>"$WORK/busy2.err"; then
    die "second simultaneous session was accepted instead of rejected"
fi
grep -qi "busy" "$WORK/busy2.err" || die "second session error is not 'busy': $(cat "$WORK/busy2.err")"
wait "$BUSY_PID" || die "first session failed while the second was rejected: $(cat "$WORK/busy1.err")"
BUSY_PID=""
grep -q "fps=" "$WORK/busy1.txt" || die "first session produced no video"

# --- event log -------------------------------------------------------------
note "event log"
"$PY" - "$WORK/events.jsonl" <<'PY' || die "event log assertions failed"
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
states = [e["state"] for e in events if e["ev"] == "session"]
assert "open" in states, "no session open event: %r" % states
assert "auth_ok" in states, "no session auth_ok event: %r" % states

touches = [e for e in events if e["ev"] == "input" and e["kind"] == "touch"]
actions = {e["action"] for e in touches}
assert 0 in actions, "no touch-down input event: %r" % actions
assert 1 in actions, "no touch-up input event: %r" % actions
for e in touches:
    assert 0.0 <= e["nx"] <= 1.0 and 0.0 <= e["ny"] <= 1.0, "touch coords not normalized"

configs = [(e["w"], e["h"]) for e in events if e["ev"] == "video" and e.get("config")]
assert (1080, 2340) in configs, "no VIDEO_CONFIG for 1080x2340: %r" % configs
assert (720, 1280) in configs, "no VIDEO_CONFIG for 720x1280 after resize: %r" % configs

qualities = [e for e in events if e["ev"] == "quality"]
assert qualities, "no quality event from window.quality"
assert qualities[0]["bitrate"] == 1000000, "quality event bitrate: %r" % qualities[0]

print("  %d events, session states=%s" % (len(events), states))
print("  touch actions=%s video configs=%s" % (sorted(actions), sorted(set(configs))))
PY

# --- shutdown + orphan check ----------------------------------------------
note "shutdown"
kill "$FH_PID" 2>/dev/null
wait "$FH_PID" 2>/dev/null
FH_PID=""
sleep 1
if pgrep -f "$WORK" > /dev/null 2>&1; then
    pgrep -fl "$WORK" >&2
    die "ffmpeg/dns-sd processes survived shutdown"
fi

rm -rf "$WORK"
echo "SELFCHECK PASS"
exit 0
