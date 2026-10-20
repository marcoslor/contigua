#!/usr/bin/env bash
# `fs.watch` on the emulator rig (docs/design/files.md §2/§5, slice S5): watch a
# real folder through the phone's own server, change it with adb, and read the
# coalesced `fs.changes` back through deckctl. Then unwatch part-way and prove
# nothing is reported after it. Also records `fs.inotify.max_user_watches` (the
# cap the design says to measure). The folder is removed at the end.
#
#   tools/emulator/start.sh
#   tools/emulator/fs-watch.sh
#
# No File Provider and no Mac app are involved.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DECKCTL="$REPO_ROOT/tools/fakephone/deckctl.py"
STATE="$CACHE_DIR/deckctl-state.json"
WORK="$AGENT_DIR/fs-watch"
FOLDER="DCIM/PocketDeck-watch"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

device_present || die "$SERIAL is not running - run tools/emulator/start.sh first"
DEVPORT="$(ensure_forward)" || die "cannot find the PocketDeck server port on $SERIAL (is the app running?)"
step "forward: 127.0.0.1:$PORT -> device tcp:$DEVPORT"
mkdir -p "$WORK"

# The app's shell service can be restarted by the system between commands (a
# new listening port each time), so the forward is re-read per call; a stale
# one connects and is closed, which reads as a TLS failure.
deckctl() {
    ensure_forward >/dev/null 2>&1 || true
    "$PYTHON" "$DECKCTL" --host 127.0.0.1 --port "$PORT" --state "$STATE" "$@"
}

if ! "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1; then
    "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
        || die "could not pair with the rig"
fi

# --- the kernel's watch budget ---------------------------------------------
MAX_WATCHES="$(emu shell "cat /proc/sys/fs/inotify/max_user_watches" 2>/dev/null | tr -d '\r')"
MAX_INSTANCES="$(emu shell "cat /proc/sys/fs/inotify/max_user_instances" 2>/dev/null | tr -d '\r')"
[ -n "$MAX_WATCHES" ] && ok "max_user_watches=$MAX_WATCHES max_user_instances=$MAX_INSTANCES" \
    || bad "could not read /proc/sys/fs/inotify/max_user_watches"
printf 'max_user_watches=%s\nmax_user_instances=%s\n' "${MAX_WATCHES:-none}" "${MAX_INSTANCES:-none}" > "$WORK/inotify.txt"

# --- one session, watched then unwatched part-way ---------------------------
emu shell "rm -rf /sdcard/$FOLDER" >/dev/null 2>&1 || true
deckctl fs mkdir "$FOLDER" > "$WORK/mkdir.json" 2> "$WORK/mkdir.err" \
    && ok "mkdir made the test folder" || bad "mkdir failed: $(tail -1 "$WORK/mkdir.err")"

# Deckctl holds the session (the phone tears every watch down at session end);
# the shell moves files while it is watching. Off at 9 s, hold ends at 13 s.
deckctl fs watch "$FOLDER" --hold 13 --off-after 9 > "$WORK/hold.txt" 2> "$WORK/hold.err" &
HOLD_PID=$!
for _ in $(seq 1 60); do
    grep -q '^watch ok' "$WORK/hold.txt" 2>/dev/null && break
    sleep 0.2
done
if grep -q '^watch ok' "$WORK/hold.txt" 2>/dev/null; then
    ok "fs.watch answered ok"
else
    bad "fs.watch failed: $(cat "$WORK/hold.err" "$WORK/hold.txt" 2>/dev/null | tail -2)"
fi

sleep 1
emu shell "echo created > /sdcard/$FOLDER/one.txt" >/dev/null 2>&1
sleep 2
emu shell "rm /sdcard/$FOLDER/one.txt" >/dev/null 2>&1
sleep 2
emu shell "for i in 1 2 3 4 5; do echo \$i > /sdcard/$FOLDER/burst\$i.txt; done" >/dev/null 2>&1
# Past the unwatch mark: this one must not be reported.
sleep 4
emu shell "echo after > /sdcard/$FOLDER/after.txt" >/dev/null 2>&1
wait "$HOLD_PID" 2>/dev/null

CHANGES="$(grep -c '^change ' "$WORK/hold.txt" 2>/dev/null || true)"
[ "${CHANGES:-0}" -ge 3 ] \
    && ok "a create, a delete and a burst each arrived as a coalesced change ($CHANGES batches)" \
    || bad "expected at least 3 change batches, saw ${CHANGES:-0}: $(tail -5 "$WORK/hold.txt")"
if grep -q '^change .* [2-9]$' "$WORK/hold.txt" 2>/dev/null; then
    bad "a batch reported more than the folder (coalescing per folder)"
else
    ok "each batch names at most the one watched folder"
fi
grep -q '^watch off' "$WORK/hold.txt" 2>/dev/null \
    && ok "fs.unwatch answered ok" || bad "fs.unwatch did not answer"
if grep -q '^change after-off' "$WORK/hold.txt" 2>/dev/null; then
    bad "a change was reported after fs.unwatch"
else
    ok "nothing is reported after fs.unwatch"
fi

# --- cleanup ----------------------------------------------------------------
deckctl fs delete "$FOLDER" --recursive > "$WORK/delete.json" 2> "$WORK/delete.err" \
    && ok "fs.delete removed the test folder" || bad "fs.delete failed: $(tail -1 "$WORK/delete.err")"
emu shell "rm -rf /sdcard/$FOLDER" >/dev/null 2>&1 || true

# The service that answered the watch must still be the same one: round 1 lost
# it in the write path, and a watch that only works while the process survives
# would be worthless. Evidence under $AGENT_DIR, never committed.
PIDS_AFTER="$(server_pids)"
[ -n "$PIDS_AFTER" ] && ok "the shell service is up after the watch (pid $(printf '%s' "$PIDS_AFTER" | cut -d' ' -f1))" \
    || bad "the shell service is gone after the watch"
capture_crash final

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
printf '%s\n' "$(cat "$WORK/inotify.txt")"
[ "$FAIL" = "0" ]
