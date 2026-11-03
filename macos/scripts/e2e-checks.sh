# The e2e check names, one source of truth for check-e2e.sh and vm-e2e.sh
# (arch M10: the VM script's own list had drifted and lacked gates/hover/density).
# Sourced, never run.

# The order `all` runs in. The shared-app checks (from deck, whose launch they
# share, to drop) run back to back; every other check launches its own app.
ALL_CHECKS=(tls qr pair gates forgot direct mirror spotlight clip sharein links share apk dock shortcuts nickname settings notify notify-actions notify-media media notify-vm menubar-vm handoff
            deck deckrail windows multiwin zoom render resize input hover mouseback pinch chrome livetext menus density trackpad pause nav audio drop drop-sources paste files files-bridge files-write files-watch intents mcp focus controls
            pathkill pathmirror pathswitch pathgrace pathstart pathversion pathrejoin pathrestart pathbulk pathblip
            dnd-edge panel-edge
            files-domain files-thumbs nfr menubar-shots)


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

# path_ctl_other <listener> — the proxy in front of the listener that did not
# found the session.
path_ctl_other() {
    if [ "$1" = "$PORT" ]; then
        printf '%s\n' "$WORK/fault-$((PORT + 4)).ctl"
    else
        printf '%s\n' "$WORK/fault-$((PORT + 3)).ctl"
    fi
}

# path_join_hello_since <session> <epoch> — a join naming that session arrived
# after <epoch> (a rejoin, not the one the phase already made).
path_join_hello_since() {
    python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
want, start = sys.argv[2], float(sys.argv[3])
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if (event.get("ev") == "hello" and event.get("join") == want
            and event.get("ts", 0) > start):
        sys.exit(0)
sys.exit(1)
PY
}

# path_joined_up_since <epoch> — a joined (not founding) path attached after
# <epoch> (the phase's own first join is not the rejoin being proved).
path_joined_up_since() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
start = float(sys.argv[2])
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if (event.get("ev") == "path" and event.get("kind") == "up"
            and event.get("joined") and event.get("ts", 0) > start):
        sys.exit(0)
sys.exit(1)
PY
}

# path_restart_timeline <old-session> <epoch> — after <epoch>, the first join
# hello naming the old session, the first plain hello and the first welcome
# carrying a *different* session id (a restarted phone's process). Prints
# `join=… hello=… welcome=… session=…`; exits 1 until that new welcome exists.
path_restart_timeline() {
    python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
old, start = sys.argv[2], float(sys.argv[3])
join = hello = welcome = None
session = ""
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello" and event.get("ts", 0) > start:
        if event.get("join") == old and join is None:
            join = event["ts"]
        elif event.get("plain") and hello is None:
            hello = event["ts"]
    if (event.get("ev") == "welcome" and event.get("ts", 0) > start
            and event.get("session") and event["session"] != old and welcome is None):
        welcome = event["ts"]
        session = event["session"]
if welcome is None:
    sys.exit(1)
def show(value):
    return "none" if value is None else "%.3f" % value
print("join=%s hello=%s welcome=%s session=%s" % (show(join), show(hello), show(welcome), session))
PY
}

# path_video_since <epoch> — a video frame arrived after <epoch>.
path_video_since() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
start = float(sys.argv[2])
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "video" and event.get("ts", 0) > start:
        sys.exit(0)
sys.exit(1)
PY
}

# chrome_offline <file> — the stream window's bar says the link is down
# (PATH-17's reconnecting state); the app writes it with --debug-chrome-state.
chrome_offline() { grep -q 'bar_offline=1' "$1" 2>/dev/null; }
chrome_online() { grep -q 'bar_offline=0' "$1" 2>/dev/null; }

# path_now — decimal epoch seconds, for the grace's 4 s and 30 s bounds.
path_now() { python3 -c 'import time; print("%.3f" % time.time())'; }

# path_stream_start — follow this run's app into $WORK/app-stream.log. A poll of
# the unified log costs about a second per call; the grace's 4 s bound and its
# 30 s timer need the transitions as they land.
path_stream_start() {
    /usr/bin/log stream --info --style syslog --predicate "processID == $APP_PID" \
        > "$WORK/app-stream.log" 2>/dev/null &
    PATH_STREAM_PID=$!
}

path_stream_stop() {
    [ -n "${PATH_STREAM_PID:-}" ] && kill "$PATH_STREAM_PID" >/dev/null 2>&1
    wait "$PATH_STREAM_PID" 2>/dev/null || true
    PATH_STREAM_PID=""
}

