#!/usr/bin/env bash
# Shell-UID comparison of the two thumbnail sources (measurement only; this
# never touches the product): ThumbnailUtils.createImageThumbnail, which
# AndroidThumbSource uses today, against MediaStore's cached thumbnail
# (ContentResolver.loadThumbnail), for the same camera-sized JPEGs.
#
#   tools/emulator/start.sh            # or let this script boot the AVD
#   bash tools/emulator/mediathumb.sh
#
# Pushes 200 generated 4032x3024 JPEGs, scans them, then runs Spike.java as
# app_process at UID 2000 and prints p50/p95 for both APIs (cold and warm),
# whether shell UID may use MediaStore at all, and the legacy thumbnail table's
# row delta around the cold pass. Fixture names only; the program prints no
# name or path.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

WORK="$AGENT_DIR/mediathumb"
FOLDER="DCIM/Camera"
PREFIX="pd-spike"
COUNT="${CONTIGUA_SPIKE_COUNT:-200}"
SIZE="${CONTIGUA_SPIKE_SIZE:-512}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
mkdir -p "$WORK"

build_dex() {
    docker info >/dev/null 2>&1 || orb start >/dev/null
    rm -rf "$WORK/dex"
    mkdir -p "$WORK/dex"
    docker run --rm --platform linux/amd64 -v pd-android-sdk-linux:/sdk \
        -v "$EMU_DIR/mediathumb:/src:ro" -v "$WORK/dex:/out" eclipse-temurin:17-jdk bash -c '
set -e
javac -source 11 -target 11 -classpath /sdk/platforms/android-36/android.jar \
    -d /tmp/classes /src/Spike.java
mkdir -p /tmp/dex
/sdk/build-tools/36.0.0/d8 --release --min-api 30 \
    --lib /sdk/platforms/android-36/android.jar \
    --output /tmp/dex /tmp/classes/pdspike/Spike.class
cp /tmp/dex/classes.dex /out/classes.dex
'
}

if [ "$CHECK" = 1 ]; then
    # Rehearsal: the same paths and tools with no device and no boot.
    [ -x "$ADB" ] || die "no adb at $ADB"
    [ -x "$EMULATOR" ] || die "no emulator at $EMULATOR"
    "$EMULATOR" -list-avds 2>/dev/null | grep -qx "$AVD_NAME" || die "no AVD $AVD_NAME"
    command -v ffmpeg >/dev/null || die "no ffmpeg"
    build_dex || die "the dex build failed"
    [ -s "$WORK/dex/classes.dex" ] || die "the dex build produced nothing"
    step "rehearsal ok: avd=$AVD_NAME serial=$SERIAL files=$COUNT size=$SIZE dex=$(wc -c < "$WORK/dex/classes.dex" | tr -d ' ') bytes"
    exit 0
fi

if ! device_present; then
    step "starting $AVD_NAME on 5554 (headless)"
    # shellcheck disable=SC2086
    nohup "$EMULATOR" -avd "$AVD_NAME" -port 5554 -memory 2048 -cores 2 -no-audio \
        -no-boot-anim -no-snapshot -no-metrics -netdelay none -netspeed full \
        -no-window -gpu swiftshader_indirect > "$WORK/emulator.log" 2>&1 &
    wait_for_device 300 || die "emulator $SERIAL did not appear (see $WORK/emulator.log)"
