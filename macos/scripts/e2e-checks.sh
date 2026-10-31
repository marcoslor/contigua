# The e2e check names, one source of truth for check-e2e.sh and vm-e2e.sh
# (arch M10: the VM script's own list had drifted and lacked gates/hover/density).
# Sourced, never run.

# The order `all` runs in. The shared-app checks (from deck, whose launch they
# share, to drop) run back to back; every other check launches its own app.
ALL_CHECKS=(tls qr pair gates forgot direct mirror spotlight clip sharein links share apk dock shortcuts nickname settings notify notify-actions notify-media media notify-vm menubar-vm handoff
            deck deckrail windows render resize input hover mouseback pinch chrome livetext menus density trackpad pause nav audio drop files files-bridge files-write files-watch intents mcp focus controls
            pathkill pathmirror pathswitch pathgrace pathstart pathversion pathrejoin pathbulk
            dnd-edge panel-edge
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

# --- paths (P1, docs/design/paths.md §10.4) --------------------------------
# The six checks share the fault proxy and a fake phone with two listeners.
PATHFAULT_PIDS=()
PATHFAULT_CTL=""

# path_log — the running app's session lines (the path transitions and the
# replay peak are privacy: .public, so the check reads the exact tokens).
# The process id goes in the predicate: `log show --process` is ignored when an
# explicit --predicate is given, which once let a previous run's lines in.
path_log() {
    /usr/bin/log show --last 5m --info --style syslog \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null
}

# pathfault_start <listen> <target> [mode] [delay-ms] — starts one proxy and
# sets PATHFAULT_CTL to its ctl file. Call it directly, never in `$(...)`:
# a command substitution runs in a subshell, so PATHFAULT_PIDS loses the PID
# and pathfault_stop_all cannot kill the proxy (pathmirror once left 47736/
# 47737 running; only the next check's pathfault_nuke hid it).
pathfault_start() {
    local listen="$1" target="$2" mode="${3:-pass}" delay="${4:-}" rate="${5:-}" ctl rate_arg=()
    ctl="$WORK/fault-$listen.ctl"
    : > "$ctl"
    [ -z "$rate" ] || rate_arg=(--rate-mbit "$rate")
    if [ -n "$delay" ]; then
        "$FAKE_PY" "$ROOT/tools/pdpathfault/pdpathfault.py" \
            --listen "$listen" --connect "127.0.0.1:$target" --mode "$mode" \
            --delay-ms "$delay" ${rate_arg[@]+"${rate_arg[@]}"} --ctl-file "$ctl" --events "$WORK/fault-$listen.events" \
            > "$WORK/fault-$listen.log" 2>&1 &
    else
        "$FAKE_PY" "$ROOT/tools/pdpathfault/pdpathfault.py" \
            --listen "$listen" --connect "127.0.0.1:$target" --mode "$mode" \
            ${rate_arg[@]+"${rate_arg[@]}"} --ctl-file "$ctl" --events "$WORK/fault-$listen.events" \
            > "$WORK/fault-$listen.log" 2>&1 &
    fi
    PATHFAULT_PIDS+=("$!")
    for _ in $(seq 1 40); do
        grep -q "pdpathfault .* listening" "$WORK/fault-$listen.log" 2>/dev/null && break
        sleep 0.1
    done
    PATHFAULT_CTL="$ctl"
}

# pathfault_nuke — kill a proxy an earlier failed run left on one of this
# run's dedicated ports (the e2e lock already keeps other runs out).
pathfault_nuke() {
    local listen
    for listen in "$((PORT + 2))" "$((PORT + 3))" "$((PORT + 4))"; do
        pkill -f "pdpathfault.py --listen $listen" >/dev/null 2>&1 || true
    done
}

pathfault_stop_all() {
    local pid
    for pid in ${PATHFAULT_PIDS[@]+"${PATHFAULT_PIDS[@]}"}; do
        kill "$pid" >/dev/null 2>&1
        wait "$pid" 2>/dev/null
    done
    PATHFAULT_PIDS=()
}

pathfault_mode() { printf 'mode %s\n' "$2" > "$1"; }

# path_hello_listener — the listener port of the first plain hello.
path_hello_listener() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello" and event.get("plain"):
        print(event.get("listener") or "")
        break
PY
}

# path_ctl_for_listener <listener> — the proxy in front of that listener.
path_ctl_for_listener() {
    if [ "$1" = "$PORT" ]; then
        printf '%s\n' "$WORK/fault-$((PORT + 3)).ctl"
    else
        printf '%s\n' "$WORK/fault-$((PORT + 4)).ctl"
    fi
}