# path_wait_line <seconds> <extended regex> — the live app log gains the line
# before the deadline.
path_wait_line() {
    local end=$((SECONDS + $1))
    while :; do
        grep -qE -- "$2" "$WORK/app-stream.log" 2>/dev/null && return 0
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 0.1
    done
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
    # The bulk window is sized for input latency (E-4), so a 64 MiB file needs
    # more ack rounds than the old 12 MiB credit: keep the app up for the whole
    # wait the check allows.
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open com.android.settings --debug-input-script "$WORK/pathkill.txt" --quit-after 95
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

# pathgrace (PATH-6, PATH-21/E-9, PATH-17): the grace starts three ways:
#  1. every path is killed and no join ever comes: at 30 s the session ends
#     cleanly — one `paths: ... --grace--> ended`, the phone's slot is free,
#     the Mac retries, no orphaned socket stays open;
#  2. E-9 (boot 13): the current path loses its pong and becomes a standby,
#     then the only other path goes silent. No non-standby path is left, so
#     the Mac orphans within 4 s of the second, its window says the link is
#     down, and the grace ends 30 s ± 2 s later;
#  3. the same, but the route comes back 10 s after the second path went
#     silent: the Mac re-dials joins, the same session id comes back, and the
#     picture resumes within 5 s of the route.
# Phase (b) also carries ISS-5/NOTIFY-1: a live row and a timer are up before
# the black-out; while it runs the phone's own state moves (one row's progress,
# the other ended) with nothing sent; after the rejoin the Mac asks again and
# shows the new progress, the ended row gone, and no second banner.
check_pathgrace() {
    clean
    local ends
    # live rows through the debug-control folder (the menu bar's LIVE section).
    live_dump() { control livedump "$1" >/dev/null 2>&1; }
    live_has() { # live_has FILE ID — the dump worked and holds that row
        [ -s "$1" ] || return 1
        python3 - "$1" "$2" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1])).get("live") or []
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if any(row.get("id") == sys.argv[2] for row in rows) else 1)
PY
    }
    live_is() { # live_is FILE ID PROGRESS — that row carries that progress
        [ -s "$1" ] || return 1
        python3 - "$1" "$2" "$3" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1])).get("live") or []
except (OSError, ValueError):
    sys.exit(1)
for row in rows:
    if row.get("id") == sys.argv[2]:
        progress = row.get("progress")
        sys.exit(0 if isinstance(progress, (int, float))
                 and abs(progress - float(sys.argv[3])) < 0.001 else 1)
