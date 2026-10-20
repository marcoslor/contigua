#!/usr/bin/env bash
# The write path against the real phone server on the emulator rig (docs/design/
# files.md §6, S4): write a JPEG into DCIM, check the bytes and that MediaStore
# saw it, rename it and record what happens to the row, delete it, and prove a
# write into Android/data is refused. The folder is removed at the end.
#
#   tools/emulator/start.sh
#   tools/emulator/fs-write.sh
#
# Everything goes through deckctl's `fs` (the phone's own protocol) and adb's
# `content`/`sha256sum`; no File Provider and no Mac app are involved.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DECKCTL="$REPO_ROOT/tools/fakephone/deckctl.py"
STATE="$CACHE_DIR/deckctl-state.json"
WORK="$AGENT_DIR/fs-write"
FOLDER="DCIM/PocketDeck-test"
NAME="pd-test.jpg"
RENAMED="pd-test-renamed.jpg"
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

# Pair if the rig has no key yet (the flow the POC check uses).
if ! "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1; then
    "$EMU_DIR/unlock.sh" || true
    "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
        || die "could not pair with the rig"
fi

# A small but real JPEG: MediaStore classifies it by its magic bytes. ffmpeg is
# a rig requirement (tools/emulator/README.md).
command -v ffmpeg >/dev/null || die "ffmpeg is needed to make the test JPEG"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=8x8 -frames:v 1 \
    -q:v 5 "$WORK/$NAME" >/dev/null 2>&1 || die "could not make the test JPEG"
WANT_SHA="$(shasum -a 256 "$WORK/$NAME" | cut -d' ' -f1)"

# --- mkdir + write ----------------------------------------------------------
if deckctl fs mkdir "$FOLDER" > "$WORK/mkdir.json" 2> "$WORK/mkdir.err"; then
    ok "mkdir made $FOLDER"
else
    bad "mkdir failed: $(tail -1 "$WORK/mkdir.err")"
fi

if deckctl fs write "$FOLDER/$NAME" "$WORK/$NAME" > "$WORK/write.json" 2> "$WORK/write.err"; then
    ok "fs.write answered ok"
else
    bad "fs.write failed: $(tail -1 "$WORK/write.err")"
fi

GOT_SHA="$(emu shell "sha256sum /sdcard/$FOLDER/$NAME" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)"
[ -n "$GOT_SHA" ] && [ "$GOT_SHA" = "$WANT_SHA" ] \
    && ok "the phone's file has the Mac's sha256 ($WANT_SHA..." \
    || bad "the phone's bytes differ (want $WANT_SHA got ${GOT_SHA:-none})"

STAGING="$(emu shell "ls -a /sdcard/$FOLDER" 2>/dev/null | tr -d '\r' | grep -c '^\.pocketdeck-')"
[ "$STAGING" = "0" ] && ok "no staging file left in the folder" || bad "a staging file is left"

# --- MediaStore -------------------------------------------------------------
query_name() {
    emu shell "content query --uri content://media/external/images/media \
--projection _id:_display_name:relative_path --where \"_display_name='$1'\"" 2>/dev/null \
        | tr -d '\r'
}

ROW=""
for _ in $(seq 1 20); do
    ROW="$(query_name "$NAME")"
    printf '%s' "$ROW" | grep -q "_id=" && break
    sleep 0.5
done
if printf '%s' "$ROW" | grep -q "_id="; then
    ROW_ID="$(printf '%s' "$ROW" | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)"
    ok "MediaStore lists the new photo (row _id=$ROW_ID)"
else
    ROW_ID=""
    bad "MediaStore has no row for the new photo: $ROW"
fi

# --- rename -----------------------------------------------------------------
if deckctl fs move "$FOLDER/$NAME" "$FOLDER/$RENAMED" > "$WORK/move.json" 2> "$WORK/move.err"; then
    ok "fs.move renamed the file"
else
    bad "fs.move failed: $(tail -1 "$WORK/move.err")"
fi

OLD_ROW="$(query_name "$NAME")"
NEW_ROW="$(query_name "$RENAMED")"
printf '%s' "$OLD_ROW" | grep -q "_id=" \
    && bad "the old display name still has a row" \
    || ok "the old display name has no row any more"
NEW_ID="$(printf '%s' "$NEW_ROW" | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)"
if printf '%s' "$NEW_ROW" | grep -q "_id="; then
    if [ -n "$ROW_ID" ] && [ "$NEW_ID" = "$ROW_ID" ]; then
        ok "the row follows the rename with the same _id ($NEW_ID)"
    else
        ok "the row follows the rename with a new _id ($NEW_ID, was ${ROW_ID:-none})"
    fi
else
    bad "MediaStore has no row for the renamed file: $NEW_ROW"
fi
RECORDED="rename: old _id=${ROW_ID:-none}, new _id=${NEW_ID:-none}"
printf '%s\n' "$RECORDED" > "$WORK/rename.txt"

# --- refused path -----------------------------------------------------------
if deckctl fs write "Android/data/pd-test.txt" "$WORK/$NAME" > "$WORK/deny.json" 2> "$WORK/deny.err"; then
    bad "a write into Android/data was accepted"
else
    grep -q '"fs_denied"' "$WORK/deny.json" \
        && ok "a write into Android/data answers fs_denied" \
        || bad "a write into Android/data failed with the wrong code: $(cat "$WORK/deny.json" 2>/dev/null)"
fi

# --- delete -----------------------------------------------------------------
if deckctl fs delete "$FOLDER" --recursive > "$WORK/delete.json" 2> "$WORK/delete.err"; then
    ok "fs.delete removed the test folder"
else
    bad "fs.delete failed: $(tail -1 "$WORK/delete.err")"
fi
LEFT="$(emu shell "ls -d /sdcard/$FOLDER" 2>/dev/null | tr -d '\r')"
[ -z "$LEFT" ] && ok "the test folder is gone from the phone" || bad "the test folder is still there"

DEL_ROW="$(query_name "$RENAMED")"
printf '%s' "$DEL_ROW" | grep -q "_id=" \
    && bad "MediaStore still has the deleted file's row" \
    || ok "MediaStore dropped the deleted file's row"

emu shell "rm -rf /sdcard/$FOLDER" >/dev/null 2>&1 || true
rm -rf "$WORK"

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
printf '%s\n' "$RECORDED"
[ "$FAIL" = "0" ]
