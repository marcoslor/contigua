#!/usr/bin/env bash
# Everything the emulator rig can check WITHOUT a device. Each script's --check
# calls this first, and verify-batch.sh --check calls it too, because a boot that
# dies on a stale APK, a typo'd component name or an implicit broadcast costs the
# whole budget.
#
#   bash tools/emulator/preflight.sh
#
# Checks:
#   1. `bash -n` on every rig script (they are always run as `bash <script>`);
#   2. adb, emulator and aapt2 are where lib.sh says;
#   3. the debug APK exists, its versionCode is readable and matches the build
#      file (a stale APK would install the wrong build);
#   4. every component the scripts name (`am start -n`, `am broadcast -n`, the
#      debug-receiver table) exists in that APK's merged manifest, and every
#      debug action the scripts broadcast is a receiver there;
#   5. deckctl imports and still has the subcommands the scripts drive;
#   6. the python can do the v2 handshake (TLS 1.3);
#   7. the boot budget for this worktree is not spent.
# Exit 0 when all of it holds. Never touches a device.
set -u

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
MAIN_REPO="$HOME/dev/pocketdeck"
FAILED=0
fail() { echo "PREFLIGHT FAIL: $*"; FAILED=1; }
ok() { echo "PREFLIGHT OK: $*"; }

# --- 1. syntax --------------------------------------------------------------
for script in tools/emulator/*.sh; do
  bash -n "$script" || fail "syntax: $script"
done
ok "bash -n on $(ls tools/emulator/*.sh | wc -l | tr -d ' ') rig scripts"

# --- 2. host tools ----------------------------------------------------------
[ -x "$ADB" ] || fail "no adb at $ADB"
[ -x "$EMULATOR" ] || fail "no emulator at $EMULATOR"
[ -x "$AAPT2" ] || fail "no aapt2 at $AAPT2"
for file in tools/emulator/start.sh tools/emulator/lib.sh tools/emulator/unlock.sh \
  tools/emulator/media.sh tools/emulator/phone-screen.sh tools/emulator/poc.py \
  tools/fakephone/deckctl.py tools/fakephone/fakephone.py; do
  [ -f "$file" ] || fail "missing $file"
done
ok "adb, emulator, aapt2 and the rig scripts are present"

# --- 3. the APK and its versionCode -----------------------------------------
if [ ! -s "$APK" ]; then
  fail "no debug APK at $APK (build it: cd android && ./gradlew :app:assembleDebug)"
else
  CODE="$(apk_version_code "$APK")"
  if [ -z "$CODE" ]; then
    fail "aapt2 cannot read the versionCode of $APK"
  else
    GRADLE_CODE="$(sed -n 's/.*versionCode = \([0-9][0-9]*\).*/\1/p' android/app/build.gradle.kts | head -1)"
    if [ -n "$GRADLE_CODE" ] && [ "$GRADLE_CODE" != "$CODE" ]; then
      fail "the APK is versionCode $CODE but android/app/build.gradle.kts is $GRADLE_CODE (stale APK)"
    else
      ok "APK versionCode $CODE"
    fi
  fi
fi

# --- 4. the components the scripts address exist in the APK's manifest ------
# Merged manifests carry fully qualified class names, so the binary manifest of
# the APK is enough and is exactly what the device will run.
manifest_names() {
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null |
    sed -n 's/.*:name(0x[0-9a-fA-F]*)="\([^"]*\)".*/\1/p' | sort -u
}