sys.exit(1)
PY
    }
    live_row_has() { live_dump "$1" && live_has "$1" "$2"; }
    live_row_is() { live_dump "$1" && live_is "$1" "$2" "$3"; }
    # live_row_gone — the dump worked and the row is not in it.
    live_row_gone() { live_dump "$1" && ! live_has "$1" "$2"; }
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

    # (a) E-9: A, the founder and current path, loses its pong and becomes a
    # standby; 3 s after that first black-hole the other path goes silent too.
    # Nothing non-standby is left, so the session orphans and starts the grace
    # exactly as when no path is left.
    clean
    pathfault_nuke
    local founder ctl_a ctl_b t_first t_second t_seen dt_orphan orphan_seen grace_seen grace_dt
    FAKE_ARGS="--paths 2" start_fake || return 1
    pathfault_start "$((PORT + 3))" "$PORT"
    pathfault_start "$((PORT + 4))" "$((PORT + 1))"
    path_pair_once "$PORT"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open-phone --debug-chrome-state "$WORK/chrome-grace.txt" --quit-after 70
    path_stream_start
    wait_until 20 path_upto 2 \
        || bad "[PATH-6] PATHGRACE(a) the second path never joined"
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-6] PATHGRACE(a) the two-path session is live before the faults" \
        || bad "[PATH-6] PATHGRACE(a) no mirror video before the faults"
    founder=""
    for _ in $(seq 1 80); do
        founder="$(path_hello_listener)"
        [ -n "$founder" ] && break
        sleep 0.25
    done
    ctl_a="$(path_ctl_for_listener "$founder")"
    ctl_b="$(path_ctl_other "$founder")"
    t_first="$(path_now)"
    pathfault_mode "$ctl_a" blackhole
    path_wait_line 5 -- '--pong-lost-->' \
        && ok "[PATH-7] PATHGRACE(a) the current path's lost pong demoted it to a standby" \
        || bad "[PATH-7] PATHGRACE(a) the current path was not demoted: $(path_log | tail -2)"
    # The brief's 3 s, counted from the first black-hole; the demote lands
    # inside them at the 2 s ping / 1.5 s pong cadence.
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_first') + 3.0 else 1)"; do
        sleep 0.1
    done
    t_second="$(path_now)"
    pathfault_mode "$ctl_b" blackhole
    orphan_seen=0
    for _ in $(seq 1 45); do
        if grep -qE -- '--(pong-lost|failed)--> orphaned' "$WORK/app-stream.log" 2>/dev/null; then
            orphan_seen=1
            break
        fi
        sleep 0.1
    done
    t_seen="$(path_now)"
    dt_orphan="$(python3 -c "print('%.2f' % (float('$t_seen') - float('$t_second')))")"
    if [ "$orphan_seen" = 1 ] && python3 -c "import sys; sys.exit(0 if float('$dt_orphan') <= 4.0 else 1)"; then
        ok "[PATH-21] PATHGRACE(a) the Mac went orphaned ${dt_orphan}s after the second black-hole (limit 4.0)"
    else
        bad "[PATH-21] PATHGRACE(a) no orphan within 4.0 s of the second black-hole: seen=$orphan_seen dt=${dt_orphan}s $(tail -2 "$WORK/app-stream.log" 2>/dev/null)"
    fi
    wait_until 3 chrome_offline "$WORK/chrome-grace.txt" \
        && ok "[PATH-17] PATHGRACE(a) the window says the link is down (reconnecting), not a live picture" \
        || bad "[PATH-17] PATHGRACE(a) the window kept the link up: $(cat "$WORK/chrome-grace.txt" 2>/dev/null)"
    grace_seen=0
    for _ in $(seq 1 320); do
        if grep -q -- '--grace--> ended' "$WORK/app-stream.log" 2>/dev/null; then grace_seen=1; break; fi
        sleep 0.1
    done
    grace_dt="$(python3 -c "import time; print('%.1f' % (time.time() - float('$t_seen')))")"
    if [ "$grace_seen" = 1 ] && python3 -c "import sys; sys.exit(0 if 28.0 <= float('$grace_dt') <= 32.0 else 1)"; then
        ok "[PATH-6] PATHGRACE(a) the Mac ended the session at the 30 s grace (${grace_dt}s after the orphan)"
    else
        bad "[PATH-6] PATHGRACE(a) the grace end came ${grace_dt}s after the orphan (want 30 ± 2), seen=$grace_seen: $(tail -2 "$WORK/app-stream.log" 2>/dev/null)"
    fi
    stop_app
    path_stream_stop
    stop_fakephone
    pathfault_stop_all

    # (b) E-9's in-grace recovery: same two faults, and the route is back 10 s
    # after the second. A raised black-hole resets the sockets it starved (the
    # radio reassociated), so the Mac re-dials joins over the restored route:
    # the same session id comes back and the picture resumes.
    clean
    pathfault_nuke
    local session t_lift rejoin_dt
    local notify_log="$WORK/notify-grace.log" notify_device="" t_rejoin="" notify_dt=""
    FAKE_ARGS="--paths 2 --notify-rejoin" start_fake || return 1
    pathfault_start "$((PORT + 3))" "$PORT"
    pathfault_start "$((PORT + 4))" "$((PORT + 1))"
    path_pair_once "$PORT"
    # The per-phone opt-in is a stored default, seeded after the pairing run so
    # that run did not enable it (docs/specs/notifications.md NOTIFY-1).
    notify_device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$notify_device" ] \
        || { bad "[NOTIFY-1] PATHGRACE(b) no device id in the fakephone listening line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "notify.$notify_device" -bool YES
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open-phone --debug-chrome-state "$WORK/chrome-grace2.txt" --quit-after 70 \
        --debug-control "$WORK-control" --share-log "$notify_log"
    path_stream_start
    wait_until 20 path_upto 2 \
        || bad "[PATH-6] PATHGRACE(b) the second path never joined"
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-6] PATHGRACE(b) the two-path session is live before the faults" \
        || bad "[PATH-6] PATHGRACE(b) no mirror video before the faults"
    # ISS-5: a Live Update and a timer are on the menu bar before the black-out.
    wait_until 20 live_row_has "$WORK/grace-live-1.json" pd-r1 \
        && ok "[NOTIFY-12] PATHGRACE(b) the live row is up before the outage" \
        || bad "[NOTIFY-12] PATHGRACE(b) no live row before the outage: $(cat "$notify_log" 2>/dev/null | tail -3 | tr '\n' '|')"
    live_row_has "$WORK/grace-live-1.json" pd-r2 \
        && ok "[NOTIFY-12] PATHGRACE(b) the timer row is up before the outage" \
        || bad "[NOTIFY-12] PATHGRACE(b) no timer row before the outage"
    founder=""
    for _ in $(seq 1 80); do
        founder="$(path_hello_listener)"
        [ -n "$founder" ] && break
        sleep 0.25
    done
    ctl_a="$(path_ctl_for_listener "$founder")"
    ctl_b="$(path_ctl_other "$founder")"
    session="$(path_welcome_session)"
    [ -n "$session" ] \
        && ok "[PATH-3] PATHGRACE(b) the phone minted the session" \
        || bad "[PATH-3] PATHGRACE(b) no welcome reached the phone"
    t_first="$(path_now)"
    pathfault_mode "$ctl_a" blackhole
    path_wait_line 5 -- '--pong-lost-->' \
        && ok "[PATH-7] PATHGRACE(b) the current path's lost pong demoted it to a standby" \
        || bad "[PATH-7] PATHGRACE(b) the current path was not demoted: $(path_log | tail -2)"
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_first') + 3.0 else 1)"; do
        sleep 0.1
    done
    t_second="$(path_now)"
    pathfault_mode "$ctl_b" blackhole
    orphan_seen=0
    for _ in $(seq 1 45); do
        if grep -qE -- '--(pong-lost|failed)--> orphaned' "$WORK/app-stream.log" 2>/dev/null; then
            orphan_seen=1
            break
        fi
        sleep 0.1
    done
    if [ "$orphan_seen" = 1 ]; then
        ok "[PATH-21] PATHGRACE(b) the Mac went orphaned after the second black-hole"
    else
        bad "[PATH-21] PATHGRACE(b) no orphan after the second black-hole: $(tail -2 "$WORK/app-stream.log" 2>/dev/null)"
    fi
    # Ten seconds with no route: the session must stay orphaned, never end
    # early and never resume on a standby.
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_second') + 10.0 else 1)"; do
        sleep 0.2
    done
    grep -q -- '--grace--> ended' "$WORK/app-stream.log" 2>/dev/null \
        && bad "[PATH-6] PATHGRACE(b) the session ended inside the 10 s black-out" \
        || ok "[PATH-6] PATHGRACE(b) still orphaned 10 s after the second black-hole, inside the grace"
    t_lift="$(path_now)"
    pathfault_mode "$ctl_a" rst
    pathfault_mode "$ctl_b" rst
    sleep 0.3
    pathfault_mode "$ctl_a" pass
    pathfault_mode "$ctl_b" pass
    if wait_until 5 path_join_hello_since "$session" "$t_lift"; then
        rejoin_dt="$(python3 -c "print('%.2f' % (float('$(path_now)') - float('$t_lift')))")"
        ok "[PATH-22] PATHGRACE(b) the Mac re-dialed a join with the same session id ${rejoin_dt}s after the route came back (limit 5.0)"
    else
        bad "[PATH-22] PATHGRACE(b) no rejoin named the session within 5.0 s: $(grep '"ev":"hello"' "$WORK/events.jsonl" | tail -2)"
    fi
    wait_until 10 path_joined_up_since "$t_lift" \
        && ok "[PATH-22] PATHGRACE(b) the phone attached the rejoined path to the same session" \
        || bad "[PATH-6] PATHGRACE(b) no path attached after the route came back"
    t_rejoin="$(path_now)"
    # ISS-5/NOTIFY-1: the phone's state moved while no path was up (one row's
    # progress, the timer ended) and nothing was sent. The Mac repeated its
    # opt-in once the rejoined path was current; the active set must bring the
    # rows up to date within 3 s, without a second banner.
    if wait_until 3 live_row_is "$WORK/grace-live-2.json" pd-r1 0.9; then
        notify_dt="$(python3 -c "print('%.2f' % (float('$(path_now)') - float('$t_rejoin')))")"
        ok "[NOTIFY-1] PATHGRACE(b) the live row showed the phone's new progress ${notify_dt}s after the rejoin (limit 3.0)"
    else
        notify_dt="$(python3 -c "print('%.2f' % (float('$(path_now)') - float('$t_rejoin')))")"
        bad "[NOTIFY-1] PATHGRACE(b) the live row's new progress did not arrive within 3 s of the rejoin (${notify_dt}s): $(cat "$notify_log" 2>/dev/null | tail -3 | tr '\n' '|')"
    fi
    live_row_gone "$WORK/grace-live-2.json" pd-r2 \
        && ok "[NOTIFY-1] PATHGRACE(b) the timer row the phone ended during the outage is gone" \
        || bad "[NOTIFY-1] PATHGRACE(b) the ended timer row is still in the LIVE section"
    [ "$(grep -cE 'notify post id=pd-r1 .* presented=1 ' "$notify_log" 2>/dev/null)" = "1" ] \
        && ok "[NOTIFY-19] PATHGRACE(b) the active set presented no second banner" \
        || bad "[NOTIFY-19] PATHGRACE(b) a live row presented more than once: $(grep -E 'notify post id=pd-r1 ' "$notify_log" 2>/dev/null | tr '\n' '|')"
    [ "$(grep -cF 'notify post id=pd-r2 ' "$notify_log" 2>/dev/null)" = "1" ] \
        && ok "[NOTIFY-1] PATHGRACE(b) the active set did not re-post the ended row" \
        || bad "[NOTIFY-1] PATHGRACE(b) the ended row was posted again: $(grep -F 'notify post id=pd-r2 ' "$notify_log" 2>/dev/null | tr '\n' '|')"
    wait_until 5 chrome_online "$WORK/chrome-grace2.txt" \
        && ok "[PATH-17] PATHGRACE(b) the window left reconnecting" \
        || bad "[PATH-17] PATHGRACE(b) the window still says the link is down"
    wait_until 10 path_video_since "$t_lift" \
        && ok "[PATH-5] PATHGRACE(b) the picture resumed after the rejoin" \
        || bad "[PATH-5] PATHGRACE(b) no video frame after the rejoin"
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
        && ok "[PATH-22] PATHGRACE(b) the rejoin started no new session (one plain hello)" \
        || bad "[PATH-3] PATHGRACE(b) a second session started"
    stop_app
    path_stream_stop
    stop_fakephone
    pathfault_stop_all

    # (c) E-11c: no route for 15 s (both sockets cut, every rejoin refused),
    # then the route is lifted. The rejoin must be dialed back to back inside
    # the grace, so the same session is back and the picture resumes within
    # 3.0 s of the lift — not after a backoff step. The proxies' conn events
    # count every dial, including the refused ones, and their gaps.
    clean
    pathfault_nuke
    local t_black dials video_dt
    FAKE_ARGS="--paths 2" start_fake || return 1
    pathfault_start "$((PORT + 3))" "$PORT"
    pathfault_start "$((PORT + 4))" "$((PORT + 1))"
    path_pair_once "$PORT"
    launch --connect "127.0.0.1:$((PORT + 3))" --connect2 "127.0.0.1:$((PORT + 4))" \
        --open-phone --debug-chrome-state "$WORK/chrome-grace3.txt" --quit-after 75
    path_stream_start
    wait_until 20 path_upto 2 \
        || bad "[PATH-6] PATHGRACE(c) the second path never joined"
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-6] PATHGRACE(c) the two-path session is live before the faults" \
        || bad "[PATH-6] PATHGRACE(c) no mirror video before the faults"
    founder=""
    for _ in $(seq 1 80); do
        founder="$(path_hello_listener)"
        [ -n "$founder" ] && break
        sleep 0.25
    done
    ctl_a="$(path_ctl_for_listener "$founder")"
    ctl_b="$(path_ctl_other "$founder")"
    session="$(path_welcome_session)"
    # No route for 15 s: both sockets are cut and every rejoin is refused, the
    # pathrestart case (a phone with no server). A silent black hole would make
    # each dial hang for the 6 s general timeout, which could land the old 8 s
    # step anywhere; a refusal fails now and shows the backoff itself.
    pathfault_mode "$ctl_a" rst
    pathfault_mode "$ctl_b" rst
    t_black="$(path_now)"
    orphan_seen=0
    for _ in $(seq 1 45); do
        if grep -qE -- '--(pong-lost|failed)--> orphaned' "$WORK/app-stream.log" 2>/dev/null; then
            orphan_seen=1
            break
        fi
        sleep 0.1
    done
    if [ "$orphan_seen" = 1 ]; then
        ok "[PATH-21] PATHGRACE(c) the Mac went orphaned when both paths were cut"
    else
        bad "[PATH-21] PATHGRACE(c) no orphan after both paths were cut: $(tail -2 "$WORK/app-stream.log" 2>/dev/null)"
    fi
    # Fifteen seconds with no route: the session must stay inside the grace.
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_black') + 15.0 else 1)"; do
        sleep 0.2
    done
    grep -q -- '--grace--> ended' "$WORK/app-stream.log" 2>/dev/null \
        && bad "[PATH-6] PATHGRACE(c) the session ended inside the 15 s black-out" \
        || ok "[PATH-6] PATHGRACE(c) still orphaned after 15 s with no route, inside the grace"
    t_lift="$(path_now)"
    pathfault_mode "$ctl_a" pass
    pathfault_mode "$ctl_b" pass
    if wait_until 5 path_join_hello_since "$session" "$t_lift"; then
        rejoin_dt="$(python3 -c "print('%.2f' % (float('$(path_now)') - float('$t_lift')))")"
        ok "[PATH-22] PATHGRACE(c) the Mac re-dialed a join with the same session id ${rejoin_dt}s after the 15 s lift (limit 5.0)"
    else
        bad "[PATH-22] PATHGRACE(c) no rejoin named the session within 5.0 s: $(grep '"ev":"hello"' "$WORK/events.jsonl" | tail -2)"
    fi
    wait_until 10 path_joined_up_since "$t_lift" \
        && ok "[PATH-22] PATHGRACE(c) the phone attached the rejoined path to the same session" \
        || bad "[PATH-6] PATHGRACE(c) no path attached after the 15 s lift"
    if wait_until 5 path_video_since "$t_lift"; then
        video_dt="$(python3 -c "print('%.2f' % (float('$(path_now)') - float('$t_lift')))")"
        if python3 -c "import sys; sys.exit(0 if float('$video_dt') <= 3.0 else 1)"; then
            ok "[PATH-5] PATHGRACE(c) the picture resumed ${video_dt}s after the 15 s lift (limit 3.0)"
        else
            bad "[PATH-5] PATHGRACE(c) the picture resumed ${video_dt}s after the 15 s lift (limit 3.0)"
        fi
    else
        bad "[PATH-5] PATHGRACE(c) no video frame after the 15 s lift"
    fi
    wait_until 5 chrome_online "$WORK/chrome-grace3.txt" \
        && ok "[PATH-17] PATHGRACE(c) the window left reconnecting" \
        || bad "[PATH-17] PATHGRACE(c) the window still says the link is down"
    dials="$(python3 - "$WORK/fault-$((PORT + 3)).events" "$WORK/fault-$((PORT + 4)).events" "$t_black" "$t_lift" <<'PY'
