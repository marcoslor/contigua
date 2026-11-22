#!/usr/bin/env bash
# ci-probe.sh — what this Mac can do for the e2e suite (#227). One line per
# capability, `CAP_<NAME>=yes|no <detail>`, plus `INFO` lines; exit 0 always,
# because it is a report, not a check. Built for a CI runner and safe on a
# developer's Mac: it opens one small window of its own for a few seconds,
# creates and removes one virtual display, one Keychain item of its own and one
# Bonjour registration of its own. It never moves the person's windows.
#
#   macos/scripts/ci-probe.sh
#
#   CAP_SCREENSHOT  `screencapture -l` of a window of ours comes back drawn
#   CAP_INPUT       a posted CGEvent click lands in a window of ours
#   CAP_TALL_SCREEN the main screen fits C6's tall window (952 pt visible)
#   CAP_VDISPLAY    pd-vdisplay creates the run's virtual display (quiet runs need it)
#   CAP_KEYCHAIN    a generic password round-trips without a prompt
#   CAP_BONJOUR     a dns-sd registration is browsable on this Mac
#   CAP_SECOND_UID  another local account exists (MCP's peer-uid step)
set -uo pipefail
cd "$(dirname "$0")" || exit 0
WINDOW=0
[ "${CI:-}" = "true" ] && WINDOW=1
[ "${1:-}" = "--window" ] && WINDOW=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-probe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# bounded <seconds> <cmd...> — runs cmd, killed after the bound (a prompt hangs).
bounded() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

echo "INFO $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
echo "INFO sip=$(csrutil status 2>/dev/null | sed -E 's/.*: *//; s/\.$//') console=$(stat -f%Su /dev/console 2>/dev/null) user=$(id -un)"

# The window server's three: screenshot, input, screen height.
if [ "$WINDOW" != 1 ]; then
    for c in SCREENSHOT INPUT TALL_SCREEN VDISPLAY; do echo "CAP_$c=unknown not run off CI (--window runs it)"; done
elif swiftc -O ci-probe.swift -o "$TMP/ci-probe" >"$TMP/swiftc.log" 2>&1; then
    bounded 30 "$TMP/ci-probe" || echo "INFO ci-probe exited $?"
else
    echo "INFO ci-probe.swift did not build: $(head -c 300 "$TMP/swiftc.log" | tr '\n' ' ')"
    for c in SCREENSHOT INPUT TALL_SCREEN; do echo "CAP_$c=no helper did not build"; done
fi

# The run's virtual display, exactly as check-e2e.sh starts it.
if [ "$WINDOW" != 1 ]; then
    :
elif swiftc -O pd-vdisplay.swift -o "$TMP/pd-vdisplay" >"$TMP/vd-swiftc.log" 2>&1; then
    "$TMP/pd-vdisplay" --profile ci-probe --size 1280x800 --scale 1 >"$TMP/vd.txt" 2>&1 &
    vd=$!
    for _ in $(seq 40); do grep -qE '^(id=|FAIL)' "$TMP/vd.txt" && break; sleep 0.25; done
    kill "$vd" >/dev/null 2>&1; wait "$vd" 2>/dev/null
    if grep -q '^id=' "$TMP/vd.txt"; then
        echo "CAP_VDISPLAY=yes $(grep -m1 '^id=' "$TMP/vd.txt")"
    else
        echo "CAP_VDISPLAY=no $(head -c 200 "$TMP/vd.txt" | tr '\n' ' ')"
    fi
else
    echo "CAP_VDISPLAY=no pd-vdisplay.swift did not build"
fi

# Keychain: the default keychain, as the app's pairing key uses it.
svc="app.contigua.ci-probe.$$"
if bounded 10 security add-generic-password -s "$svc" -a probe -w probe-value >/dev/null 2>&1 \
    && [ "$(bounded 10 security find-generic-password -s "$svc" -a probe -w 2>/dev/null)" = "probe-value" ]; then
    echo "CAP_KEYCHAIN=yes default=$(security default-keychain 2>/dev/null | tr -d ' "' | xargs basename 2>/dev/null)"
else
    echo "CAP_KEYCHAIN=no default=$(security default-keychain 2>/dev/null | tr -d ' "' | xargs basename 2>/dev/null)"
fi
bounded 10 security delete-generic-password -s "$svc" -a probe >/dev/null 2>&1

# Bonjour, at dns-sd's level (the app's own Local Network prompt needs the app).
type="_pd-ci-probe._tcp"
dns-sd -R "ci-probe-$$" "$type" local 49999 >/dev/null 2>&1 &
reg=$!
dns-sd -B "$type" local >"$TMP/browse.txt" 2>&1 &
browse=$!
sleep 4
kill "$reg" "$browse" >/dev/null 2>&1; wait "$reg" "$browse" 2>/dev/null
if grep -q "ci-probe-$$" "$TMP/browse.txt"; then
    echo "CAP_BONJOUR=yes"
else
    echo "CAP_BONJOUR=no browse saw $(grep -c Add "$TMP/browse.txt") adds"
fi

others="$(dscl . list /Users UniqueID 2>/dev/null | awk -v me="$(id -u)" '$2 >= 501 && $2 != me' | wc -l | tr -d ' ')"
[ "$others" -gt 0 ] && echo "CAP_SECOND_UID=yes others=$others" || echo "CAP_SECOND_UID=no others=0"
exit 0
