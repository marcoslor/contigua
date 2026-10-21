#!/usr/bin/env bash
# The combined device verification: ONE boot, five independent sections.
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
# start.sh (hardened) -> pair -> paired-row -> media -> phone-screen -> secure
# -> icons. A section that fails records its evidence and the next one still
# runs: one boot answers all five questions. The emulator is killed at the end,
# whatever happened.
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
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
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


# --- the paired-Mac row -----------------------------------------------------
# One live session (deckctl authenticates and holds it) must turn the paired row
# at the top of the list into "Connected now"; after the session drops the same
# row must read "Last connected ...". uiautomator reads the Compose text the
# person sees, and uirows.py picks the row by its bounds: the dump only holds
# the rows that are drawn, so the position is the check.
ui_text() { # ui_text <dump-file> -> the dump's text nodes
  emu shell uiautomator dump --compressed "$1" >/dev/null 2>&1 || true
  emu shell cat "$1" 2>/dev/null | tr -d '\r'
}

wait_for_text() { # wait_for_text <dump-file> <grep-pattern> <timeout_s>
  local dump="$1" pattern="$2" deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ui_text "$dump" | grep -q "$pattern" && return 0
    sleep 1
  done
  return 1
}

# The paired row nearest the top of the screen, as "<y>\t<status>". Grepping
# the whole dump only finds rows it drew, so the position is what the person
# actually sees: uirows.py reads the dump's bounds.
top_row() { # top_row <dump-file>
  "$PYTHON" tools/emulator/uirows.py top "$1" 2>/dev/null || true
}

# Refreshes the dump until the topmost paired row matches <literal>. Prints
# that row (or the last one seen) and returns 0 only on a match.
wait_top_row() { # wait_top_row <dump-file> <ui-out> <literal> <timeout_s>
  local dump="$1" out="$2" want="$3" deadline=$(( $(date +%s) + $4 )) top=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ui_text "$dump" > "$out" 2>/dev/null || true
    top="$(top_row "$out")"
    [ -n "$top" ] && printf '%s\n' "$top" | grep -qF "$want" && { echo "$top"; return 0; }
    sleep 1
  done
  echo "${top:-none}"
  return 1
}

paired_row_section() { # paired_row_section <port> <state> <log>
  local port="$1" state="$2" log="$3"
  local dump=/data/local/tmp/pd-paired-row.xml watch="$log.watch" rc=0 pid top=none
  : > "$log"
  if emu shell dumpsys window 2>/dev/null | grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true'; then
    bash tools/emulator/unlock.sh >> "$log" 2>&1 || true
  fi
  emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  # The shade may be open from an earlier step: it would be the only window
  # uiautomator dumps, hiding the app's text.
  emu shell cmd statusbar collapse >/dev/null 2>&1 || true
  emu shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null 2>&1 || true
  sleep 3
  if ! wait_for_text "$dump" 'Paired Macs' 15; then
    echo "paired-row: the home screen is not on top"
    ui_text "$dump" > "$log.ui" 2>/dev/null || true
    return 1
  fi

  # A live session, without a window: `state` messages alone say it authenticated.
  PYTHONUNBUFFERED=1 "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$port" \
      --state "$state" watch-state --seconds 25 > "$watch" 2>&1 &
  pid=$!
  local deadline=$(( $(date +%s) + 15 )) live=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q ' state #' "$watch" && { live=1; break; }
    sleep 1
  done
  if [ "$live" -eq 1 ] && top="$(wait_top_row "$dump" "$log.ui" 'Connected now' 10)"; then
    echo "paired-row: the row at the top says Connected now ($top)"
  else
    echo "paired-row: the top paired row is not Connected now (session live=$live, top=$top)"
    ui_text "$dump" > "$log.ui" 2>/dev/null || true
    rc=1
  fi

  wait "$pid" 2>/dev/null || true
  if top="$(wait_top_row "$dump" "$log.ui" 'Last connected' 15)"; then
    echo "paired-row: after the session the row at the top says Last connected ($top)"
  else
    echo "paired-row: the top row after the session is not Last connected (top=$top)"
    ui_text "$dump" > "$log.ui" 2>/dev/null || true
    rc=1
  fi
  if ui_text "$dump" | grep -q 'Connected now'; then
    echo "paired-row: the row still says Connected now after the session ended"
    rc=1
  fi
  return "$rc"
}

# --- secure screens ---------------------------------------------------------
# Lock, wake, raise the rig's PIN bouncer: the phone must report state.secure
# true. Unlocking with the rig's own PIN (the same path start.sh uses) must
# report false again. The mirror is open the whole time, which is the only
# condition under which the phone polls the secure state.
secure_seen() { grep -q " secure=$2" "$1"; }