import json, sys
start, end = float(sys.argv[3]), float(sys.argv[4])
times = []
for path in sys.argv[1:3]:
    try:
        for line in open(path):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("ev") == "conn" and start <= event.get("ts", 0) <= end:
                times.append(event["ts"])
    except OSError:
        pass
times.sort()
gaps = ",".join("%.2f" % (b - a) for a, b in zip(times, times[1:])) or "-"
print("dials=%d gaps=%s" % (len(times), gaps))
PY
)"
    ok "[PATH-6] PATHGRACE(c) rejoin dials during the 15 s no-route window: ${dials:-none}"
    stop_app
    path_stream_stop
    stop_fakephone
    pathfault_stop_all
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

# pathblip (PATH-24, E-11): one path and one live window. The radio dies and
# comes back only for NEW connections, exactly as a socket stuck in TCP's
# retransmission backoff behaves: the old connection stays silent, so the Mac
# cannot wait for it. The probe join dialed during the silence must welcome
# after the lift, the session must switch to it at once, and the first frame
# over the new path must arrive within blip_recovery_ms. No probe while the
# path was healthy, one session, no Reconnecting.
#
# pathblip_phase <blackout-seconds> <label> — the same run with a chosen
# outage. E-11b's long variant (20 s) also proves the probes never stop:
# their count and the gaps between them are logged, and the first frame after
# the lift is held to blip_recovery_ms. Today's 1/2/4 s backoff leaves one
# probe in flight for the whole general connect timeout, so a 20 s outage
# recovers far too late.
pathblip_phase() {
    local blackout="$1" label="$2"
    clean
    pathfault_nuke
    local ctl session founder t_launch t_fault t_lift conns_before delta blip_ms probes gaps chrome_pid=""
    blip_ms="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["blip_recovery_ms"]))' "$MACOS/scripts/nfr-limits.json")"
    FAKE_ARGS="--paths 1" start_fake || return 1
    path_pair_once "$PORT"
    pathfault_start "$((PORT + 3))" "$PORT"
    ctl="$PATHFAULT_CTL"
    # The rig's own readiness probes reach the proxy before the app does: the
    # count below starts at this launch.
    t_launch="$(path_now)"
    launch --connect "127.0.0.1:$((PORT + 3))" --open com.android.settings \
        --debug-frame-log "$WORK/frames.tsv" --debug-chrome-state "$WORK/chrome.txt" \
        --quit-after 80
    # The chrome file is overwritten on every change; sample it so a flash of
    # Reconnecting cannot hide between two reads.
    : > "$WORK/blip-stop"
    (
        while [ ! -e "$WORK/blip-stop" ]; do
            [ -s "$WORK/chrome.txt" ] && cat "$WORK/chrome.txt" 2>/dev/null
            sleep 0.1
        done
    ) > "$WORK/chrome-ticks.txt" &
    chrome_pid=$!
    wait_until 20 events_have '"kind":"up"' \
        && ok "[PATH-24] PATHBLIP($label) the session is live on its only path" \
        || bad "[PATH-24] PATHBLIP($label) no path attached"
    session="$(path_welcome_session)"
    [ -n "$session" ] \
        && ok "[PATH-3] PATHBLIP($label) the phone minted the session" \
        || bad "[PATH-3] PATHBLIP($label) no welcome reached the phone"
    wait_until 20 events_have '"ev":"video"' \
        && ok "[PATH-24] PATHBLIP($label) the app window shows a live picture" \
        || bad "[PATH-24] PATHBLIP($label) no app-window video"
    # Healthy: the stream moves, so nothing is silent and nothing probes.
    sleep 4
    founder="$(awk '$1 >= 0 { p = $3 } END { print p }' "$WORK/frames.tsv")"
    [ -n "$founder" ] || bad "[PATH-24] PATHBLIP($label) the frame log names no path"
    conns_before="$(python3 - "$WORK/fault-$((PORT + 3)).events" "$t_launch" <<'PY'
import json, sys
since = float(sys.argv[2])
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "conn" and float(event.get("ts", 0)) >= since:
        count += 1
print(count)
PY
)"
    [ "${conns_before:-0}" -eq 1 ] \
        && ok "[PATH-24] PATHBLIP($label) no probe was dialed while the path was healthy (one connection)" \
        || bad "[PATH-24] PATHBLIP($label) $conns_before connections before the fault"
    t_fault="$(path_now)"
    pathfault_mode "$ctl" blackhole
    # E-11: 2 s of silence starts one probe. The proxy accepts its TCP
    # connection at once even though the TLS hello is dropped, so the second
    # connection before the lift is the dial's own evidence. A rejoin after the
    # old path died would come later (and must not count).
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_fault') + 3.5 else 1)"; do
        sleep 0.1
    done
    conns_before="$(python3 - "$WORK/fault-$((PORT + 3)).events" <<'PY'
