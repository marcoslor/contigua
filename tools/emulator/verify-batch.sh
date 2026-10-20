#!/usr/bin/env bash
# The combined device verification: ONE boot, three independent sections.
#
#   bash tools/emulator/verify-batch.sh            the run (heavy.sh owns the
#                                                  lock and the boot budget; boot
#                                                  + checks + kill are one call)
#   bash tools/emulator/verify-batch.sh --check    the rehearsal: preflight plus
#                                                  every section's dry run. No
#                                                  device is touched, so this is
#                                                  the exact command to try with
#                                                  --check before the boot.
#
# start.sh (hardened) -> pair -> media -> phone-screen -> icons. A section that
# fails records its evidence and the next one still runs: one boot answers all
# three questions. The emulator is killed at the end, whatever happened.
#
# Results: one `SECTION <name> PASS|FAIL <key numbers>` line per section, in
# .agent/emu/verify-batch.log, with one full log per section beside it. Icon
# layer PNGs go to .agent/rig-verify/icons/ (never committed). Only counts,
# sizes, states and timings are logged — never a track, an artist or an icon's
# pixels in text.
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "verify-batch.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47982}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
LOG="$OUT/verify-batch.log"
ICONS="$REPO_ROOT/.agent/rig-verify/icons"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")
FAILED=0

# One SECTION line on the console and in the log, the shape the brief asks for.
section() { # section <name> PASS|FAIL <detail...>
  local line="SECTION $*"
  printf '%s\n' "$line" | tee -a "$LOG"
  [ "$2" = "PASS" ] || FAILED=1
}

# --- the icon section -------------------------------------------------------
# Host-side parsing of deckctl's own output, so it runs the same against the
# emulator and against fakephone (the --check rehearsal).
icons_section() { # icons_section <port> <state> <outdir> <layers-dir> <log>
  local port="$1" state="$2" outdir="$3" layers_dir="$4" log="$5"
  local dc
  # The --check rehearsal runs this against a stub that drives fakephone's own
  # icon renderer (fakephone's TLS needs pyOpenSSL, which the host may lack);
  # everywhere else it is the real deckctl.
  if [ -n "${POCKETDECK_DECKCTL_STUB:-}" ]; then
    dc=("$POCKETDECK_DECKCTL_STUB" --host 127.0.0.1 --port "$port" --state "$state")
  else
    dc=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$port" --state "$state")
  fi
  local apps pkg px line rc=0 count=0 layered=0 max_ms=0
  local flat want fg bg files=0
  : > "$log"
  mkdir -p "$layers_dir"

  apps="$("${dc[@]}" apps 2>>"$log" |
    awk -F'\t' '$1 ~ /^com\.(android|google\.android)\./ { print $1 }' | head -3)"
  count="$(printf '%s\n' "$apps" | grep -c . || true)"
  echo "icons: $count system apps from deckctl apps" >> "$log"
  if [ "$count" -lt 3 ]; then
    echo "apps=$count (need 3)"
    return 1
  fi

  for pkg in $apps; do
    for px in 216 1296; do
      local -a args=(icon "$pkg" --px "$px" --out "$outdir/icon-$pkg-$px.png")
      [ "$px" -eq 1296 ] && args+=(--layers-dir "$layers_dir")
      if ! line="$("${dc[@]}" "${args[@]}" 2>>"$log")"; then
        echo "icons: apps.icon $pkg px=$px failed" >> "$log"
        rc=1
        continue
      fi
      echo "$line" >> "$log"
      flat="$(printf '%s' "$line" | sed -n 's/.* png=\([0-9][0-9]*\)px.*/\1/p')"
      want=$((px * 2 / 3))
      [ "$flat" = "$want" ] || { echo "icons: $pkg px=$px flat ${flat:-none}px, expected $want" >> "$log"; rc=1; }
      case "$line" in
        *total_ms=*) ;;
        *) echo "icons: $pkg px=$px has no total_ms" >> "$log"; rc=1 ;;
      esac
      max_ms="$(printf '%s' "$line" | sed -n 's/.*total_ms=\([0-9][0-9]*\).*/\1/p' |
        awk -v m="$max_ms" '{ print ($1 > m) ? $1 : m }')"
      if [ "$px" -eq 1296 ]; then
        fg="$(printf '%s' "$line" | sed -n 's/.*fg=\([0-9][0-9]*\)px.*/\1/p')"
        bg="$(printf '%s' "$line" | sed -n 's/.*bg=\([0-9][0-9]*\)px.*/\1/p')"
        if [ -n "$fg" ] && [ -n "$bg" ]; then
          layered=$((layered + 1))
          [ "$fg" = "1296" ] && [ "$bg" = "1296" ] ||
            { echo "icons: $pkg px=1296 layers fg=$fg bg=$bg (expected 1296)" >> "$log"; rc=1; }
        fi
      fi
    done
  done

  files="$(ls "$layers_dir"/*.png 2>/dev/null | wc -l | tr -d ' ')"
  # Most system icons are adaptive; a flat one has no layers, so at least one of
  # the three must prove the 1296 fg/bg path.
  [ "$layered" -ge 1 ] || { echo "icons: no adaptive icon among the three (no fg/bg layers)" >> "$log"; rc=1; }
  echo "apps=$count px=216,1296 flat=144,864 layers=$layered/3 max_ms=$max_ms layer_pngs=$files"
  return "$rc"
}