# path_pair_once <port> — pair on a fresh profile before a two-provider
# launch: a held, unpinned attempt is closed at welcome (pathstart), so the
# second launch must find a pin. The fake's log is truncated after it.
path_pair_once() {
    launch --connect "127.0.0.1:$1" --quit-after 10
    wait_until 12 events_have '"state":"auth_ok"' || true
    stop_app
    sleep 0.5
    : > "$WORK/events.jsonl"
}

# path_upto <N> — at least N paths are up in the fake's log.
path_upto() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
want = int(sys.argv[2])
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "path" and event.get("kind") == "up":
        count += 1
sys.exit(0 if count >= want else 1)
PY
}

# path_pongs <N> — at least N distinct paths answered the fake's own ping
# (PATH-12: the phone pings each path the moment it attaches it).
path_pongs() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
want = int(sys.argv[2])
answered = set()
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "path" and event.get("kind") == "pong":
        answered.add(event.get("path"))
sys.exit(0 if len(answered) >= want else 1)
PY
}

# path_no_pong_lost — no path missed a pong (the first ping after attach
# included, which is what --ping-on-welcome sends).
path_no_pong_lost() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "path" and event.get("kind") == "pong_lost":
        sys.exit(1)
sys.exit(0)
PY
}

# path_rel_paths — how many distinct paths carried a reliable frame.
path_rel_paths() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
paths = set()
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "rel":
        paths.add(event.get("path"))
print(len(paths))
PY
}

# path_welcome_session — the session id the fake welcomed (an id, no values).
path_welcome_session() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "welcome" and event.get("session"):
        print(event["session"])
        break
PY
}

# path_join_hello <session> — a later path's hello named that session (a join).
path_join_hello() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
want = sys.argv[2]
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello" and event.get("join") == want and want:
        sys.exit(0)
sys.exit(1)
PY
}

# path_joined_up — a joined (not founding) path attached again.
path_joined_up() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "path" and event.get("kind") == "up" and event.get("joined"):
        sys.exit(0)
sys.exit(1)
PY
}

# path_mac_pings_since <epoch> — how many path.ping frames the Mac sent after
# <epoch> (the fake logs every JSON it receives).
path_mac_pings_since() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
start = float(sys.argv[2])
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "rx" or event.get("ts", 0) < start:
        continue
    msg = event.get("msg") or {}
    if msg.get("t") == "path.ping":
        count += 1
print(count)
PY
}

check_pathstart() {
    clean
    pathfault_nuke
    local listen="$((PORT + 2))" ctl plain_count join_count listener ok_all=0
    FAKE_ARGS="--paths 2 --ping-on-welcome" start_fake || return 1
    # The first listener's radio is off until the second founds. `delay`, not
    # `blackhole`: a radio that is off buffers the client's first bytes; a
    # blackhole drops them, and a real path cannot finish TLS from bytes it
    # never sent again. 600 ms is longer than the second listener's handshake
    # and far inside the 6 s connect budget.
    pathfault_start "$listen" "$PORT" delay 600
    ctl="$PATHFAULT_CTL"
    path_pair_once "$((PORT + 1))"
    launch --connect "127.0.0.1:$listen" --connect2 "127.0.0.1:$((PORT + 1))" \
        --open-phone --quit-after 25
    # The first listener is dead radio until the second has founded: only then
    # does it come back, its attempt becomes ready and PathStart joins it.
    for _ in $(seq 1 40); do
        [ "$(path_hello_listener)" = "$((PORT + 1))" ] && break
        sleep 0.25
    done
    pathfault_mode "$ctl" pass
    wait_until 20 path_upto 2 || bad "[PATH-20] PATHSTART a second path never joined"
    # PATH-12: each path's first ping (sent with its welcome) must be answered.
    wait_until 15 path_pongs 2 \
        && ok "[PATH-12] PATHSTART the first ping on each path was answered" \
        || bad "[PATH-12] PATHSTART the Mac did not answer the phone's first ping on each path"
    wait_until 15 path_no_pong_lost \
        && ok "[PATH-12] PATHSTART no path lost its first ping" \
        || bad "[PATH-12] PATHSTART a path lost its first ping"
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
hellos = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello":
        hellos.append(event)
plain = [h for h in hellos if h.get("plain")]
joins = [h for h in hellos if h.get("join")]
listener = plain[0].get("listener") if plain else None
if len(plain) == 1 and len(joins) >= 1 and len(joins[0].get("join") or "") == 32:
    print("plain=%d join=%d listener=%s" % (len(plain), len(joins), listener))
    sys.exit(0)
print("plain=%d join=%d %r" % (len(plain), len(joins), hellos))
sys.exit(1)
PY
    if [ $? -eq 0 ]; then
        listener="$(path_hello_listener)"
        if [ "$listener" = "$((PORT + 1))" ]; then
            ok "[PATH-20] PATHSTART exactly one plain hello, on the second listener; the held attempt joined with the winner's id"
        else
            bad "[PATH-20] PATHSTART the plain hello landed on listener $listener, not the second"
        fi
    else
        bad "[PATH-20] PATHSTART the hello accounting is wrong"
    fi
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-20] PATHSTART the session on the second listener is usable (a video stream opened)" \
        || bad "[PATH-20] PATHSTART the session never served a window"
    [ "$(grep -c '"kind":"up"' "$WORK/events.jsonl" 2>/dev/null)" -ge 2 ] \
        && ok "[PATH-20] PATHSTART the held attempt became a joined path" \
        || bad "[PATH-20] PATHSTART no joined path in the fake's log"
    stop_app
    stop_fakephone
    pathfault_stop_all

    # R-12: a provider that accepts TCP and then goes silent (a black hole) must
    # be abandoned at the dial deadline, closing its channel, while the live
    # provider founds the session. Before the deadline the thread and the fd
    # leaked for the life of the app.
    clean
    pathfault_nuke
    FAKE_ARGS="--paths 1" start_fake || return 1
    path_pair_once "$PORT"
    pathfault_start "$((PORT + 2))" "$PORT" blackhole
    launch --connect "127.0.0.1:$((PORT + 2))" --connect2 "127.0.0.1:$PORT" \
        --open-phone --quit-after 22
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-20] PATHSTART the session founds on the live provider beside a black hole" \
        || bad "[PATH-20] PATHSTART the black-holed provider blocked the session"
    if wait_until 12 python3 - "$WORK/fault-$((PORT + 2)).events" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") in ("eof", "close"):
        sys.exit(0)
