#!/bin/bash
# The fake phone's ui.tree keys (MCP-71), heading (MCP-72) and covered (MCP-73):
# docs/PROTOCOL.md "UI tree" item 9. Run alone, or from test_selfcheck.sh.
#
# 1. The fixed tree: two reads give every row the same `k`, 1…4.
# 2. --tree-variant: a heading row, a button covered by the banner's `k`, and a
#    second read without k 2, the other rows keeping theirs.
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
    local name="$1"
    "$PY" "$HERE/deckctl.py" --host 127.0.0.1 --port "$PORT" --state "$WORK/$name-deck.json" \
        --pair ui-tree --reads 2 > "$WORK/$name.jsonl" 2>"$WORK/$name-deck.err" \
        || die "ui-tree ($name) failed: $(cat "$WORK/$name-deck.err")"
}

note "ui-tree: the fixed tree keeps k 1…4 across two reads (MCP-71)"
start fixed
reads fixed
"$PY" - "$WORK/fixed.jsonl" <<'PY' || die "fixed tree key assertions failed"
import json, sys
one, two = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
keys = lambda r: [n.get("k") for n in r["nodes"]]
assert keys(one) == [1, 2, 3, 4], keys(one)
assert keys(two) == keys(one), (keys(one), keys(two))
assert all("ref" not in n for n in one["nodes"]), "the phone sent a ref"
print("  keys %s, %s" % (keys(one), keys(two)))
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

echo "TREE-KEYS OK"
