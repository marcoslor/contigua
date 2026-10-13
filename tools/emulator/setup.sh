#!/usr/bin/env bash
# Install the Android SDK bits for the PocketDeck emulator rig and create the
# AVD. Idempotent: re-running only fills in whatever is missing.
#
#   tools/emulator/setup.sh
#
# Env overrides: ANDROID_HOME, JAVA_HOME, POCKETDECK_AVD, POCKETDECK_API.
set -euo pipefail

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
SDKROOT="$ANDROID_HOME"
SDKMANAGER="$SDKROOT/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$SDKROOT/cmdline-tools/latest/bin/avdmanager"
AVD_NAME="${POCKETDECK_AVD:-pocketdeck-api36}"
WANT_API="${POCKETDECK_API:-36}"
DEVICE_PROFILE="${POCKETDECK_DEVICE:-}"
RAM_MB="${POCKETDECK_RAM_MB:-4096}"

export PATH="$SDKROOT/platform-tools:$SDKROOT/emulator:$PATH"

if [ ! -x "$SDKMANAGER" ]; then
  echo "setup: sdkmanager not found at $SDKMANAGER" >&2
  exit 1
fi
if [ ! -d "$JAVA_HOME" ]; then
  echo "setup: JAVA_HOME $JAVA_HOME does not exist (Android tools need JDK 17)" >&2
  exit 1
fi

# --- 1. licenses + packages -------------------------------------------------
# Accepting licenses is a no-op once accepted; keep it non-interactive.
yes 2>/dev/null | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true

installed() { # installed <path>
  "$SDKMANAGER" --list_installed 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# google_apis (never playstore): the rig needs `adb root` and a userdebug image.
pick_system_image() {
  local wanted="system-images;android-$WANT_API;google_apis;arm64-v8a"
  if "$SDKMANAGER" --list 2>/dev/null | grep -q "^[[:space:]]*$wanted"; then
    echo "$wanted"
    return
  fi
  # Newest available API level, highest first.
  "$SDKMANAGER" --list 2>/dev/null |
    sed -n 's/^[[:space:]]*\(system-images;android-\([0-9][0-9]*\);google_apis;arm64-v8a\).*/\2 \1/p' |
    sort -rn | head -1 | cut -d' ' -f2
}

SYSIMG="$(pick_system_image)"
if [ -z "$SYSIMG" ]; then
  echo "setup: no google_apis;arm64-v8a system image available from sdkmanager" >&2
  exit 1
fi

# Phone profile: the newest pixel_* the installed cmdline-tools knows about
# (older tool versions stop at pixel_7), else a generic phone.
if [ -z "$DEVICE_PROFILE" ]; then
  # Highest-numbered pixel_<N> profile; older cmdline-tools stop at pixel_7.
  DEVICE_PROFILE="$("$AVDMANAGER" list device 2>/dev/null |
    sed -n 's/.*or "pixel_\([0-9][0-9]*\)".*/\1/p' | sort -rn | head -1 |
    sed 's/^/pixel_/')"
  [ "$DEVICE_PROFILE" != "pixel_" ] || DEVICE_PROFILE=""
  [ -n "$DEVICE_PROFILE" ] || DEVICE_PROFILE="medium_phone"
fi

TO_INSTALL=()
for pkg in "emulator" "platforms;android-$WANT_API" "$SYSIMG"; do
  if installed "$pkg"; then
    echo "setup: have $pkg"
  else
    TO_INSTALL+=("$pkg")
  fi
done
if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
  echo "setup: installing ${TO_INSTALL[*]}"
  yes 2>/dev/null | "$SDKMANAGER" "${TO_INSTALL[@]}" >/dev/null
else
  echo "setup: SDK packages already installed"
fi

# --- 2. AVD ----------------------------------------------------------------
avd_exists() { "$AVDMANAGER" list avd 2>/dev/null | grep -q "Name: $AVD_NAME\$"; }

if avd_exists; then
  echo "setup: AVD $AVD_NAME exists"
else
  echo "setup: creating AVD $AVD_NAME ($DEVICE_PROFILE, $SYSIMG)"
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSIMG" -d "$DEVICE_PROFILE" --force >/dev/null
fi

# Pin the knobs the rig depends on (VDs + an encoder need the RAM; a keyboard
# makes `input text`/IME-free typing work).
CFG="${ANDROID_AVD_HOME:-$HOME/.android/avd}/$AVD_NAME.avd/config.ini"
if [ ! -f "$CFG" ]; then
  echo "setup: AVD config $CFG missing" >&2
  exit 1
fi
set_ini() { # set_ini key value
  if grep -q "^$1=" "$CFG"; then
    # BSD sed: -i takes a suffix argument.
    sed -i '' "s|^$1=.*|$1=$2|" "$CFG"
  else
    printf '%s=%s\n' "$1" "$2" >>"$CFG"
  fi
}
set_ini hw.ramSize "$RAM_MB"
set_ini vm.heapSize 512
set_ini hw.keyboard yes
set_ini disk.dataPartition.size 8192M
set_ini hw.gpu.enabled yes
set_ini hw.gpu.mode swiftshader_indirect

echo "setup: ok"
echo "setup: AVD $AVD_NAME -> $CFG"
echo "setup: serial will be emulator-5554 (see tools/emulator/start.sh)"
