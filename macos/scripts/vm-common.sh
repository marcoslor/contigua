#!/usr/bin/env bash
# Shared helpers for the headless-VM e2e scripts (vm-prepare.sh, vm-e2e.sh):
# tart boot/IP/ssh/rsync plumbing, the machine-wide heavy lock and the memory
# gate from .agent/RULES.md. Sourced, never run on its own.

VM="${PD_E2E_VM:-pd-e2e}"
BASE_IMAGE="${PD_E2E_BASE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
TART="${TART:-$HOME/.local/bin/tart}"
VM_USER="admin"
VM_HOME="/Users/$VM_USER"
VM_ROOT="$VM_HOME/pd-e2e"        # the worktree copy inside the guest
VM_PORT="${PD_VM_PORT:-47890}"   # the run's port inside the guest
VM_MEMORY="${PD_VM_MEMORY:-4096}"  # MB; the tahoe image rejects less than 4 GB
VM_STATE="${PD_VM_STATE:-$HOME/.tart/pd-e2e}"  # ssh key + prepared marker (host)
VM_KEY="$VM_STATE/id_ed25519"
HEAVY_LOCK="/tmp/contigua-heavy.lock"

say() { printf '%s\n' "$*"; }

# heavy_lock — RULES.md 14: every heavy step is serialized machine-wide. A
# caller that is already inside .agent/heavy.sh must not take the lock again
# (that would deadlock on itself): if the lock's holder is one of our
# ancestors, we ARE the step it is running.
heavy_held_by_ancestor() {
    local pid p=$$
    [ -f "$HEAVY_LOCK/pid" ] || return 1
    pid="$(cat "$HEAVY_LOCK/pid" 2>/dev/null)" || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    while [ "$p" -gt 1 ]; do
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        [ -n "$p" ] || return 1
        [ "$p" = "$pid" ] && return 0
    done
    return 1
}

heavy_lock() {
    if heavy_held_by_ancestor; then HEAVY_OWN=0; return 0; fi
    local holder waited=0
    while ! mkdir "$HEAVY_LOCK" 2>/dev/null; do
        holder="$(cat "$HEAVY_LOCK/pid" 2>/dev/null)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$HEAVY_LOCK"; continue; fi
        [ "$waited" = 0 ] && say "waiting for the machine-wide heavy lock (held by pid ${holder:-unknown})"
        sleep 15
        waited=$((waited + 15))
    done
    echo $$ > "$HEAVY_LOCK/pid"
    HEAVY_OWN=1
}