import json, sys
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "conn":
        count += 1
print(count)
PY
)"
    [ "${conns_before:-0}" -ge 2 ] \
        && ok "[PATH-24] PATHBLIP($label) the Mac dialed one probe join during the silence" \
        || bad "[PATH-24] PATHBLIP($label) no probe join was dialed during the silence ($conns_before connection(s))"
    # Hold the radio off for the phase's outage from the fault, then lift it
    # for new connections only: the old socket stays in its backoff.
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_fault') + float('$blackout') else 1)"; do
        sleep 0.1
    done
    t_lift="$(path_now)"
    pathfault_mode "$ctl" pass-new
    # E-11b: the probes during the black hole, with the gaps between them.
    read -r probes gaps <<<"$(python3 - "$WORK/fault-$((PORT + 3)).events" "$t_fault" "$t_lift" <<'PY'
import json, sys
start, end = float(sys.argv[2]), float(sys.argv[3])
times = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "conn":
        ts = float(event.get("ts", 0))
        if start <= ts < end:
            times.append(ts)
gaps = [round(b - a, 1) for a, b in zip(times, times[1:])]
print(len(times), ",".join("%.1f" % gap for gap in gaps))
PY
)"
    if [ "$blackout" -ge 20 ]; then
        # Today's backoff: one 6 s dial plus 1 s and 2 s waits give 3 probes in
        # 20 s. E-11b's back-to-back 2.0 s dials give about 9.
        [ "${probes:-0}" -ge 6 ] \
            && ok "[PATH-24] PATHBLIP($label) the probes kept coming while black-holed: $probes in ${blackout} s, gaps ${gaps:-none} s" \
            || bad "[PATH-24] PATHBLIP($label) only $probes probe(s) in ${blackout} s (gaps ${gaps:-none} s)"
    else
        ok "[PATH-24] PATHBLIP($label) probes during the ${blackout} s black hole: $probes, gaps ${gaps:-none} s"
    fi
    wait_until 8 path_join_hello_since "$session" "$t_lift" \
        && ok "[PATH-24] PATHBLIP($label) the probe joined the same session through the lifted proxy" \
        || bad "[PATH-22] PATHBLIP($label) no join named the session after the lift: $(grep '"ev":"hello"' "$WORK/events.jsonl" | tail -2)"
    if wait_until 10 python3 - "$WORK/frames.tsv" "$t_lift" "$founder" <<'PY'
