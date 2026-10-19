#!/usr/bin/env bash
# vm-prepare.sh — create (or rebuild) the headless macOS VM the e2e suite runs
# in, and install everything the suite needs inside it.
#
#   macos/scripts/vm-prepare.sh            refresh the existing VM in place
#   macos/scripts/vm-prepare.sh --fresh    delete and re-clone it first
#
# The VM is named pd-e2e (PD_E2E_VM) and is a clone of
# ghcr.io/cirruslabs/macos-tahoe-base:latest (PD_E2E_BASE): 2 CPUs, 4 GB RAM,
# a 1920x1080 display, ssh on as admin/admin. Preparation is idempotent: it
# installs Homebrew's python3 and ffmpeg, the Command Line Tools (for swiftc,
# the suite compiles its small helpers in-guest), the host's dedicated ssh key,
# an auto-login console session (the checks drive a real window server) and the
# TCC grants Screen Recording needs. The VM boots and stops inside the
# machine-wide heavy lock; the whole thing is one heavy step.
set -uo pipefail
MACOS="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=vm-common.sh
. "$MACOS/scripts/vm-common.sh"

FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

[ -x "$TART" ] || { say "tart not found at $TART"; exit 3; }
mkdir -p "$VM_STATE"

if [ "$FRESH" = 1 ]; then
    vm_running && { say "$VM is running; stop it first"; exit 3; }
    if vm_exists; then
        say "deleting $VM"
        "$TART" delete "$VM" || exit 1
    fi
fi

if ! vm_exists; then
    # `tart list` lists pulled images and VMs together.
    if ! "$TART" list 2>/dev/null | grep -qF "$BASE_IMAGE"; then
        say "the base image is not pulled; run: $TART pull $BASE_IMAGE"
        exit 3
    fi
    say "cloning $BASE_IMAGE -> $VM"
    "$TART" clone "$BASE_IMAGE" "$VM" || exit 1
fi
# Idempotent: also refreshes an existing VM's sizing.
"$TART" set "$VM" --cpu 2 --memory "$VM_MEMORY" --display 1920x1080 || exit 1

if [ ! -f "$VM_KEY" ]; then
    say "generating the host->guest ssh key ($VM_KEY)"
    ssh-keygen -q -t ed25519 -N "" -C "pd-e2e host key" -f "$VM_KEY"
fi
PUBKEY="$(cat "$VM_KEY.pub")"

state="$VM_STATE/prepared"
memory_gate || exit 3
heavy_lock
trap 'vm_stop; heavy_unlock' EXIT

# A killed run can leave the VM up; it is ours, so stop it before booting.
if vm_running; then
    say "$VM was left running; stopping it"
    vm_stop
fi

memory_gate || exit 3

VM_LOG="$VM_STATE/prepare-tart-run.log"
vm_boot password || exit 3

say "installing the ssh key (first contact uses the image's admin/admin)"
vm_password_ssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '$PUBKEY' ~/.ssh/authorized_keys || echo '$PUBKEY' >> ~/.ssh/authorized_keys" \
    >/dev/null || { say "password ssh failed; is the image's admin account unchanged?"; exit 3; }
ssh_guest true || { say "ssh with the new key failed"; exit 3; }

say "preparing the guest (log: $state.log)"
ssh_guest bash -s -- "$PUBKEY" <<'EOS' 2>&1 | tee "$state.log"
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
SUDO="sudo -n"
$SUDO true 2>/dev/null || SUDO="sudo"
step() { printf '\n== %s\n' "$*"; }

step "system"
sw_vers -productVersion; uname -m
echo "command line tools: $(xcode-select -p 2>/dev/null || echo none)"
echo "SIP: $(csrutil status 2>/dev/null)"

step "console session"
# The checks drive a real window server, so an admin session must own the
# console. The images boot to loginwindow; enable auto-login once.
if [ "$(stat -f%Su /dev/console)" = "admin" ]; then
    echo "console user: admin"
else
    echo "console user: $(stat -f%Su /dev/console) -> enabling auto-login"
    if ! $SUDO sysadminctl -autologin set -userName admin -password admin 2>&1; then
        echo "sysadminctl failed; writing kcpassword by hand"
        $SUDO defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string admin
    fi
    python3 - <<'PY'
# /etc/kcpassword: the login window's obfuscated copy of the password.
key = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x12, 0x51, 0x56, 0x8D, 0xA4, 0xB1]
pw = b"admin" + b"\x00"
pw += b"\x00" * ((-len(pw)) % len(key))
open("/tmp/kcpassword", "wb").write(bytes(c ^ key[i % len(key)] for i, c in enumerate(pw)))
PY
    $SUDO cp /tmp/kcpassword /etc/kcpassword
    $SUDO chown root:wheel /etc/kcpassword
    $SUDO chmod 600 /etc/kcpassword
    rm -f /tmp/kcpassword
fi

step "TCC (SIP: $($SUDO csrutil status 2>/dev/null | sed -E 's/.*: //'))"
if $SUDO csrutil status 2>/dev/null | grep -q 'disabled'; then
    # The ssh session's responsible processes need Screen Recording
    # (`screencapture -l`, the checks' screenshots) and Accessibility (real
    # CGEvent posts in PD_E2E_VISIBLE runs). The rows are what the GUI's
    # "grant" button writes.
    db="/Library/Application Support/com.apple.TCC/TCC.db"
    for service in kTCCServiceScreenCapture kTCCServiceAccessibility; do
        for client in com.apple.sshd-keygen-wrapper /usr/libexec/sshd-keygen-wrapper /bin/bash /bin/sh /usr/bin/screencapture; do
            $SUDO sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) SELECT '$service', '$client', 0, 2, 3, 1, NULL, 0, 'UNUSED', NULL, 0, strftime('%s','now') WHERE NOT EXISTS (SELECT 1 FROM access WHERE service='$service' AND client='$client');" 2>&1
        done
    done
    echo "tcc rows: $($SUDO sqlite3 "$db" 'SELECT service||" "||client FROM access WHERE auth_value=2;' 2>&1 | tr '\n' ';')"