sys.exit(1)
PY
    then
        ok "[PATH-20] PATHSTART the silent dial closed its channel at the dial deadline"
    else
        bad "[PATH-20] PATHSTART the silent dial kept its channel open (no EOF at the proxy)"
    fi
    stop_app
    stop_fakephone
    pathfault_stop_all
}

check_pathversion() {
    clean
    local out hellos
    start_fake || return 1
    # Direction 2: a v3-shaped hello against the v4 phone.
    out="$(PD_PY_ROOT="$ROOT" "$FAKE_PY" - "$PORT" <<'PY'
import os, socket, sys
sys.path.insert(0, os.path.join(os.environ["PD_PY_ROOT"], "tools", "fakephone"))
import proto
try:
    raw = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
    context = proto.tls_client_context()
    sock = context.wrap_socket(raw, server_hostname="fakephone.local")
    sock.sendall(proto.pack_json({"t": "hello", "v": 3, "clientId": "v3", "name": "old peer"}))
    answer = proto.recv_frame(sock)
    message = proto.unpack_json(answer) if answer is not None else {}
    after = proto.recv_frame(sock)
    print("code=%s v=%s closed=%s" % (message.get("code"), message.get("v"), after is None))
    sys.exit(0 if message.get("code") == "version" and message.get("v") == 4 and after is None else 1)
except Exception as exc:
    print("error=%s" % exc)
    sys.exit(1)
PY
)"
    case "$out" in
        "code=version v=4 closed=True")
            ok "[PATH-1] PATHVERSION a v3-shaped hello got error version carrying 4 and a close, no welcome" ;;
        *)
            bad "[PATH-1] PATHVERSION the v4 phone's answer was: $out" ;;
    esac
    events_have '"kind":"version_refused"' \
        && ok "[PATH-1] PATHVERSION the phone logged the refusal" \
        || bad "[PATH-1] PATHVERSION the phone did not log the refusal"
    events_have '"ev":"hello"' \
        && bad "[PATH-1] PATHVERSION a refused hello reached the session slot" \
        || ok "[PATH-1] PATHVERSION no path frame, join or session was served to the v3 peer"
    stop_fakephone
    sleep 1
    # Direction 1: a v3 phone refuses the Mac, which names the app and stops.
    FAKE_ARGS="--version 3" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-banner "$WORK/banner.txt" --quit-after 14
    wait_until 10 events_have '"kind":"version_refused"' \
        && ok "[PATH-1] PATHVERSION the v3 phone refused the Mac's v4 hello" \
        || bad "[PATH-1] PATHVERSION the v3 phone never refused"
    wait_until 5 grep -qF "Update PocketDeck on your phone." "$WORK/banner.txt" \
        && ok "[PATH-1] PATHVERSION the Mac says \"Update PocketDeck on your phone.\"" \
        || bad "[PATH-1] PATHVERSION the Mac did not name the phone's update: $(cat "$WORK/banner.txt" 2>/dev/null)"
    sleep 3
    hellos="$(grep -c '"ev":"hello"' "$WORK/events.jsonl" 2>/dev/null || true)"
    [ "${hellos:-0}" -eq 0 ] \
        && ok "[PATH-1] PATHVERSION the Mac stopped retrying (no second hello)" \
        || bad "[PATH-1] PATHVERSION the Mac retried a refused version ($hellos hellos)"
    stop_app
    stop_fakephone
}

