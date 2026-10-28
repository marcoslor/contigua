# The e2e check names, one source of truth for check-e2e.sh and vm-e2e.sh
# (arch M10: the VM script's own list had drifted and lacked gates/hover/density).
# Sourced, never run.

# The order `all` runs in. The shared-app checks (from deck, whose launch they
# share, to drop) run back to back; every other check launches its own app.
ALL_CHECKS=(tls qr pair gates direct mirror spotlight clip sharein links share apk dock nickname settings notify notify-actions notify-media media notify-vm menubar-vm handoff
            deck windows multiwin render resize input hover mouseback pinch chrome livetext menus density trackpad pause nav audio drop files files-bridge files-write files-watch intents mcp focus controls
            files-domain nfr menubar-shots)

# True when $1 is one of ALL_CHECKS.
valid_check() {
    local c
    for c in "${ALL_CHECKS[@]}"; do
        [ "$c" = "$1" ] && return 0
    done
    return 1
}

# The names joined with `|`, for the usage lines.
check_list() {
    local IFS='|'
    echo "${ALL_CHECKS[*]}"
}
