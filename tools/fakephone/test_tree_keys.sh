#!/bin/bash
# The fake phone's ui.tree keys (MCP-71), heading (MCP-72) and covered (MCP-73):
# docs/PROTOCOL.md "UI tree" item 9. Run alone, or from test_selfcheck.sh.
#
# 1. The fixed tree: two reads give every row the same `k`; the off-screen rows
#    are left out and counted (MCP-106), the search field shows its hint
#    (MCP-104) and the one layer is `active` (MCP-105). With `offscreen` they
#    come back marked `off`; --keyboard adds an ime layer whose row has no focus.
# 2. --tree-variant: a heading row, a button covered by the banner's `k`, and a
#    second read without k 2, the other rows keeping theirs.
# 3. ui.press (item 8, MCP-86/89): k 2 presses Continue at its `at` (one touch
#    down/up); off-screen k 4 and unknown k 999 press nothing; --tree-variant's
#    covered k 6 is `covered` by 7; --relabel's k 2 is `changed`, no touch.
# 4. ui.type (item 10, MCP-109/110): "café" is set text, "milk 42" keys, and
#    with clear set text that replaces; the `type` event counts and never the text; --type-refuse refuses.
# Exits 0 only if every check passed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PD_FAKE_TLS_PYTHON:-}"
[ -n "$PY" ] || PY="$(command -v python3.11 || echo /usr/bin/python3)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fakephone-treekeys.XXXXXX")"
FH_PID=""