check_pathkill() {
    clean
    pathfault_nuke
    local ctl founder ok_peak
    python3 - "$WORK/pathkill.bin" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as fp:
    fp.write(os.urandom(64 * 1024 * 1024))
PY
    FAKE_ARGS="--paths 2" start_fake || return 1
    pathfault_start "$((PORT + 3))" "$PORT"
    pathfault_start "$((PORT + 4))" "$((PORT + 1))"
    path_pair_once "$PORT"
    printf '%s\n' "dropfile $WORK/pathkill.bin" "wait 30" > "$WORK/pathkill.txt"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open com.android.settings --debug-input-script "$WORK/pathkill.txt" --quit-after 40
    wait_until 25 path_upto 2 || bad "[PATH-4] PATHKILL the second path never joined"
    founder=""
    for _ in $(seq 1 80); do
        founder="$(path_hello_listener)"
        [ -n "$founder" ] && break
        sleep 0.25
    done
    ctl="$(path_ctl_for_listener "$founder")"
    if wait_until 40 grep -q '"ev":"drop_progress"' "$WORK/events.jsonl"; then
        pathfault_mode "$ctl" blackhole
        ok "[PATH-4] PATHKILL the current path was black-holed mid-file (8 MiB received)"
    else
        bad "[PATH-4] PATHKILL the transfer never started"
        pathfault_mode "$ctl" blackhole
    fi
    if wait_until 90 grep -q '"ev":"drop".*"match":true.*"ok":true' "$WORK/events.jsonl"; then
        ok "[PATH-4] PATHKILL the file arrived byte-exact across the black-holed path (sha256 match)"
    else
        bad "[PATH-4] PATHKILL the 64 MiB file never arrived intact: $(grep '"ev":"drop"' "$WORK/events.jsonl" | tail -2)"
    fi
    sleep 1
    grep -qF "session failed" "$WORK/app.log" \
        && bad "[PATH-4] PATHKILL the session ended during the transfer" \
        || ok "[PATH-4] PATHKILL the session stayed live on the second path"
    # Let the app finish and write its replay peak (unified log: the path
    # layer's lines are public closed tokens).
    wait_app
    ok_peak="$(path_log | grep -o 'paths: replay peak [0-9]* bytes' | tail -1 | awk '{print $4}')"
    if [ -n "$ok_peak" ] && [ "$ok_peak" -le $((16 * 1024 * 1024)) ]; then
        ok "[PATH-4] PATHKILL the replay buffer peaked at $ok_peak bytes (<= 16 MiB)"
    else
        bad "[PATH-4] PATHKILL replay peak '${ok_peak:-missing}' is over the 16 MiB credit"
    fi
    stop_fakephone
    pathfault_stop_all
}

check_pathmirror() {
    clean
    pathfault_nuke
    local ctl founder t0 delta
    FAKE_ARGS="--paths 2" start_fake || return 1
    pathfault_start "$((PORT + 3))" "$PORT"
    pathfault_start "$((PORT + 4))" "$((PORT + 1))"
    path_pair_once "$PORT"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open-phone --quit-after 25
    wait_until 20 path_upto 2 || bad "[PATH-5] PATHMIRROR the second path never joined"
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-5] PATHMIRROR the mirrored picture is live before the fault" \
        || bad "[PATH-5] PATHMIRROR no mirror video before the fault"
    founder=""
    for _ in $(seq 1 80); do
        founder="$(path_hello_listener)"
        [ -n "$founder" ] && break
        sleep 0.25
    done
    ctl="$(path_ctl_for_listener "$founder")"
    t0="$(python3 -c 'import time; print(time.time())')"
    pathfault_mode "$ctl" blackhole
    delta="$(python3 - "$WORK/events.jsonl" "$t0" <<'PY'
