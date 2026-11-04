#!/usr/bin/env bash
# `fs.digest` on the emulator rig (docs/design/files.md § Sync integrity,
# FILES-35/FILES-33): two folders through the phone's own server, their digest
# before and after an add, an unchanged folder that keeps its digest, a file
# that answers not_found, and Android's transient names left out of the
# listing at depth 1 and depth 2. The folders are removed at the end.
#
#   tools/emulator/start.sh
#   tools/emulator/fs-digest.sh
#
# No File Provider and no Mac app are involved.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DECKCTL="$REPO_ROOT/tools/fakephone/deckctl.py"
STATE="$CACHE_DIR/deckctl-state.json"
WORK="$AGENT_DIR/fs-digest"
A="DCIM/PocketDeck-digest-a"
B="DCIM/PocketDeck-digest-b"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
short() { printf '%s' "$1" | cut -c1-12; }

device_present || die "$SERIAL is not running - run tools/emulator/start.sh first"
DEVPORT="$(ensure_forward)" || die "cannot find the PocketDeck server port on $SERIAL (is the app running?)"
step "forward: 127.0.0.1:$PORT -> device tcp:$DEVPORT"
mkdir -p "$WORK"

# The app's shell service can restart between commands (a new listening port
# each time), so the forward is re-read per call.
deckctl() {
    ensure_forward >/dev/null 2>&1 || true
    "$PYTHON" "$DECKCTL" --host 127.0.0.1 --port "$PORT" --state "$STATE" "$@"
}

if ! "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1; then
    "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
        || die "could not pair with the rig"
fi

# --- two folders, a transient pair and one file -----------------------------
emu shell "rm -rf /sdcard/$A /sdcard/$B" >/dev/null 2>&1 || true
deckctl fs mkdir "$A" > "$WORK/mkdir-a.json" 2> "$WORK/mkdir-a.err" \
    && ok "mkdir made the first test folder" || bad "mkdir A failed: $(tail -1 "$WORK/mkdir-a.err")"
deckctl fs mkdir "$B" > "$WORK/mkdir-b.json" 2> "$WORK/mkdir-b.err" \
    && ok "mkdir made the second test folder" || bad "mkdir B failed: $(tail -1 "$WORK/mkdir-b.err")"
emu shell "echo one > /sdcard/$A/one.txt; echo two > /sdcard/$A/two.txt; \
    mkdir -p /sdcard/$A/sub; echo bee > /sdcard/$B/bee.txt; \
    echo gone > /sdcard/$A/.trashed-1; echo staged > /sdcard/$A/.pending-2; \
    echo deep > /sdcard/$A/sub/.trashed-3" >/dev/null 2>&1
TRANSIENTS="$(emu shell "ls -a /sdcard/$A /sdcard/$A/sub" 2>/dev/null | grep -c -e '\.trashed-' -e '\.pending-')"
[ "${TRANSIENTS:-0}" -ge 3 ] && ok "3 transient names exist on the phone's disk" \
    || bad "the transient fixtures are not on disk (${TRANSIENTS:-0})"

# --- the digest: stable, sensitive to an add, blind to transient names ------
deckctl fs digest --paths "$A" "$B" > "$WORK/digest-1.json" 2> "$WORK/digest-1.err" \
    || bad "fs.digest failed: $(tail -1 "$WORK/digest-1.err")"
deckctl fs digest --paths "$A" "$B" > "$WORK/digest-2.json" 2> "$WORK/digest-2.err" \
    || bad "fs.digest (second call) failed: $(tail -1 "$WORK/digest-2.err")"
emu shell "echo three > /sdcard/$A/three.txt" >/dev/null 2>&1
deckctl fs digest --paths "$A" "$B" > "$WORK/digest-3.json" 2> "$WORK/digest-3.err" \
    || bad "fs.digest (after the add) failed: $(tail -1 "$WORK/digest-3.err")"
deckctl fs digest --paths "$A/one.txt" > "$WORK/digest-file.json" 2> "$WORK/digest-file.err" \
    || bad "fs.digest of a file failed: $(tail -1 "$WORK/digest-file.err")"
deckctl fs list "$A" > "$WORK/list-a.json" 2> "$WORK/list-a.err" \
    || bad "fs.list failed: $(tail -1 "$WORK/list-a.err")"

python3 - "$WORK" "$A" "$B" <<'PY'
import json, os, sys

work, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
passed, failed = 0, 0

def report(ok, text):
    global passed, failed
    if ok:
        passed += 1
        print("PASS " + text)
    else:
        failed += 1
        print("FAIL " + text)

def load(name):
    with open(os.path.join(work, name)) as handle:
        return json.load(handle)

def short(value):
    return (value or "")[:12]

def is_digest(value):
    return isinstance(value, str) and len(value) == 32 \
        and all(c in "0123456789abcdef" for c in value)

one, two, three = load("digest-1.json"), load("digest-2.json"), load("digest-3.json")
report(is_digest(one.get(a)) and is_digest(one.get(b)),
       "fs.digest answers a 32-hex digest for two folders (%s..., %s...)"
       % (short(one.get(a)), short(one.get(b))))
report(one.get(a) == two.get(a) and one.get(b) == two.get(b),
       "the digest is stable across two calls")
report(three.get(a) != one.get(a),
       "the digest moved after an add (%s... -> %s...)"
       % (short(one.get(a)), short(three.get(a))))
report(three.get(b) == one.get(b),
       "an unchanged folder keeps its digest (%s...)" % short(one.get(b)))

file_reply = load("digest-file.json")
report(file_reply.get(a + "/one.txt") == "not_found",
       "a path that is not a folder answers not_found")

names = [item.get("name") for item in load("list-a.json")]
report(len(names) == 4 and all(not name.startswith(".trashed-")
                               and not name.startswith(".pending-")
                               for name in names),
       "fs.list leaves the transient names out at depth 1 (%d items)" % len(names))

with open(os.path.join(work, "counts.txt"), "w") as handle:
    handle.write("%d %d\n" % (passed, failed))
PY

COUNTS="$(cat "$WORK/counts.txt" 2>/dev/null)"
if [ -n "$COUNTS" ]; then
    PASS=$((PASS + $(printf '%s' "$COUNTS" | cut -d' ' -f1)))
    FAIL=$((FAIL + $(printf '%s' "$COUNTS" | cut -d' ' -f2)))
else
    bad "the digest assertions did not run"
fi

# --- cleanup ----------------------------------------------------------------
for folder in "$A" "$B"; do
    deckctl fs delete "$folder" --recursive > "$WORK/delete.json" 2> "$WORK/delete.err" \
        || bad "fs.delete failed: $(tail -1 "$WORK/delete.err")"
    emu shell "rm -rf /sdcard/$folder" >/dev/null 2>&1 || true
done
ok "the test folders are gone"

capture_crash final

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