die() { echo "TREE-KEYS FAIL: $*" >&2; exit 1; }
note() { echo "-- $*"; }
cleanup() { [ -n "$FH_PID" ] && kill "$FH_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

# start <name> [fakephone flags…]: a fresh fake phone; sets PORT.
start() {
    local name="$1"; shift
    cleanup
    "$PY" "$HERE/fakephone.py" --port 0 --no-mdns --auto-allow \
        --state "$WORK/$name-state.json" "$@" >"$WORK/$name.out" 2>"$WORK/$name.err" &
    FH_PID=$!
    for _ in $(seq 1 100); do
        grep -q "listening on" "$WORK/$name.err" 2>/dev/null && break
        sleep 0.1
    done
    PORT="$(sed -nE 's/.*listening on 0\.0\.0\.0:([0-9]+).*/\1/p' "$WORK/$name.err" | head -1)"
    [ -n "$PORT" ] || die "fakephone ($name) did not report its port"
}

reads() {
    local name="$1"; shift
    "$PY" "$HERE/deckctl.py" --host 127.0.0.1 --port "$PORT" --state "$WORK/$name-deck.json" \
        --pair ui-tree --reads 2 "$@" > "$WORK/$name.jsonl" 2>"$WORK/$name-deck.err" \
        || die "ui-tree ($name) failed: $(cat "$WORK/$name-deck.err")"
}

note "ui-tree: the fixed tree keeps its keys across two reads (MCP-71)"
start fixed
reads fixed
"$PY" - "$WORK/fixed.jsonl" <<'PY' || die "fixed tree key assertions failed"
import json, sys
one, two = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
keys = lambda r: [n.get("k") for n in r["nodes"]]
assert keys(one) == [1, 2, 3, 9, 11, 12, 13, 14], keys(one)
assert keys(two) == keys(one), (keys(one), keys(two))
assert all("ref" not in n for n in one["nodes"]), "the phone sent a ref"
print("  keys %s, %s" % (keys(one), keys(two)))
PY

note "ui-tree: off-screen rows counted, a hint, the active layer (MCP-104/105/106)"
"$PY" - "$WORK/fixed.jsonl" <<'PY' || die "fixed tree B6 assertions failed"
import json, sys
one = json.loads(open(sys.argv[1]).readline())
rows = one["nodes"]
assert all(n.get("off") is not True for n in rows), "an off row was sent"
assert one["omitted"] == 6, one.get("omitted")
lst = next(n for n in rows if n.get("scroll"))
assert lst["hidden"] == [0, 5], lst.get("hidden")
assert [n["text"] for n in rows if n.get("p") == lst["i"]] == ["Row 1", "Row 2", "Row 3"]
assert all(n["p"] < n["i"] for n in rows if "p" in n), "a parent is not an earlier row"
hint = next(n for n in rows if n.get("hint"))
assert hint["hintText"] == "Search" and "text" not in hint, hint
assert one["layers"] == [{"i": 0, "title": one["layers"][0]["title"], "type": "app", "active": True}], one["layers"]
assert [n["k"] for n in rows if n.get("focus")] == [9]
print("  omitted %d, hidden %s, hint %r, layers %d" % (one["omitted"], lst["hidden"], hint["hintText"], len(one["layers"])))
PY

note "ui-tree offscreen: the left-out rows come back marked off, no at (MCP-106)"
start offscreen
reads offscreen --offscreen
"$PY" - "$WORK/offscreen.jsonl" <<'PY' || die "offscreen assertions failed"
import json, sys
one = json.loads(open(sys.argv[1]).readline())
off = [n for n in one["nodes"] if n.get("off")]
assert sorted(n["k"] for n in off) == [4, 15, 16, 17, 18, 19], off
assert all("at" not in n for n in off), off
assert one["omitted"] == 0 and all("hidden" not in n for n in one["nodes"]), one
print("  %d rows, %d off, omitted %d" % (len(one["nodes"]), len(off), one["omitted"]))
PY

note "ui-tree --keyboard: the ime layer is not active and its row has no focus (MCP-105)"
start keyboard --keyboard
reads keyboard
"$PY" - "$WORK/keyboard.jsonl" <<'PY' || die "keyboard assertions failed"
import json, sys
one = json.loads(open(sys.argv[1]).readline())
layers = one["layers"]
assert [l["type"] for l in layers] == ["app", "ime"], layers
assert layers[0].get("active") is True and "active" not in layers[1], layers
assert all("focused" not in l for l in layers), layers
key = next(n for n in one["nodes"] if n.get("l") == 1)
assert "focus" not in key and [n["k"] for n in one["nodes"] if n.get("focus")] == [9], one["nodes"]
print("  layers %s, focus only on k 9" % [l["type"] for l in layers])
PY

note "ui-tree --tree-variant: heading, covered, and a gone row's key not reused (MCP-71/72/73)"
start variant --tree-variant
reads variant
"$PY" - "$WORK/variant.jsonl" <<'PY' || die "tree-variant assertions failed"
import json, sys
one, two = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = lambda r: {n["k"]: n for n in r["nodes"]}
a, b = by(one), by(two)
assert len(a) == len(one["nodes"]) and len(b) == len(two["nodes"]), "a k is repeated in a reply"
heading = [n for n in one["nodes"] if n.get("heading") is True]
assert len(heading) == 1 and heading[0]["text"] == "Settings", heading
assert all("heading" not in n for n in one["nodes"] if n is not heading[0]), "heading on another row"
covered = [n for n in one["nodes"] if "covered" in n]
assert len(covered) == 1, covered
cover = a.get(covered[0]["covered"])
assert cover is not None and cover.get("click") is True, "covered names no clickable row of the read"
assert 2 in a and 2 not in b, (sorted(a), sorted(b))
for k, node in b.items():
    assert k in a and a[k]["role"] == node["role"] and a[k].get("text") == node.get("text"), k
assert [n["i"] for n in two["nodes"]] == list(range(len(two["nodes"]))), "rows are not renumbered"
print("  read 1 keys %s, read 2 keys %s, covered %s by %s"
      % (sorted(a), sorted(b), covered[0]["k"], covered[0]["covered"]))
PY

# presses <name> <flags…> -- <deckctl ui-press args…>: one fake phone, its events file.
presses() {
    local name="$1"; shift
    local flags=()
    while [ "$1" != "--" ]; do flags+=("$1"); shift; done
    shift
    start "$name" --events "$WORK/$name-events.jsonl" "${flags[@]+"${flags[@]}"}"
    "$PY" "$HERE/deckctl.py" --host 127.0.0.1 --port "$PORT" --state "$WORK/$name-deck.json" \
        --pair ui-press "$@" > "$WORK/$name.jsonl" 2>"$WORK/$name-deck.err" \
        || die "ui-press ($name) failed: $(cat "$WORK/$name-deck.err")"
}

note "ui-press: k 2 presses at its at; off-screen (left out of the tree) and unknown keys press nothing (MCP-86)"
presses press -- --k 2 --k 4 --k 999
"$PY" - "$WORK/press.jsonl" "$WORK/press-events.jsonl" <<'PY' || die "ui-press assertions failed"
import json, sys
ok, off, unknown = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
touches = [e for e in map(json.loads, open(sys.argv[2])) if e.get("kind") == "touch"]
assert ok["ok"] is True and ok["text"] == "Continue" and ok["role"] == "Button", ok
assert [t["action"] for t in touches] == [0, 1], touches
assert all([round(t["nx"], 3), round(t["ny"], 3)] == ok["at"] for t in touches), (touches, ok["at"])
assert off["ok"] is False and off["code"] == "off_screen", off
assert unknown["ok"] is False and unknown["code"] == "gone", unknown
print("  press ok at %s, k 4 %s, k 999 %s, touches %d" % (ok["at"], off["code"], unknown["code"], len(touches)))
PY

note "ui-press --tree-variant: the covered button is not pressed (MCP-89)"
presses covered --tree-variant -- --k 6
"$PY" - "$WORK/covered.jsonl" "$WORK/covered-events.jsonl" <<'PY' || die "ui-press covered assertions failed"
import json, sys
(reply,) = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
touches = [e for e in map(json.loads, open(sys.argv[2])) if e.get("kind") == "touch"]
assert reply["ok"] is False and reply["code"] == "covered" and reply["coveredBy"] == 7, reply
assert touches == [], touches
print("  k 6 covered by %s, touches 0" % reply["coveredBy"])
PY

note "ui-press --relabel: a stale expect presses nothing (MCP-86, #188)"
presses relabel --relabel -- --k 2
"$PY" - "$WORK/relabel.jsonl" "$WORK/relabel-events.jsonl" <<'PY' || die "ui-press relabel assertions failed"
import json, sys
(reply,) = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
touches = [e for e in map(json.loads, open(sys.argv[2])) if e.get("kind") == "touch"]
assert reply["ok"] is False and reply["code"] == "changed" and reply["now"] == "Continue later", reply
assert touches == [], touches
print("  k 2 changed, now %r, touches 0" % reply["now"])
PY

# types <name> <flags…> -- <deckctl ui-type args…>: one fake phone, its events file.
types() {
    local name="$1"; shift
    local flags=()
    while [ "$1" != "--" ]; do flags+=("$1"); shift; done
    shift
    start "$name" --events "$WORK/$name-events.jsonl" "${flags[@]+"${flags[@]}"}"
    "$PY" "$HERE/deckctl.py" --host 127.0.0.1 --port "$PORT" --state "$WORK/$name-deck.json" \
        --pair ui-type "$@" > "$WORK/$name.jsonl" 2>"$WORK/$name-deck.err" \
        || die "ui-type ($name) failed: $(cat "$WORK/$name-deck.err")"
}

note "ui-type: text outside the key map is set, key-map text goes as keys; its log line has counts, never text (MCP-109/110)"
types type -- --text "café"
types typekeys -- --text "milk 42"
types typeclear -- --text "milk 42" --clear
"$PY" - "$WORK" <<'PY' || die "ui-type assertions failed"
import json, os, sys
def run(name):
    (reply,) = [json.loads(l) for l in open(os.path.join(sys.argv[1], name + ".jsonl")) if l.strip()]
    events = list(map(json.loads, open(os.path.join(sys.argv[1], name + "-events.jsonl"))))
    # The `rx` trace records the request as sent (T13's e2e reads it); the `type` line never the text.
    lines = [e for e in events if e.get("ev") == "type"]
    assert len(lines) == 1 and set(lines[0]) == {"ev", "stream", "characters", "via", "entry", "ts"}, lines
    assert (lines[0]["characters"], lines[0]["via"], lines[0]["entry"]) == \
        (reply["characters"], reply["via"], reply["entry"]), (lines, reply)
    return reply, len([e for e in events if e.get("last_input") == "type"])
cafe, cafe_inputs = run("type")
keys, key_inputs = run("typekeys")
clear, clear_inputs = run("typeclear")
assert cafe == {"t": "ui.type", "stream": 1, "seq": 1, "ok": True, "entry": "inserted",
                "via": "set_text", "characters": 4}, cafe
assert (keys["via"], keys["entry"], keys["characters"], key_inputs) == ("keys", "inserted", 7, 7), (keys, key_inputs)
# The fake's field takes set text, so clear sets it whole: one input.
assert (clear["via"], clear["entry"], clear_inputs) == ("set_text", "replaced", 1), (clear, clear_inputs)
print("  café %s/%s, milk 42 %s/%s, with clear %s/%s" % (
    cafe["via"], cafe["entry"], keys["via"], keys["entry"], clear["via"], clear["entry"]))
PY

note "ui-type --type-refuse not_supported: refused with its code, nothing typed (MCP-109)"
types typerefuse --type-refuse not_supported -- --text "café"
"$PY" - "$WORK/typerefuse.jsonl" "$WORK/typerefuse-events.jsonl" <<'PY' || die "ui-type refuse assertions failed"
import json, sys
(reply,) = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
events = list(map(json.loads, open(sys.argv[2])))
assert reply["ok"] is False and reply["code"] == "not_supported" and "clear: true" in reply["message"], reply
assert [e.get("code") for e in events if e.get("ev") == "type"] == ["not_supported"], events
assert not [e for e in events if e.get("last_input") == "type"], "a refused type typed"
print("  refused %s" % reply["code"])
PY

echo "TREE-KEYS OK"