# --- --check: the rehearsal of the exact boot command ----------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  bash tools/emulator/preflight.sh || { echo "CHECK FAIL: preflight"; exit 1; }
  bash tools/emulator/media.sh --check || { echo "CHECK FAIL: media --check"; exit 1; }
  bash tools/emulator/phone-screen.sh --check || { echo "CHECK FAIL: phone-screen --check"; exit 1; }
  bash tools/emulator/start.sh --help >/dev/null || { echo "CHECK FAIL: start.sh --help"; exit 1; }
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
    echo "CHECK FAIL: $SERIAL is already running (not ours to touch)"
    exit 1
  fi

  # The icon section needs an apps.list and an icon renderer. fakephone's
  # protocol server needs pyOpenSSL (which this Mac may not have), but its icon
  # renderer is plain Python, so the rehearsal drives the real parser through a
  # stub that calls the same renderer.
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pd-icons-check.XXXXXX")"
  cat > "$WORK/deckctl-stub.py" <<'PY'
#!/usr/bin/env python3
"""The icon subset of deckctl, rendered by fakephone's own icon code (no TLS)."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.environ["PD_REPO"], "tools", "fakephone"))
import fakephone  # noqa: E402

APPS = ["com.android.settings", "com.android.chrome", "com.android.camera2"]
args = sys.argv[1:]
if "apps" in args:
    for pkg in APPS:
        print("%s\t%s" % (pkg, pkg.rsplit(".", 1)[-1]))
    print("# %d apps" % len(APPS))
    sys.exit(0)
i = args.index("icon")
pkg = args[i + 1]
rest = args[i + 2:]
px = out = layers_dir = None
k = 0
while k < len(rest):
    if rest[k] == "--px":
        px = int(rest[k + 1]); k += 2
    elif rest[k] == "--out":
        out = rest[k + 1]; k += 2
    elif rest[k] == "--layers-dir":
        layers_dir = rest[k + 1]; k += 2
    else:
        k += 1
started = time.time()
layer = fakephone.FakePhone.layer_size(px)
flat = 96 if px is None else layer * 2 // 3
png = fakephone.render_text_png(pkg.rsplit(".", 1)[-1][:1], flat, flat,
                                (255, 255, 255), fakephone.pkg_color(pkg))
with open(out, "wb") as fp:
    fp.write(png)
fields = []
if fakephone.is_adaptive_pkg(pkg):
    layers = {
        "fg": fakephone.render_disc_png(layer, (51, 144, 236, 255)),
        "bg": fakephone.render_text_png("", layer, layer, (255, 255, 255), (255, 255, 255)),
    }
    for name, data in layers.items():
        fields.append("%s=%dpx/%dB" % (name, layer, len(data)))
        if layers_dir:
            os.makedirs(layers_dir, exist_ok=True)
            with open(os.path.join(layers_dir, "%s-%s.png" % (pkg, name)), "wb") as fp:
                fp.write(data)
print("icon %s px=%s png=%dpx/%dB %s total_ms=%d -> %s"
      % (pkg, px if px is not None else "default", flat, len(png),
         " ".join(fields) if fields else "flat",
         int((time.time() - started) * 1000), out))
PY
  chmod +x "$WORK/deckctl-stub.py"
  DETAIL="$(PD_REPO="$REPO_ROOT" POCKETDECK_DECKCTL_STUB="$WORK/deckctl-stub.py" \
    icons_section 0 "$WORK/state.json" "$WORK" "$WORK/layers" "$WORK/icons.log")"
  ICONS_RC=$?
  if [ "$ICONS_RC" -ne 0 ]; then
    echo "CHECK FAIL: icon dry run: $DETAIL (see $WORK/icons.log)"
    tail -5 "$WORK/icons.log"
    rm -rf "$WORK"
    exit 1
  fi
  echo "CHECK OK: icon dry run (fakephone's renderer, deckctl's output shape): $DETAIL"
  rm -rf "$WORK"
  echo "CHECK OK: preflight + media and phone-screen dry runs + start.sh; $SERIAL free"
  exit 0
fi

# --- the run (ONE boot) -----------------------------------------------------
if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "verify-batch: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap 'kill_emulator' EXIT

{
  echo "=== verify-batch started $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
} > "$LOG"

echo "verify-batch: booting $SERIAL (one boot budget)"
if ! bash tools/emulator/start.sh --no-build > "$OUT/verify-batch-start.log" 2>&1; then
  tail -5 "$OUT/verify-batch-start.log" | tee -a "$LOG"
  section boot FAIL "start.sh failed (see $OUT/verify-batch-start.log)"
  kill_emulator
  exit 1
fi
tail -4 "$OUT/verify-batch-start.log" | sed 's/^/  /' | tee -a "$LOG"

# --- pair once; the sections open their own sessions ------------------------
if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
      --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
      > "$OUT/verify-batch-pair.log" 2>&1; then
  tail -5 "$OUT/verify-batch-pair.log" | tee -a "$LOG"
  section pair FAIL "poc.py pair failed (see $OUT/verify-batch-pair.log)"
  kill_emulator
  exit 1
fi
section pair PASS "v2 handshake + Allow"

# --- media ------------------------------------------------------------------
echo "verify-batch: media"
if bash tools/emulator/media.sh --no-boot > "$OUT/verify-batch-media.log" 2>&1; then
  section media PASS "$(grep -c '^PASS media:' "$OUT/verify-batch-media.log") checks: $(grep '^sessions:' "$OUT/media.log" 2>/dev/null | tail -1 | cut -c1-60) $(grep '^art:' "$OUT/media.log" 2>/dev/null | tail -1 | cut -c1-46)"
else
  section media FAIL "$(grep -c '^FAIL media:' "$OUT/verify-batch-media.log") checks (see $OUT/verify-batch-media.log)"
fi

# --- phone-screen -----------------------------------------------------------
echo "verify-batch: phone-screen"
if bash tools/emulator/phone-screen.sh --no-boot > "$OUT/verify-batch-phone-screen.log" 2>&1; then
  section phone-screen PASS "$(grep -c '^PASS phone-screen:' "$OUT/verify-batch-phone-screen.log") checks: $(grep '^screen-off:' "$OUT/phone-screen.log" 2>/dev/null | tail -1 | cut -c1-40) $(grep '^power:' "$OUT/phone-screen.log" 2>/dev/null | tail -1 | cut -c1-60)"
else
  section phone-screen FAIL "$(grep -c '^FAIL phone-screen:' "$OUT/verify-batch-phone-screen.log") checks (see $OUT/verify-batch-phone-screen.log)"
fi

# --- icons ------------------------------------------------------------------
echo "verify-batch: icons"
DETAIL="$(icons_section "$PORT" "$CACHE_DIR/deckctl-state.json" "$OUT" "$ICONS" "$OUT/verify-batch-icons.log")"
ICONS_RC=$?
section icons "$([ "$ICONS_RC" -eq 0 ] && echo PASS || echo FAIL)" "$DETAIL"

kill_emulator
echo
PASSED="$(grep -cE '^SECTION (media|phone-screen|icons) PASS' "$LOG")"
echo "verify-batch: done — $PASSED of 3 sections passed; log $LOG"
exit "$FAILED"