check_components() {
  local names="$1" ref refs pkg cls count=0
  # Every `pkg/Class` a script starts or broadcasts to. Scripts spell them as
  # "$PKG/.app.MainActivity" or as the literal dev.pocketdeck/... of the debug
  # receiver table, so both spellings are resolved here.
  refs="$(
    grep -hoE '(dev\.pocketdeck|moe\.shizuku\.privileged\.api)/[A-Za-z0-9_.$]+' \
      tools/emulator/lib.sh tools/emulator/start.sh tools/emulator/unlock.sh \
      tools/emulator/media.sh tools/emulator/phone-screen.sh tools/emulator/flow.sh \
      tools/emulator/lock.sh tools/emulator/poc.py tools/emulator/fs-watch.sh \
      tools/emulator/fs-write.sh 2>/dev/null
    grep -hoE '\$PKG/[A-Za-z0-9_.$]+' tools/emulator/lib.sh tools/emulator/start.sh \
      tools/emulator/media.sh tools/emulator/phone-screen.sh 2>/dev/null |
      sed 's|^\$PKG/|dev.pocketdeck/|'
  )"
  refs="$(printf '%s\n' "$refs" | sort -u | grep . || true)"
  [ -n "$refs" ] || fail "no component references found in the rig scripts (the extractor broke)"
  for ref in $refs; do
    pkg="${ref%%/*}"
    cls="${ref#*/}"
    case "$cls" in
      .*) cls="$pkg$cls" ;;
    esac
    count=$((count + 1))
    if ! printf '%s\n' "$names" | grep -qx "$cls"; then
      fail "component $pkg/$cls is named by a rig script but is not in the APK's manifest"
    fi
  done
  ok "$count components named by the scripts are in the APK's manifest"
  # The debug receivers the broadcasts target, with their actions.
  local action
  for action in dev.pocketdeck.DEBUG_MEDIA dev.pocketdeck.DEBUG_NOTIFY; do
    ref="$(debug_component "$action")" || { fail "no debug component for $action"; continue; }
    cls="${ref#*/}"
    if printf '%s\n' "$names" | grep -qx "$cls"; then
      ok "broadcast $action -> $ref (explicit component, present in the manifest)"
    else
      fail "broadcast $action targets $ref, which the APK's manifest does not declare"
    fi
  done
}

if [ -s "$APK" ] && [ -x "$AAPT2" ]; then
  NAMES="$(manifest_names)"
  if [ -z "$NAMES" ]; then
    fail "aapt2 cannot read the APK's AndroidManifest.xml"
  else
    check_components "$NAMES"
  fi
fi

# --- 5. deckctl -------------------------------------------------------------
"$PYTHON" - <<'PY' || fail "deckctl does not import or lost a subcommand the rig drives"
import sys
sys.path.insert(0, "tools/fakephone")
import deckctl  # noqa: F401
parser = deckctl.build_parser()
for argv in (["apps"], ["icon", "p", "--out", "/tmp/x.png", "--px", "216"],
             ["media", "drive", "--seconds", "1"], ["wake-test", "--off-timeout", "1"]):
    parser.parse_args(argv)
# Every subcommand needs a handler: `wake-test` parsed but was missing from
# COMMANDS, so deckctl died with a KeyError only once the emulator was up.
subs = [a for a in parser._actions if getattr(a, "choices", None) and a.dest == "command"]
missing = [name for name in sorted(subs[0].choices) if name not in deckctl.COMMANDS]
assert not missing, "subcommands without a handler: %s" % ", ".join(missing)
print("PREFLIGHT OK: deckctl imports; %d subcommands, all handled" % len(deckctl.COMMANDS))
PY
"$PYTHON" tools/fakephone/fakephone.py --help >/dev/null 2>&1 ||
  fail "fakephone.py --help"
"$PYTHON" -c 'import ssl; c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.minimum_version = ssl.TLSVersion.TLSv1_3' \
  >/dev/null 2>&1 || fail "$PYTHON cannot enforce TLS 1.3 (the v2 handshake needs it); set POCKETDECK_PYTHON"
ok "python $("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])') with TLS 1.3"

# --- 6. boot budget ---------------------------------------------------------
NAME="$(basename "$REPO_ROOT")"
BUDGET_FILE="$MAIN_REPO/.agent/budgets/$NAME"
LEDGER=/tmp/pocketdeck-boots.ledger
if [ -f "$BUDGET_FILE" ]; then
  LIMIT="$(sed -n 's/^emulator=\([0-9][0-9]*\)$/\1/p' "$BUDGET_FILE" | head -1)"
  USED="$(ledger_boots "$LEDGER" "$NAME")"
  if [ -n "$LIMIT" ]; then
    if [ "$USED" -ge "$LIMIT" ]; then
      fail "emulator budget spent for $NAME ($USED of $LIMIT boots already in $LEDGER)"
    else
      ok "emulator budget: $USED of $LIMIT used"
    fi
  fi
else
  ok "no boot budget file for $NAME (nothing to check)"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "PREFLIGHT FAIL"
  exit 1
fi
echo "PREFLIGHT PASS"