import json, sys, time
start = float(sys.argv[2])
deadline = time.time() + 4.0
while time.time() < deadline:
    configs = []
    switches = []
    for line in open(sys.argv[1]):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        stamp = event.get("ts", 0)
        if event.get("ev") == "video" and event.get("config") and stamp > start:
            configs.append(stamp)
        if event.get("ev") == "path" and event.get("kind") == "switch" and stamp > start:
            switches.append(stamp)
    if switches:
        after = [stamp for stamp in configs if stamp >= switches[0]]
        if after:
            # recovery is measured from the switch (the Mac decided); the
            # total from the black-hole includes the pong timeout that found it.
            print("%.2f %.2f" % ((after[0] - switches[0]) * 1000.0,
                                 (after[0] - start) * 1000.0))
            sys.exit(0)
    time.sleep(0.1)
print("no-config" if not configs else "no-switch")
sys.exit(1)
PY
)"
    case "$delta" in
        no-config|no-switch|"")
            bad "[PATH-5] PATHMIRROR no fresh VIDEO_CONFIG/keyframe on the second path after the black-hole: $delta" ;;
        *)
            recovery="${delta%% *}"
            total="${delta##* }"
            if python3 -c "import sys; sys.exit(0 if float('$recovery') <= 2000 else 1)"; then
                ok "[PATH-5] PATHMIRROR the picture was live on the second path ${recovery} ms after the switch (${total} ms after the black-hole; stale_picture_ms 2000)"
            else
                bad "[PATH-5] PATHMIRROR the picture took ${recovery} ms after the switch (${total} ms after the fault)"
            fi ;;
    esac
    # The window said "reconnecting" only if there was no path; with a standby
    # it must not have failed. Either way the session is still the same.
    grep -qF "session failed" "$WORK/app.log" \
        && bad "[PATH-5] PATHMIRROR the session ended on the black-holed path" \
        || ok "[PATH-5] PATHMIRROR the session survived the path failure"
    stop_app
    stop_fakephone
    pathfault_stop_all
}

check_pathswitch() {
    clean
    local seqs path_count verdict
    FAKE_ARGS="--paths 2 --slow-pong 1 1000" start_fake || return 1
    path_pair_once "$PORT"
    {
        printf 'click 0.5 0.5\nwait 1\n'
        for _ in $(seq 1 40); do
            printf 'click 0.3 0.3\nscroll 30\nwait 0.5\n'
        done
    } > "$WORK/pathswitch.txt"
    launch --connect "127.0.0.1:$PORT" --connect2 "127.0.0.1:$((PORT + 1))" \
        --open com.android.settings --debug-input-script "$WORK/pathswitch.txt" --quit-after 30
    wait_until 20 path_upto 2 || bad "[PATH-9] PATHSWITCH the second path never joined"
    if wait_until 20 events_have '"kind":"switch"'; then
        ok "[PATH-9] PATHSWITCH the Mac switched by margin to the better path (planned marker)"
    else
        bad "[PATH-9] PATHSWITCH no margin switch happened: $(grep '"kind":"' "$WORK/events.jsonl" | tail -3)"
    fi
    # The input script runs for ~20 s; the switch can land at 9 s. Give the
    # next click a bounded moment to travel on the new path, or the verdict
    # would only ever see the old one and stop the app first.
    wait_until 6 test "$(path_rel_paths)" -ge 2 || true
    verdict="$(python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
seqs = []
paths = set()
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "rel":
        seqs.append(event["seq"])
        paths.add(event.get("path"))
if not seqs:
    print("no-frames")
    sys.exit(1)
unique = sorted(set(seqs))
missing = [n for n in range(unique[0], unique[-1] + 1) if n not in unique]
dups = len(seqs) - len(unique)
print("frames=%d paths=%d range=%d..%d dups=%d missing=%d"
      % (len(seqs), len(paths), unique[0], unique[-1], dups, len(missing)))
sys.exit(0 if len(paths) >= 2 and dups == 0 and not missing else 1)
PY
)"
    if [ $? -eq 0 ]; then
        ok "[PATH-3] PATHSWITCH $verdict — every reliable seq once, across both paths"
    else
        bad "[PATH-3] PATHSWITCH reliable frames across the switch: $verdict"
    fi
    stop_app
    stop_fakephone
}