fi
deadline=$(( $(date +%s) + 420 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(emu shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 3
done
[ "$(emu shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
    || die "emulator did not finish booting (see $WORK/emulator.log)"
step "booted: Android $(emu shell getprop ro.build.version.release | tr -d '\r') (api $(emu shell getprop ro.build.version.sdk | tr -d '\r'))"
# A rig PIN keeps /sdcard (FBE) mounted as a stub until the test user is
# unlocked; `test -d` passes on the stub, so prove a write. The 19:59 and 21:09
# boots both passed a directory test and then every create answered EPERM.
storage_writable() {
    emu shell 'echo pd > /sdcard/DCIM/.pd-write-probe && rm -f /sdcard/DCIM/.pd-write-probe' \
        >/dev/null 2>&1
}
if ! storage_writable; then
    step "storage is not writable yet; unlocking the test user"
    bash "$EMU_DIR/unlock.sh" > "$WORK/unlock.log" 2>&1 || tail -3 "$WORK/unlock.log"
    for _ in $(seq 1 30); do
        storage_writable && break
        sleep 2
    done
fi
ROOTED=0
if ! storage_writable; then
    # A userdebug emulator can write as root; this is measurement-only tooling
    # and the spike still runs at shell UID because we unroot before it.
    step "shell cannot write /sdcard; pushing as root only"
    emu root > "$WORK/root.log" 2>&1 || true
    emu wait-for-device >/dev/null 2>&1 || true
    sleep 3
    storage_writable || die "/sdcard is not writable at shell or root UID; see $WORK/unlock.log and $WORK/root.log"
    ROOTED=1
fi

command -v ffmpeg >/dev/null || die "ffmpeg is needed to make the fixtures"
step "fixtures: $COUNT generated 4032x3024 JPEGs"
rm -rf "$WORK/push"
mkdir -p "$WORK/push"
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=4032x3024:rate=1" \
    -frames:v 1 -q:v 5 "$WORK/$PREFIX-base.jpg" >/dev/null 2>&1 \
    || die "could not make the fixture"
i=0
while [ "$i" -lt "$COUNT" ]; do
    i=$((i + 1))
    cp "$WORK/$PREFIX-base.jpg" "$WORK/push/$(printf '%s-%04d.jpg' "$PREFIX" "$i")"
done
emu shell mkdir -p "/sdcard/$FOLDER" >/dev/null 2>&1 || true
step "pushing $COUNT files to /data/local/tmp in one pass"
emu shell rm -rf /data/local/tmp/pdspike-push >/dev/null 2>&1 || true
if ! emu push "$WORK/push" /data/local/tmp/pdspike-push > "$WORK/push.log" 2>&1; then
    tail -3 "$WORK/push.log"
    die "could not push the fixtures to /data/local/tmp (see $WORK/push.log)"
fi
# One `cp` per file through the FUSE mount: a directory push creates its own
# entries and the first FUSE refusal stops the whole batch midway (21:09).
step "copying them into /sdcard/$FOLDER"
copied="$(emu shell "mkdir -p /sdcard/$FOLDER; n=0; for f in /data/local/tmp/pdspike-push/*.jpg; do cp \"\$f\" /sdcard/$FOLDER/ || exit 1; n=\$((n+1)); done; echo \$n" \
    2>> "$WORK/push.log" | tr -d '\r')"
if [ "${copied:-0}" != "$COUNT" ]; then
    tail -3 "$WORK/push.log"
    die "copied ${copied:-0} of $COUNT fixtures (see $WORK/push.log)"
fi
emu shell rm -rf /data/local/tmp/pdspike-push >/dev/null 2>&1 || true
if [ "$ROOTED" = 1 ]; then
    emu unroot >/dev/null 2>&1 || true
    emu wait-for-device >/dev/null 2>&1 || true
    sleep 3
    step "unrooted before the measurement"
fi
step "scanning them into MediaStore"
emu shell "for f in /sdcard/$FOLDER/$PREFIX-*.jpg; do am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \"file://\$f\" >/dev/null 2>&1; done" >/dev/null 2>&1 || true
sleep 3

step "building the shell-UID spike dex in Docker (no host JVM)"
build_dex || die "could not build the spike dex"
emu push "$WORK/dex/classes.dex" /data/local/tmp/pdspike.dex >/dev/null 2>&1 \
    || die "could not push the spike dex"

step "running as uid $(emu shell id -u | tr -d '\r')"
emu shell "CLASSPATH=/data/local/tmp/pdspike.dex app_process /system/bin pdspike.Spike /sdcard/$FOLDER $SIZE" \
    2>&1 | tee "$WORK/spike.txt"

step "results"
for tag in RESOLVER MEDIA_QUERY MEDIA_ROWS LOAD_THUMB THUMB_TABLE THUMB_ROWS_BEFORE THUMB_ROWS_AFTER \
           TODAY_FAIL today_cold today_warm mediastore_cold mediastore_warm MEDIASTORE; do
    grep -E "^$tag" "$WORK/spike.txt" || true
done

emu shell rm -f "/sdcard/$FOLDER/$PREFIX-*.jpg" >/dev/null 2>&1 || true
emu shell rm -f /data/local/tmp/pdspike.dex >/dev/null 2>&1 || true
rm -rf "$WORK/push"
printf 'MEDIATHUMB done\n'