else
    echo "SIP enabled: cannot write the TCC database (see progress.md)"
fi

step "sleep, screensaver and lock screen off"
$SUDO pmset -a sleep 0 disksleep 0 displaysleep 0
$SUDO defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLock -bool true
defaults -currentHost write com.apple.screensaver idleTime -int 0

step "homebrew"
command -v brew >/dev/null || { echo "no Homebrew in the image"; exit 4; }
brew --version | head -1

step "python3 + ffmpeg"
brew list --formula 2>/dev/null | grep -q '^python' || brew install python || exit 4
brew list --formula 2>/dev/null | grep -q '^ffmpeg' || brew install ffmpeg || exit 4
/opt/homebrew/bin/python3 -c 'import sys, ssl; print("python", sys.version.split()[0], ssl.OPENSSL_VERSION)' || exit 4
ffmpeg -version 2>/dev/null | head -1 || exit 4

step "bash 5"
# check-e2e.sh expands a possibly-empty array under `set -u`, which system
# bash 3.2 rejects; the suite runs with a modern bash (Homebrew's).
brew list --formula 2>/dev/null | grep -q '^bash$' || brew install bash || exit 4

step "pyOpenSSL for the fakephone"
/opt/homebrew/bin/python3 -c 'import OpenSSL' 2>/dev/null \
    || /opt/homebrew/bin/python3 -m pip install --user --break-system-packages pyopenssl || exit 4
/opt/homebrew/bin/python3 -c 'import OpenSSL; print("pyOpenSSL", OpenSSL.__version__)' || exit 4

step "Command Line Tools (swiftc)"
if command -v swiftc >/dev/null 2>&1; then
    swiftc --version
else
    $SUDO touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    label="$(softwareupdate -l 2>/dev/null | grep -oE 'Command Line Tools for Xcode-[0-9.]+' | tail -1)"
    echo "installing: ${label:-not offered by softwareupdate}"
    if [ -n "$label" ]; then
        $SUDO softwareupdate -i "$label" --agree-to-license || exit 4
    fi
    $SUDO rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    command -v swiftc >/dev/null 2>&1 || { echo "swiftc still missing"; exit 4; }
fi

step "ssh key"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qF "$1" ~/.ssh/authorized_keys || echo "$1" >> ~/.ssh/authorized_keys

step "done"
echo "guest preparation steps finished"
EOS

rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { say "guest preparation failed (rc=$rc); see $state.log"; exit 3; }

# Auto-login only takes effect at the next login window; the guest prepares
# without a console session, so check the rebooted state before declaring the
# VM ready.
say "restarting the guest to apply the login/session settings"
vm_stop
vm_boot || exit 3

say "verifying the prepared VM"
ok=1
check() { # check <label> <command...>
    local label="$1" out; shift
    if out="$(ssh_guest "$@" 2>&1)"; then
        say "ok    $label: $(printf '%s' "$out" | head -1)"
    else
        say "FAIL  $label: $(printf '%s' "$out" | head -1)"
        ok=0
    fi
}
check_wait() { # check_wait <label> <seconds> <command...> — login can lag sshd
    local label="$1" secs="$2" waited=0
    shift 2
    while :; do
        if ssh_guest "$@" >/dev/null 2>&1; then
            check "$label" "$@"
            return
        fi
        if [ "$waited" -ge "$secs" ]; then
            check "$label" "$@"   # fail and print the error
            return
        fi
        sleep 5
        waited=$((waited + 5))
    done
}
check_wait "console session" 90 'test "$(stat -f%Su /dev/console)" = admin'
check "swiftc"         'PATH=/opt/homebrew/bin:/usr/bin:/bin swiftc --version | head -1'
check "ffmpeg"         'PATH=/opt/homebrew/bin:/usr/bin:/bin ffmpeg -version 2>/dev/null | head -1'
check "python TLS1.3"  '/opt/homebrew/bin/python3 -c "import ssl,sys,OpenSSL; assert sys.version_info>=(3,11) and not ssl.OPENSSL_VERSION.startswith(\"LibreSSL\"); print(sys.version.split()[0], \"pyOpenSSL\", OpenSSL.__version__)"'
check "bash 5"        '/opt/homebrew/bin/bash -c "set -u; a=(); echo \${a[@]} ok; echo \$BASH_VERSION"'
check_wait "screencapture" 30 'sudo launchctl asuser $(id -u) sudo -u admin bash -c "screencapture -x /tmp/pd-e2e-check.png" && stat -f%z /tmp/pd-e2e-check.png && PATH=/opt/homebrew/bin:/usr/bin:/bin ffmpeg -hide_banner -i /tmp/pd-e2e-check.png -vf signalstats,metadata=print -f null - 2>&1 | grep -oE "YMAX=[0-9]+" | head -1 && rm -f /tmp/pd-e2e-check.png'

[ "$ok" = 1 ] || { say "prepared VM failed verification; see $state.log"; exit 3; }

{
    say "prepared $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    guest_ver="$(ssh_guest 'sw_vers -productVersion' 2>/dev/null)"
    say "guest macOS $guest_ver"
    say "image $BASE_IMAGE"
} > "$state"
say "wrote $state"
vm_stop
say "done: $VM is prepared and stopped"