check_pathgrace() {
    clean
    local ends
    FAKE_ARGS="--paths 2 --drop-path all after 5 --no-rejoin" start_fake || return 1
    path_pair_once "$PORT"
    launch --connect "127.0.0.1:$PORT" --connect2 "127.0.0.1:$((PORT + 1))" \
        --open-phone --quit-after 55
    wait_until 20 path_upto 2 || bad "[PATH-6] PATHGRACE the second path never joined"
    wait_until 20 events_have '"kind":"grace"' \
        && ok "[PATH-6] PATHGRACE the fake dropped every path and entered the grace" \
        || bad "[PATH-6] PATHGRACE the paths were not dropped"
    local path_lines=""
    for _ in $(seq 1 160); do
        path_lines="$(path_log)"
        grep -q -- '--grace--> ended' <<<"$path_lines" && break
        sleep 0.25
    done
    grep -q -- '--grace--> ended' <<<"$path_lines" \
        && ok "[PATH-6] PATHGRACE the Mac ended the session at the 30 s grace ($(printf '%s\n' "$path_lines" | grep -o 'paths: [a-z]* --grace--> [a-z]*' | tail -1))" \
        || bad "[PATH-6] PATHGRACE the 30 s grace never ended: $(printf '%s\n' "$path_lines" | tail -3)"
    ends="$(printf '%s\n' "$path_lines" | grep -c -- '--grace--> ended' || true)"
    [ "${ends:-0}" -eq 1 ] \
        && ok "[PATH-6] PATHGRACE exactly one grace transition" \
        || bad "[PATH-6] PATHGRACE $ends grace transitions"
    wait_until 15 python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
hellos = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello" and event.get("plain"):
        hellos += 1
sys.exit(0 if hellos >= 2 else 1)
PY
    [ $? -eq 0 ] \
        && ok "[PATH-6] PATHGRACE the Mac retried and founded a new session (the slot is free)" \
        || bad "[PATH-6] PATHGRACE the Mac did not retry after the grace"
    sleep 1
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
downs = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "path" and event.get("kind") == "down":
        downs += 1
print("downs=%d" % downs)
sys.exit(0 if downs >= 2 else 1)
PY
    [ $? -eq 0 ] \
        && ok "[PATH-6] PATHGRACE the old session's sockets closed (no orphan)" \
        || bad "[PATH-6] PATHGRACE the old session's paths did not close"
    stop_app
    stop_fakephone
}

# pathrejoin (D-3, R-3): the only path dies and the route comes back inside the
# 30 s grace. The Mac re-dials a join at once, the phone answers the same
# session, the windows leave "reconnecting", and no new session starts.
check_pathrejoin() {
    clean
    pathfault_nuke
    local ctl session path_lines
    FAKE_ARGS="--paths 1" start_fake || return 1
    path_pair_once "$PORT"
    pathfault_start "$((PORT + 3))" "$PORT"
    ctl="$PATHFAULT_CTL"
    local t_launch
    t_launch="$(date +%s)"
    launch --connect "127.0.0.1:$((PORT + 3))" --open-phone --quit-after 40
    wait_until 20 events_have '"ev":"video"' \
        && ok "[PATH-6] PATHREJOIN the session is live on its only path" \
        || bad "[PATH-6] PATHREJOIN the session never opened a window"
    # D-1: one path is never pinged. Give the 2 s ticker two chances to prove it.
    sleep 3
    local mac_pings
    mac_pings="$(path_mac_pings_since "$t_launch")"
    [ "${mac_pings:-1}" -eq 0 ] \
        && ok "[PATH-7] PATHREJOIN a one-path session sends no path.ping" \
        || bad "[PATH-7] PATHREJOIN a one-path session sent $mac_pings path.pings"
    session="$(path_welcome_session)"
    [ -n "$session" ] \
        && ok "[PATH-3] PATHREJOIN the phone minted the session" \
        || bad "[PATH-3] PATHREJOIN no welcome reached the phone"
    # A dead radio that resets: the Mac must see the path die at once and say
    # reconnecting (a black hole would surface only through TCP keepalive).
    pathfault_mode "$ctl" rst
    path_lines=""
    for _ in $(seq 1 40); do
        path_lines="$(path_log)"
        grep -q -- '--failed--> orphaned' <<<"$path_lines" && break
        sleep 0.25
    done
    grep -q -- '--failed--> orphaned' <<<"$path_lines" \
        && ok "[PATH-17] PATHREJOIN the only path died and the session went orphaned" \
        || bad "[PATH-17] PATHREJOIN the orphan transition never happened: $(printf '%s\n' "$path_lines" | tail -2)"
    sleep 2
    pathfault_mode "$ctl" pass
    wait_until 20 path_join_hello "$session" \
        && ok "[PATH-22] PATHREJOIN the Mac re-dialed a join with the same session id" \
        || bad "[PATH-3] PATHREJOIN no join named the session again: $(grep '"ev":"hello"' "$WORK/events.jsonl" | tail -2)"
    wait_until 15 path_joined_up \
        && ok "[PATH-22] PATHREJOIN the phone attached the path to the same session" \
        || bad "[PATH-6] PATHREJOIN no path attached after the route came back"
    path_lines=""
    for _ in $(seq 1 40); do
        path_lines="$(path_log)"
        grep -Eq -- '--up--> live' <<<"$path_lines" && break
        sleep 0.25
    done
    grep -Eq -- '--up--> live' <<<"$path_lines" \
        && ok "[PATH-17] PATHREJOIN the windows cleared \"reconnecting\" (orphaned --up--> live)" \
        || bad "[PATH-17] PATHREJOIN the session never returned to live: $(printf '%s\n' "$path_lines" | tail -2)"
    # One session, not a second one: the count of plain hellos stays at one.
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
plain = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello" and event.get("plain"):
        plain += 1
print("plain=%d" % plain)
sys.exit(0 if plain == 1 else 1)
PY
    [ $? -eq 0 ] \
        && ok "[PATH-22] PATHREJOIN no new session started (one plain hello)" \
        || bad "[PATH-3] PATHREJOIN a second session started"
    sleep 1
    grep -qF "session failed" "$WORK/app.log" \
        && bad "[PATH-6] PATHREJOIN the session ended instead of rejoining" \
        || ok "[PATH-6] PATHREJOIN no session failed"
    stop_app
    stop_fakephone
    pathfault_stop_all
}