heavy_unlock() {
    [ "${HEAVY_OWN:-0}" = 1 ] || return 0
    [ "$(cat "$HEAVY_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$HEAVY_LOCK"
    HEAVY_OWN=0
}

# memory_gate — RULES.md 12: the 8 GB Mac was force-restarted once under load.
# Do not boot a VM unless at least 25% of memory is free and swap is under
# 2 GB. Waiting is the rule's other half: one boot moves a few hundred MB into
# swap and macOS keeps it there while nothing asks for the RAM, so back-to-back
# runs drain at ~10 MB/min. Wait up to 45 minutes and say so every 5.
memory_gate() {
    local waited=0 free swap_mb
    while :; do
        free="$(memory_pressure 2>/dev/null | tail -1 | sed -E 's/.*: ([0-9]+)%.*/\1/')"
        swap_mb="$(sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*used = ([0-9.]+)M.*/\1/' | cut -d. -f1)"
        # PD_VM_SWAP_MAX_MB / PD_VM_FREE_MIN: a supervised run may move the
        # bar (stale swap with plenty free); agents never set these.
        if [ -n "$free" ] && [ "$free" -ge "${PD_VM_FREE_MIN:-25}" ] && [ -n "$swap_mb" ] \
            && [ "$swap_mb" -lt "${PD_VM_SWAP_MAX_MB:-2048}" ]; then
            return 0
        fi
        if [ "$waited" -ge 2700 ]; then
            say "memory gate: free ${free:-?}%, swap used ${swap_mb:-?} MB after 45 min; not starting the VM"
            return 1
        fi
        if [ "$waited" = 0 ] || [ $((waited % 300)) = 0 ]; then
            say "memory gate: free ${free:-?}%, swap used ${swap_mb:-?} MB; waiting for room"
        fi
        sleep 30
        waited=$((waited + 30))
    done
}

vm_exists() { "$TART" list --quiet 2>/dev/null | grep -qx "$VM"; }

# vm_running — true while a `tart run` of this VM is alive on the host.
vm_running() { pgrep -f "$TART run $VM" >/dev/null 2>&1; }

VM_IP=""
RUN_PID=""

# vm_boot [password] — start the VM headless (no window ever touches the user's
# session) and wait for sshd. "password" waits using the image's admin/admin
# account (a fresh clone has no host key installed yet). Needs $VM_LOG.
vm_boot() {
    local probe="ssh_guest"
    [ "${1:-}" = "password" ] && probe="vm_password_ssh"
    say "booting $VM headless"
    "$TART" run "$VM" --no-graphics --no-audio >"$VM_LOG" 2>&1 &
    RUN_PID=$!
    VM_IP="$("$TART" ip "$VM" --wait 240 2>/dev/null)"
    [ -n "$VM_IP" ] || { say "no IP for $VM after 240 s; see $VM_LOG"; return 1; }
    local waited=0
    until "$probe" true 2>/dev/null; do
        if ! kill -0 "$RUN_PID" 2>/dev/null; then say "$VM stopped while booting; see $VM_LOG"; return 1; fi
        [ "$waited" -ge 300 ] && { say "ssh to $VM ($VM_IP) did not come up; see $VM_LOG"; return 1; }
        sleep 5
        waited=$((waited + 5))
    done
    say "ssh up at $VM_IP"
}

# vm_stop — graceful stop, then the run process, then force if it is stuck.
vm_stop() {
    vm_running || return 0
    say "stopping $VM"
    "$TART" stop "$VM" --timeout 60 >/dev/null 2>&1
    [ -n "$RUN_PID" ] && wait "$RUN_PID" 2>/dev/null
    if vm_running; then
        [ -n "$RUN_PID" ] && kill "$RUN_PID" 2>/dev/null
        sleep 2
        vm_running && say "warning: $VM may still be running (check tart list)"
    fi
    RUN_PID=""
    return 0
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=8 -o ServerAliveInterval=30 -i "$VM_KEY")

# ssh_guest <command...> — run a command in the guest, non-interactive.
ssh_guest() { ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; }

RSYNC_SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $VM_KEY"

# rsync_to_guest <local> <guest-path> [extra rsync args...]
rsync_to_guest() {
    local src="$1" dst="$2"
    shift 2
    rsync -a --delete -e "$RSYNC_SSH" "$@" "$src" "$VM_USER@$VM_IP:$dst"
}

# rsync_from_guest <guest-path> <local> — no --delete: the local side is the run's
# artefact directory, the guest side is the source of truth.
rsync_from_guest() {
    local src="$1" dst="$2"
    shift 2
    rsync -a -e "$RSYNC_SSH" "$@" "$VM_USER@$VM_IP:$src" "$dst"
}

# vm_copy_shots SRC DEST — copy a run's shots and their sidecar reports out of
# the boot's work dir, so the next boot's `rm -rf` of that dir cannot lose
# them (round 5's dark set went that way). DEST is created and merged into,
# never removed: one boot's copy outlives every later boot's. Prints the
# count, so the log says whether the copy happened.
vm_copy_shots() {
    local src="$1" dest="$2" files
    [ -d "$src" ] || return 0
    mkdir -p "$dest" || { say "shot dir: cannot create $dest"; return 1; }
    files="$(ls -1 "$src" 2>/dev/null | wc -l | tr -d ' ')"
    cp -R "$src/." "$dest/" || { say "shot copy failed: $src -> $dest"; return 1; }
    say "shots copied: $files files -> $dest"
}

# vm_password_ssh <command...> — first contact with the stock admin/admin
# account (before the ssh key is installed). ssh only calls askpass when there
# is no terminal; SSH_ASKPASS_REQUIRE=force makes it regardless.
vm_password_ssh() {
    local askpass
    askpass="$(mktemp -t pd-e2e-askpass)"
    printf '#!/bin/sh\nprintf "%%s\\n" admin\n' > "$askpass"
    chmod 700 "$askpass"
    SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
            "$VM_USER@$VM_IP" "$@"
    local rc=$?
    rm -f "$askpass"
    return $rc
}