secure_section() { # secure_section <port> <state> <log>
  local port="$1" state="$2" log="$3"
  local watch="$log.watch" unlock="$log.unlock" rc=0 pid
  : > "$log"
  ensure_forward >/dev/null || { echo "secure: no server port"; return 1; }
  PYTHONUNBUFFERED=1 "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$port" \
      --state "$state" watch-state --phone --seconds 90 > "$watch" 2>&1 &
  pid=$!
  local deadline=$(( $(date +%s) + 20 )) opened=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q 'phone window opened' "$watch" && { opened=1; break; }
    sleep 1
  done
  if [ "$opened" -ne 1 ]; then
    echo "secure: no phone window ($(tail -1 "$watch" 2>/dev/null))"
    kill "$pid" >/dev/null 2>&1 || true
    return 1
  fi

  # The panel sleeps and wakes again; the bouncer goes up the way the rig raises it.
  emu shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1 || true
  sleep 2
  emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  sleep 2
  emu shell wm dismiss-keyguard >/dev/null 2>&1 || true
  for _ in $(seq 1 5); do
    emu shell input swipe 540 2000 540 700 250 >/dev/null 2>&1 || true
    sleep 1
  done

  deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ] && ! secure_seen "$watch" true; do sleep 1; done
  if secure_seen "$watch" true; then
    echo "secure: true while the bouncer is up"
  else
    echo "secure: no secure=true at the bouncer"
    rc=1
  fi

  # Exactly the rig's PIN unlock (unlock.sh): it never changes a lock setting.
  bash tools/emulator/unlock.sh > "$unlock" 2>&1 || true
  deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ] && ! secure_seen "$watch" false; do sleep 1; done
  if secure_seen "$watch" false; then
    echo "secure: false after the rig PIN unlock"
  else
    echo "secure: no secure=false after the unlock (unlock: $(tail -1 "$unlock" 2>/dev/null))"
    rc=1
  fi

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
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
  # The paired-row check reads the dump by position. Rehearse the parser on the
  # saved dump from the boot that failed (a local fixture, never committed).
  "$PYTHON" tools/emulator/uirows.py --self-test \
    || { echo "CHECK FAIL: paired-row parser self-test"; exit 1; }
  FIXTURE="$AGENT_DIR/paired-row.ui"
  if [ -f "$FIXTURE" ]; then
    ROW="$(top_row "$FIXTURE")"
    case "$ROW" in
      *"Last connected"*) echo "CHECK OK: paired-row parser on the saved dump: $ROW" ;;
      *) echo "CHECK FAIL: paired-row parser read '$ROW' from $FIXTURE"; exit 1 ;;
    esac
  else
    echo "CHECK NOTE: no $FIXTURE; the paired-row parser ran its self-test only"
  fi
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

# --- paired-row -------------------------------------------------------------
echo "verify-batch: paired-row"
if DETAIL="$(paired_row_section "$PORT" "$CACHE_DIR/deckctl-state.json" "$OUT/verify-batch-paired-row.log")"; then
  {
    echo "$DETAIL"
    echo "SECTION paired-row PASS $(printf '%s' "$DETAIL" | tr '\n' ';' | cut -c1-90)"
  } | tee -a "$LOG" >> "$OUT/hotfix-phone.log"
else
  {
    echo "$DETAIL"
    echo "SECTION paired-row FAIL $(printf '%s' "$DETAIL" | tr '\n' ';' | cut -c1-90)"
  } | tee -a "$LOG" >> "$OUT/hotfix-phone.log"
  FAILED=1
fi

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

# --- secure -----------------------------------------------------------------
echo "verify-batch: secure"
if DETAIL="$(secure_section "$PORT" "$CACHE_DIR/deckctl-state.json" "$OUT/verify-batch-secure.log")"; then
  {
    echo "$DETAIL"
    echo "SECTION secure PASS $(printf '%s' "$DETAIL" | tr '\n' ';' | cut -c1-90)"
  } | tee -a "$LOG" >> "$OUT/hotfix-phone.log"
else
  {
    echo "$DETAIL"
    echo "secure: last states $(grep ' state #' "$OUT/verify-batch-secure.log.watch" 2>/dev/null | tail -3 | tr '\n' ';' | cut -c1-160)"
    echo "SECTION secure FAIL $(printf '%s' "$DETAIL" | tr '\n' ';' | cut -c1-90)"
  } | tee -a "$LOG" >> "$OUT/hotfix-phone.log"
  FAILED=1
fi

# --- icons ------------------------------------------------------------------
echo "verify-batch: icons"
DETAIL="$(icons_section "$PORT" "$CACHE_DIR/deckctl-state.json" "$OUT" "$ICONS" "$OUT/verify-batch-icons.log")"
ICONS_RC=$?
section icons "$([ "$ICONS_RC" -eq 0 ] && echo PASS || echo FAIL)" "$DETAIL"

kill_emulator
echo
PASSED="$(grep -cE '^SECTION (paired-row|media|phone-screen|secure|icons) PASS' "$LOG")"
echo "verify-batch: done — $PASSED of 5 sections passed; log $LOG"
exit "$FAILED"