# pathbulk (D-2, R-5): a 16 Mbit/s path carries a 32 MiB drop while a fast
# standby exists. The throttled path's ping must not wait behind the bulk, so
# the Mac never declares it failed: no unplanned switch, and the hash is exact.
check_pathbulk() {
    clean
    pathfault_nuke
    local slow_ctl fast_ctl founder bytes_ok
    python3 - "$WORK/pathbulk.bin" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as fp:
    fp.write(os.urandom(32 * 1024 * 1024))
PY
    FAKE_ARGS="--paths 2" start_fake || return 1
    pathfault_start "$((PORT + 3))" "$PORT" throttle "" 16
    slow_ctl="$PATHFAULT_CTL"
    # The standby starts behind a handshake delay so the throttled path founds
    # the session; it is made fast once both paths are up.
    pathfault_start "$((PORT + 4))" "$((PORT + 1))" delay 600
    fast_ctl="$PATHFAULT_CTL"
    path_pair_once "$PORT"
    python3 - "$WORK/pathbulk2.bin" <<'PY2'
import os, sys
with open(sys.argv[1], "wb") as fp:
    fp.write(os.urandom(64 * 1024 * 1024))
PY2
    # E-4/PATH-23: a second transfer starts the moment the check releases it,
    # and 0.6 s in (mid-transfer) the script types a KEY. `stamp` writes the
    # moment it was typed, so the fake's own arrival time gives the latency.
    printf '%s\n' "dropfile $WORK/pathbulk.bin" \
        "waitfile $WORK/pathbulk-again 90" \
        "dropfile $WORK/pathbulk2.bin" "wait 0.6" \
        "stamp $WORK/pathbulk-key.ts" "key left" "wait 30" > "$WORK/pathbulk.txt"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open com.android.settings --debug-input-script "$WORK/pathbulk.txt" --quit-after 60
    wait_until 25 path_upto 2 || bad "[PATH-10] PATHBULK the standby never joined"
    founder=""
    for _ in $(seq 1 80); do
        founder="$(path_hello_listener)"
        [ -n "$founder" ] && break
        sleep 0.25
    done
    if [ "$founder" = "$PORT" ]; then
        ok "[PATH-10] PATHBULK the drop started on the throttled path"
    else
        bad "[PATH-10] PATHBULK the session founded on listener ${founder:-?}, not the throttled one"
    fi
    # The standby is fast for the rest of the run: a live throttled path must
    # still not be failed by a late pong.
    pathfault_mode "$fast_ctl" pass
    if wait_until 70 grep -q '"ev":"drop".*"match":true.*"ok":true' "$WORK/events.jsonl"; then
        ok "[PATH-10] [PATH-23] PATHBULK the 32 MiB file arrived byte-exact across the throttled path"
    else
        bad "[PATH-10] PATHBULK the file never arrived intact: $(grep '"ev":"drop"' "$WORK/events.jsonl" | tail -2)"
    fi
    # D-2: the throttled path must not be failed while bulk runs. A planned
    # margin switch is legitimate (a faster standby exists); a failure-driven
    # one is not: no lost pong and no socket error may have moved the session.
    # The peer sees the marker on whichever path it reaches first, so the Mac's
    # own transition log is the evidence, not the fake's arrival.
    local path_lines
    path_lines="$(path_log)"
    grep -q -- '--pong-lost-->' <<<"$path_lines" \
        && bad "[PATH-23] PATHBULK the throttled path was failed by a lost pong during the transfer" \
        || ok "[PATH-23] PATHBULK no path was demoted by a lost pong during the transfer"
    grep -q "paths: path down" <<<"$path_lines" \
        && bad "[PATH-23] PATHBULK a path died during the transfer" \
        || ok "[PATH-23] PATHBULK both paths stayed open"
    # The check is vacuous unless the throttle actually carried the file.
    bytes_ok="$(python3 - "$WORK/fault-$((PORT + 3)).events" <<'PY'
import json, sys
total = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "bytes":
        total += event.get("n") or 0
print(total)
PY
)"
    if [ -n "$bytes_ok" ] && [ "$bytes_ok" -ge $((1 << 20)) ]; then
        ok "[PATH-23] PATHBULK the throttled path carried $bytes_ok bytes"
    else
        bad "[PATH-23] PATHBULK the throttled path carried ${bytes_ok:-0} bytes"
    fi
    grep -qF "session failed" "$WORK/app.log" \
        && bad "[PATH-23] PATHBULK the session ended during the transfer" \
        || ok "[PATH-23] PATHBULK the session stayed live"
    # E-4/PATH-23: a fresh session on the same two listeners, both throttled at
    # 400 Mbit/s (a fast LAN, the link where input_latency_ms is a real
    # promise). A KEY typed 0.6 s into a 64 MiB drop must not wait behind the
    # transfer: before E-4 it sat behind the whole 12 MiB credit, now behind at
    # most the 256 KiB send window plus one chunk. A fresh launch keeps the
    # window (and its input route) out of the first phase's long transfer.
    local input_limit latency_ms
    input_limit="$(nfr_limit input_latency_ms)"
    stop_app
    sleep 0.5
    printf 'rate 400\n' > "$slow_ctl"
    printf 'rate 400\n' > "$fast_ctl"
    sleep 0.2
    printf 'mode throttle\n' > "$fast_ctl"
    sleep 0.2
    printf '%s\n' "dropfile $WORK/pathbulk2.bin" "wait 0.6" \
        "stamp $WORK/pathbulk-key.ts" "key left" "wait 20" > "$WORK/pathbulk-key.txt"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open com.android.settings --debug-input-script "$WORK/pathbulk-key.txt" --quit-after 40
    # The KEY may be late by design on the old code, so wait for its arrival
    # (30 s, more than the whole 64 MiB drop) before judging it.
    for _ in $(seq 1 120); do
        [ -s "$WORK/pathbulk-key.ts" ] && grep -q '"kind":"key"' "$WORK/events.jsonl" && break
        sleep 0.25
    done
    latency_ms="$(python3 - "$WORK/pathbulk-key.ts" "$WORK/events.jsonl" <<'PY'