import sys
lift, founder = float(sys.argv[2]), sys.argv[3]
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    try:
        ts = float(parts[0])
    except ValueError:
        continue
    if ts >= lift and parts[2] != founder:
        sys.exit(0)
sys.exit(1)
PY
    then
        ok "[PATH-24] PATHBLIP($label) a frame arrived over the new path after the lift"
    else
        bad "[PATH-24] PATHBLIP($label) no frame arrived over the new path: $(tail -3 "$WORK/frames.tsv" 2>/dev/null | tr '\n' ' ')"
    fi
    delta="$(python3 - "$WORK/frames.tsv" "$t_lift" "$founder" <<'PY'
import sys
lift, founder = float(sys.argv[2]), sys.argv[3]
first = None
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    try:
        ts = float(parts[0])
    except ValueError:
        continue
    if ts >= lift and parts[2] != founder:
        first = ts
        break
print("none" if first is None else "%.0f" % ((first - lift) * 1000.0))
PY
)"
    if [ "$delta" = "none" ]; then
        bad "[PATH-24] PATHBLIP($label) the recovery time could not be measured"
    elif python3 -c "import sys; sys.exit(0 if float('$delta') <= $blip_ms else 1)"; then
        ok "[PATH-24] PATHBLIP($label) the first frame over the new path arrived ${delta} ms after the lift (blip_recovery_ms ${blip_ms})"
    else
        bad "[PATH-24] PATHBLIP($label) the first frame over the new path took ${delta} ms (blip_recovery_ms ${blip_ms})"
    fi
    # The switch was E-11's unplanned failover: the old path was still the
    # attached, live path when the probe welcomed. After that it is a standby,
    # demoted by its lost pong or closed by its own socket error (E-11), so a
    # later `path down` is not a failure of this rule.
    path_log > "$WORK/path-lines.log"
    if python3 - "$WORK/path-lines.log" <<'PY'
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
switch = None
for index, line in enumerate(lines):
    if "live --probe--> live" in line:
        switch = index
        break
