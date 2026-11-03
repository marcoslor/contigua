#!/usr/bin/env bash
# Shell-UID comparison of the two thumbnail sources (measurement only; this
# never touches the product): ThumbnailUtils.createImageThumbnail, which
# AndroidThumbSource uses today, against MediaStore's cached thumbnail
# (ContentResolver.loadThumbnail), for the same camera-sized JPEGs.
#
#   tools/emulator/start.sh            # or let this script boot the AVD
#   ~/dev/pocketdeck/.agent/heavy.sh bash tools/emulator/mediathumb.sh
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
COUNT="${POCKETDECK_SPIKE_COUNT:-200}"
SIZE="${POCKETDECK_SPIKE_SIZE:-512}"
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
# A rig PIN keeps /sdcard (FBE) unmounted until the test user is unlocked; the
# spike only needs storage, not the app. Prove the mount before pushing.
storage_ready() { emu shell 'test -d /sdcard/DCIM' >/dev/null 2>&1; }
if ! storage_ready; then
    step "storage is not mounted yet; unlocking the test user"
    bash "$EMU_DIR/unlock.sh" > "$WORK/unlock.log" 2>&1 || tail -3 "$WORK/unlock.log"
    for _ in $(seq 1 30); do
        storage_ready && break
        sleep 2
    done
fi
storage_ready || die "/sdcard is not mounted; see $WORK/unlock.log"

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
step "pushing $COUNT files in one pass"
if ! emu push "$WORK/push/." "/sdcard/$FOLDER/" > "$WORK/push.log" 2>&1; then
    tail -3 "$WORK/push.log"
    die "could not push the fixtures (see $WORK/push.log)"
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
           today_cold today_warm mediastore_cold mediastore_warm MEDIASTORE; do
    grep -E "^$tag" "$WORK/spike.txt" || true
done

emu shell rm -f "/sdcard/$FOLDER/$PREFIX-*.jpg" >/dev/null 2>&1 || true
emu shell rm -f /data/local/tmp/pdspike.dex >/dev/null 2>&1 || true
rm -rf "$WORK/push"
printf 'MEDIATHUMB done\n'