import json, sys
try:
    stamp = float(open(sys.argv[1]).read().strip())
except (OSError, ValueError):
    sys.exit(2)
starts = {}
ends = {}
key = None
for line in open(sys.argv[2]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "rx" and (event.get("msg") or {}).get("t") == "drop.start":
        starts[event["msg"].get("id")] = event.get("ts", 0)
    if event.get("ev") == "drop":
        ends[event.get("id")] = event.get("ts", 0)
    if (event.get("ev") == "input" and event.get("kind") == "key"
            and event.get("action") == 0 and event.get("ts", 0) >= stamp and key is None):
        key = event["ts"]
# The KEY must have been typed while the second drop ran; if it was typed
# after the transfer ended, the measurement proves nothing.
running = [sid for sid, at in starts.items()
           if at <= stamp and ends.get(sid, stamp + 1) > stamp]
if not running:
    print("not-running")
    sys.exit(3)
if key is None:
    sys.exit(1)
print("%.1f" % ((key - stamp) * 1000.0))
PY
)"
    case "$latency_ms" in
        not-running)
            bad "[PATH-23] PATHBULK the KEY was typed after the second drop had finished" ;;
        ""|2)
            bad "[PATH-23] PATHBULK the KEY never reached the phone during the drop" ;;
        *)
            if python3 -c "import sys; sys.exit(0 if float('$latency_ms') <= $input_limit else 1)"; then
                ok "[PATH-23] PATHBULK a KEY typed mid-drop reached the phone in ${latency_ms} ms (input_latency_ms $input_limit)"
            else
                bad "[PATH-23] PATHBULK a KEY typed mid-drop took ${latency_ms} ms (input_latency_ms $input_limit)"
            fi ;;
    esac
    stop_app
    stop_fakephone
    pathfault_stop_all
}