if switch is None:
    sys.exit(1)
for line in lines[:switch]:
    if "paths: path down" in line:
        sys.exit(1)
sys.exit(0)
PY
    then
        ok "[PATH-24] PATHBLIP($label) the Mac switched to the probe while the old path was still live"
    else
        bad "[PATH-24] PATHBLIP($label) no probe switch transition: $(grep 'paths:' "$WORK/path-lines.log" | tail -3 | tr '\n' ' ')"
    fi
    grep -q 'bar_offline=1' "$WORK/chrome-ticks.txt" \
        && bad "[PATH-24] PATHBLIP($label) the window said Reconnecting during the blip" \
        || ok "[PATH-17] PATHBLIP($label) the window never said Reconnecting"
    grep -qF "session failed" "$WORK/app.log" \
        && bad "[PATH-6] PATHBLIP($label) the session ended instead of moving to the probe" \
        || ok "[PATH-6] PATHBLIP($label) the session stayed live"
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
plain = joins = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "hello":
        if event.get("plain"):
            plain += 1
        elif event.get("join"):
            joins += 1
print("plain=%d joins=%d" % (plain, joins))
sys.exit(0 if plain == 1 and joins >= 1 else 1)
PY
    [ $? -eq 0 ] \
        && ok "[PATH-3] PATHBLIP($label) one session: one plain hello and the probe's join" \
        || bad "[PATH-3] PATHBLIP($label) the hello accounting is wrong"
    : > "$WORK/blip-stop"
    [ -n "$chrome_pid" ] && kill "$chrome_pid" 2>/dev/null || true
    wait "$chrome_pid" 2>/dev/null || true
    stop_app
    stop_fakephone
    pathfault_stop_all
}

# The 8 s blip from E-11 stays; E-11b adds the 20 s outage that the old
# backoff could not meet.
check_pathblip() {
    pathblip_phase 8 short
    pathblip_phase 20 long
}

# pathrestart (RR-12): the phone's server restarts while the Mac holds a
# session (an app update, or Android killing and restarting the service). The
# new process knows no session, so the Mac's orphan join gets `no_session`;
# the Mac must start one new session at once, never wait out the 30 s grace.
# (a) one path, (b) two: the same with both providers.
pathrestart_phase() {
    local paths="$1" label="$2" session t_kill t_listen timeline t_join t_hello t_welcome
    local new_session chrome="$WORK/chrome-restart-$label.txt" second=()
    clean
    pathfault_nuke
    FAKE_ARGS="--paths $paths" start_fake || return 1
    path_pair_once "$PORT"
    [ "$paths" -lt 2 ] || second=(--connect2 "127.0.0.1:$((PORT + 1))")
    launch --connect "127.0.0.1:$PORT" ${second[@]+"${second[@]}"} \
        --open com.android.settings --debug-chrome-state "$chrome" --quit-after 70
    path_stream_start
    wait_until 20 path_upto "$paths" \
        && ok "[PATH-22] PATHRESTART($label) the ${paths}-path session is live before the kill" \
        || bad "[PATH-22] PATHRESTART($label) only $(grep -c '"kind":"up"' "$WORK/events.jsonl" 2>/dev/null) paths were up before the kill"
    wait_until 15 events_have '"ev":"video"' \
        && ok "[PATH-22] PATHRESTART($label) the app window shows a live picture before the kill" \
        || bad "[PATH-22] PATHRESTART($label) no app-window video before the kill"
    session="$(path_welcome_session)"
    [ -n "$session" ] \
        && ok "[PATH-22] PATHRESTART($label) the phone minted the first session" \
        || bad "[PATH-22] PATHRESTART($label) no welcome before the kill"
    t_kill="$(path_now)"
    kill -9 "$FAKE_PID"
    wait "$FAKE_PID" 2>/dev/null
    wait_until 5 chrome_offline "$chrome" \
        && ok "[PATH-17] PATHRESTART($label) the Mac shows Reconnecting while the phone is gone" \
        || bad "[PATH-17] PATHRESTART($label) the window kept the link up after the kill: $(cat "$chrome" 2>/dev/null)"
    # The brief's gap: the new process listens 2 s after the kill, not before.
    while python3 -c "import sys, time; sys.exit(0 if time.time() < float('$t_kill') + 2.0 else 1)"; do
        sleep 0.1
    done
    start_fake || return 1
    t_listen="$(path_now)"
    timeline=""
    for _ in $(seq 1 150); do
        timeline="$(path_restart_timeline "$session" "$t_kill")" && break
        sleep 0.1
    done
    if [ -z "$timeline" ]; then
        bad "[PATH-22] PATHRESTART($label) no new session within 15 s of the new fake: $(grep '"ev":"hello"' "$WORK/events.jsonl" | tail -2)"
        stop_app; path_stream_stop; stop_fakephone; return 1
    fi
    t_join="$(sed -n 's/.*join=\([^ ]*\).*/\1/p' <<<"$timeline")"
    t_hello="$(sed -n 's/.*hello=\([^ ]*\).*/\1/p' <<<"$timeline")"
    t_welcome="$(sed -n 's/.*welcome=\([^ ]*\).*/\1/p' <<<"$timeline")"
    new_session="$(sed -n 's/.*session=\([^ ]*\).*/\1/p' <<<"$timeline")"
    [ "$new_session" != "$session" ] \
        && ok "[PATH-22] PATHRESTART($label) the restarted phone minted a new session (not $session)" \
        || bad "[PATH-22] PATHRESTART($label) the session id did not change"
    local t_no_session="none"
    if grep -q -- 'session failed: no_session' "$WORK/app-stream.log" 2>/dev/null; then
        t_no_session="$(python3 - "$WORK/app-stream.log" <<'PY'
import datetime, re, sys
for line in open(sys.argv[1], errors="replace"):
    if "session failed: no_session" not in line:
        continue
    match = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
    if not match:
        continue
    try:
        print("%.3f" % datetime.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp())
        break
    except ValueError:
        continue
PY
)"
        [ -n "$t_no_session" ] || t_no_session="none"
        ok "[PATH-22] PATHRESTART($label) the orphan join was refused no_session and ended the old session at once"
    else
        bad "[PATH-22] PATHRESTART($label) no no_session in the app log: $(grep 'session failed' "$WORK/app-stream.log" 2>/dev/null | tail -2)"
    fi
    if python3 -c "import sys; sys.exit(0 if float('$t_welcome') - float('$t_listen') <= 5.0 else 1)"; then
        ok "[PATH-22] PATHRESTART($label) the Mac was online $(python3 -c "print('%.2f' % (float('$t_welcome') - float('$t_listen')))")s after the new fake listened (limit 5.0)"
    else
        bad "[PATH-22] PATHRESTART($label) the Mac was online $(python3 -c "print('%.2f' % (float('$t_welcome') - float('$t_listen')))")s after the new fake listened (limit 5.0)"
    fi
    ok "[PATH-22] PATHRESTART($label) times: kill=$t_kill listen=$t_listen join=$t_join no_session=$t_no_session hello=$t_hello welcome=$t_welcome"
    wait_until 10 chrome_online "$chrome" \
        && ok "[PATH-17] PATHRESTART($label) the window left Reconnecting" \
        || bad "[PATH-17] PATHRESTART($label) the window still says the link is down: $(cat "$chrome" 2>/dev/null)"
    wait_until 10 path_video_since "$t_listen" \
        && ok "[PATH-22] PATHRESTART($label) the app window shows a live picture again" \
        || bad "[PATH-22] PATHRESTART($label) no video frame after the restart"
    stop_app
    path_stream_stop
    stop_fakephone
    pathfault_stop_all
}

check_pathrestart() {
    pathrestart_phase 1 a
    pathrestart_phase 2 b
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
    printf '%s\n' "dropfile $WORK/pathbulk.bin" "wait 40" > "$WORK/pathbulk.txt"
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
    # E-8/RRR-4: a planned switch drains its old path, and E-5 re-dials it at
    # once; without the 30 s hold the fresh idle path won back every 8–25 s and
    # the pair churned a handshake during the whole transfer.
    local planned
    planned="$(printf '%s\n' "$path_lines" | grep -c -- ' (planned)' || true)"
    [ "${planned:-0}" -le 1 ] \
        && ok "[PATH-7] PATHBULK ${planned:-0} planned switch during the 32 MiB drop (at most one per 30 s)" \
        || bad "[PATH-7] PATHBULK $planned planned switches during the 32 MiB drop: $(printf '%s\n' "$path_lines" | grep -- ' (planned)' | tail -3)"
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
    # 600 Mbit/s (a fast LAN, the link where input_latency_ms is a real
    # promise). A KEY typed 0.6 s into a 64 MiB drop must not wait behind the
    # transfer: before E-4 it sat behind the whole 12 MiB credit, now behind at
    # most the 256 KiB send window plus one chunk. A fresh launch keeps the
    # window (and its input route) out of the first phase's long transfer.
    local input_limit latency_ms
    input_limit="$(nfr_limit input_latency_ms)"
    stop_app
    sleep 0.5
    printf 'rate 600\n' > "$slow_ctl"
    printf 'rate 600\n' > "$fast_ctl"
    sleep 0.2
    printf 'mode throttle\n' > "$fast_ctl"
    sleep 0.2
    # Two keys, half a second apart: the first can straddle the transfer's
    # ramp (the file's hash and the phone's opening reply), the second is
    # typed while the pipe is full. The measured one is the second.
    printf '%s\n' "dropfile $WORK/pathbulk2.bin" "wait 0.6" \
        "stamp $WORK/pathbulk-key-1.ts" "key left" \
        "wait 0.5" "stamp $WORK/pathbulk-key.ts" "key left" "wait 20" \
        > "$WORK/pathbulk-key.txt"
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
