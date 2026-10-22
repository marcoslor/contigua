#!/usr/bin/env bash
# check-rules.sh — the AGENTS.md rules a script can see, checked on the lines
# this change adds or changes: the work tree and index against a base ref
# (default main). Legacy lines never fail; --all lists them as counts.
#
#   scripts/check-rules.sh [--base REF] [--all]
#
# Every finding prints `path:line: RULE-ID message`. REVIEW findings (R-SUPP-1,
# R-CHECK-1) need the reviewer's sign-off and do not fail the check. Exit 1 on a
# failure, 0 otherwise. Python 3.9 stdlib only; run from any directory in the
# checkout.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check-rules: not in a git checkout" >&2
    exit 2
}
cd "$ROOT" || exit 2

exec python3 - "$@" <<'PY'
import argparse
import json
import os
import re
import subprocess
import sys

REVIEW_RULES = {"R-SUPP-1", "R-CHECK-1"}
RULE_ORDER = ["R-SWIFT-1", "R-SWIFT-2", "R-SWIFT-3", "R-SWIFT-4", "R-SWIFT-5",
              "R-TEST-1", "R-KEY-1", "R-PRIV-1", "R-SUPP-1", "R-CHECK-1"]
TEXT_EXT = (".swift", ".kt", ".kts", ".java", ".sh", ".json", ".md", ".py")
MISSING = object()

FINDINGS = []      # (path, line, rule, message)
TEXT_CACHE = {}
TABLE_CACHE = []   # one entry once loaded: None (no table) or a set of shortcuts
KEYCONST = []      # one entry once loaded: name -> key code


def die(message, code=2):
    print("check-rules: " + message, file=sys.stderr)
    sys.exit(code)


def git(*args):
    proc = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          encoding="utf-8", errors="replace")
    return proc.returncode, proc.stdout


def read_text(path):
    if path not in TEXT_CACHE:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                TEXT_CACHE[path] = fh.read()
        except OSError:
            TEXT_CACHE[path] = None
    return TEXT_CACHE[path]


def lines_of(text):
    return text.split("\n") if text is not None else []


def add(path, line, rule, message):
    FINDINGS.append((path, line, rule, message))


def split_code(line):
    """(code, comment) of one line; a // inside a string literal is not a comment."""
    in_str = False
    i = 0
    while i < len(line):
        c = line[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif line.startswith("//", i):
            return line[:i], line[i:]
        i += 1
    return line, ""


def escaped(comment, key):
    """True when the comment carries `// <key> <non-empty reason>`, e.g. `// gcd: ...`."""
    return re.search(r"//\s*" + re.escape(key) + r"\s*\S", comment) is not None


# --- changed lines -----------------------------------------------------------

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def parse_diff(text):
    """path -> {"added": {line: text}, "removed": [(line, text)], "hunks": [...]}."""
    files = {}
    cur = None
    hunk = None
    new_no = 0
    for raw in text.split("\n"):
        if raw.startswith("diff --git "):
            cur = files.setdefault(raw.rsplit(" b/", 1)[-1],
                                   {"added": {}, "removed": [], "hunks": []})
            hunk = None
            continue
        if cur is None:
            continue
        m = HUNK.match(raw)
        if m:
            count = int(m.group(2)) if m.group(2) is not None else 1
            # A pure deletion (+c,0) names the line before the gap.
            new_no = int(m.group(1)) + (1 if count == 0 else 0)
            hunk = {"added": [], "removed": []}
            cur["hunks"].append(hunk)
            continue
        if hunk is None:
            continue
        if raw.startswith("+"):
            cur["added"][new_no] = raw[1:]
            hunk["added"].append((new_no, raw[1:]))
            new_no += 1
        elif raw.startswith("-"):
            cur["removed"].append((new_no, raw[1:]))
            hunk["removed"].append((new_no, raw[1:]))
    return files


def whole_file(path):
    lines = lines_of(read_text(path))
    added = {i: t for i, t in enumerate(lines, 1)}
    return {"added": added, "removed": [], "hunks": [
        {"added": sorted(added.items()), "removed": []}]}


def changed_files(base):
    rc, diff = git("diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", base, "--")
    if rc:
        die("git diff against %s failed" % base)
    files = parse_diff(diff)
    _, others = git("ls-files", "--others", "--exclude-standard")
    for path in others.splitlines():
        if path.endswith(TEXT_EXT):
            files[path] = whole_file(path)
    return files


def all_files():
    _, out = git("ls-files")
    files = {}
    for path in out.splitlines():
        if path.startswith(("macos/", "android/", "tools/", "docs/")) \
                and path.endswith(TEXT_EXT) and os.path.isfile(path):
            files[path] = whole_file(path)
    return files


def git_show(base, path):
    rc, out = git("show", "%s:%s" % (base, path))
    return out if rc == 0 else None


# --- code rules --------------------------------------------------------------

SWIFT_SOURCE_RULES = [
    ("R-SWIFT-1", re.compile(r"\bGeometryReader\b"),
     "GeometryReader: lay out from the proposal in a custom Layout", None),
    ("R-SWIFT-2", re.compile(r"\bAnyView\b"),
     "AnyView: use a concrete view type or @ViewBuilder", None),
    ("R-SWIFT-3", re.compile(r"\bDispatchQueue\b|\bDispatchWorkItem\b|\basyncAfter\b"),
     "new GCD: use async/await or an actor (or // gcd: <reason>)", "gcd:"),
    ("R-SWIFT-4", re.compile(r"\btry!|\bas!|\bfatalError\("),
     "force try/cast or fatalError: handle the failure (or // unrecoverable: <reason>)",
     "unrecoverable:"),
    ("R-SWIFT-5", re.compile(r"\bObservableObject\b|@Published\b|@StateObject\b"),
     "ObservableObject, @Published or @StateObject: use @Observable with @MainActor", None),
]


def check_swift_source(path, added):
    if not (path.startswith("macos/Sources/") and path.endswith(".swift")):
        return
    for n, text in sorted(added.items()):
        code, comment = split_code(text)
        for rule, rx, message, esc in SWIFT_SOURCE_RULES:
            if rx.search(code) and not (esc and escaped(comment, esc)):
                add(path, n, rule, message)


TEST_SLEEP = re.compile(r"\bsleep\(|\busleep\(|\bThread\.sleep\b|\bTask\.sleep\b")


def check_swift_tests(path, added):
    if not (path.startswith("macos/Tests/") and path.endswith(".swift")):
        return
    for n, text in sorted(added.items()):
        code, comment = split_code(text)
        if TEST_SLEEP.search(code) and not escaped(comment, "real-time:"):
            add(path, n, "R-TEST-1",
                "wall-clock sleep in a test (or // real-time: <reason>)")


def virtual_lines(lines):
    """1-based line numbers inside a runTest { } block, where delay() is virtual time."""
    virtual = set()
    stack = []
    depth = 0
    for n, text in enumerate(lines, 1):
        code, _ = split_code(text)
        opens = "runTest" in code
        if stack or opens:
            virtual.add(n)
        pending = opens
        for ch in code:
            if ch == "{":
                depth += 1
                if pending:
                    stack.append(depth)
                    pending = False
            elif ch == "}":
                if stack and stack[-1] == depth:
                    stack.pop()
                depth -= 1
    return virtual


def check_kotlin_tests(path, added, lines):
    if not (path.startswith("android/app/src/test/") and path.endswith(".kt")):
        return
    virtual = virtual_lines(lines)
    for n, text in sorted(added.items()):
        code, comment = split_code(text)
        if re.search(r"\bThread\.sleep\(", code) and not escaped(comment, "real-time:"):
            add(path, n, "R-TEST-1", "wall-clock sleep in a test (or // real-time: <reason>)")
        if re.search(r"\bdelay\(", code) and n not in virtual \
                and not escaped(comment, "real-time:"):
            add(path, n, "R-TEST-1",
                "delay() outside runTest: virtual time needs runTest (or // real-time: <reason>)")


# Names that carry a person's data (titles, media, files, pasteboard, messages).
SENSITIVE = {"title", "text", "body", "artist", "album", "filename", "path", "url",
             "clipboard", "pasteboard", "message"}
LOG_CALL = re.compile(r"\.(?:debug|info|notice|warning|error|fault|trace)\(|\bprint\(|"
                      r"\bos_log\(|\bNSLog\(|\bLog\.[vdiwe]\(")
SWIFT_INTERP = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
KT_INTERP = re.compile(r"\$\{([^}]*)\}|\$([A-Za-z_]\w*)")
PRIVATE_ARG = re.compile(r"privacy:\s*\.(?:private|sensitive)\b")
CAMEL = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+")


def sensitive_names(expr):
    names = []
    for ident in re.findall(r"[A-Za-z_]\w*", expr):
        parts = CAMEL.findall(ident)
        last = parts[-1].lower() if parts else ident.lower()
        if ident.lower() in SENSITIVE or last in SENSITIVE:
            names.append(ident)
    return names


def check_privacy(path, added):
    swift = path.endswith(".swift") and (path.startswith("macos/Sources/")
                                        or path.startswith("macos/Tests/"))
    kotlin = path.endswith(".kt") and path.startswith("android/app/src/")
    if not (swift or kotlin):
        return
    for n, text in sorted(added.items()):
        code, comment = split_code(text)
        if not LOG_CALL.search(code) or escaped(comment, "log-ok:"):
            continue
        if swift:
            exprs = [m.group(0)[2:-1] for m in SWIFT_INTERP.finditer(code)]
        else:
            exprs = [m.group(1) or m.group(2) for m in KT_INTERP.finditer(code)]
        for expr in exprs:
            if swift and PRIVATE_ARG.search(expr):
                continue
            names = sensitive_names(expr)
            if names:
                add(path, n, "R-PRIV-1",
                    "log interpolates %s: log an id, count or state, or mark it "
                    "privacy: .private (or // log-ok: <reason>)" % names[0])


SUPPRESSION = re.compile(r"swiftlint:disable|@Suppress\(|@SuppressWarnings\b|#warning\b|"
                         r"swift-format-ignore")


def check_suppressions(path, added):
    if not (path.startswith(("macos/", "android/")) and
            path.endswith((".swift", ".kt", ".kts", ".java"))):
        return
    for n, text in sorted(added.items()):
        if SUPPRESSION.search(text):
            add(path, n, "R-SUPP-1",
                "suppression: needs the reviewer's sign-off (AGENTS.md QA rule)")


# --- R-KEY-1: shortcuts against the docs/UX.md table -------------------------

GLYPH_MODS = {"⌃": "control", "⌥": "option", "⇧": "shift", "⌘": "command"}
GLYPH_ORDER = [("⌃", "control"), ("⌥", "option"), ("⇧", "shift"), ("⌘", "command")]
KEY_ALIAS = {
    "uparrow": "up", "downarrow": "down", "leftarrow": "left", "rightarrow": "right",
    "defaultaction": "return", "cancelaction": "escape", "return": "return",
    "enter": "return", "↩": "return", "escape": "escape", "esc": "escape", "⎋": "escape",
    "↑": "up", "↓": "down", "←": "left", "→": "right", "tab": "tab", "⇥": "tab",
    "delete": "delete", "⌫": "delete", "space": "space", "␣": "space", "−": "-",
}
KEY_GLYPH = {"return": "↩", "escape": "⎋", "up": "↑", "down": "↓", "left": "←",
             "right": "→", "tab": "⇥", "delete": "⌫", "space": "␣"}
KEYNAME = {0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
           11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
           20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
           29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "return",
           37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n",
           46: "m", 47: ".", 48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
           123: "left", 124: "right", 125: "down", 126: "up"}
MOD_TOKEN = re.compile(r"\.(command|shift|option|control)\b")
CONTAINS_MOD = re.compile(r"contains\(\s*\.(command|shift|option|control)\b")
KS_CALL = re.compile(r"\.keyboardShortcut\(([^()]*)\)")
KS_ARGS = re.compile(r'\s*("(?:[^"\\]|\\.)*"|\.\w+)\s*(?:,\s*modifiers:\s*([^)]*?))?\s*$', re.S)
KC_CMP = re.compile(r"\bkeyCode\s*==\s*(?:Self\.)?(\w+)")
KC_CONST = re.compile(r"\b(keyCode\w+)\s*(?::\s*[\w.]+)?\s*=\s*(\d+)\b")


def norm_key(key):
    key = key.lower()
    return KEY_ALIAS.get(key, key)


def parse_ks(args):
    """(modifiers, key) of a .keyboardShortcut(...) argument list, or None."""
    m = KS_ARGS.match(args)
    if not m:
        return None
    token, mods_expr = m.group(1), m.group(2)
    if token in (".defaultAction", ".cancelAction"):
        # KeyboardShortcut constants carry no modifier unless one is given.
        return frozenset(MOD_TOKEN.findall(mods_expr or "")), norm_key(token[1:])
    key = token[1:-1] if token.startswith('"') else token[1:]
    # A KeyEquivalent with no modifiers: means ⌘.
    mods = set(MOD_TOKEN.findall(mods_expr)) if mods_expr is not None else {"command"}
    return frozenset(mods), norm_key(key)


def parse_glyph(text):
    """(modifiers, key) of a table cell such as ⇧⌘C, ⌘− or ↩."""
    mods = {GLYPH_MODS[ch] for ch in text if ch in GLYPH_MODS}
    key = "".join(ch for ch in text if ch not in GLYPH_MODS).strip()
    if not key:
        return None
    return frozenset(mods), norm_key(key)


def load_table():
    if not TABLE_CACHE:
        lines = lines_of(read_text("docs/UX.md"))
        start = next((i for i, t in enumerate(lines) if t.strip() == "## Keyboard shortcuts"),
                     None)
        if start is None:
            TABLE_CACHE.append(None)
        else:
            rows = set()
            for text in lines[start + 1:]:
                if text.startswith("## "):
                    break
                if not text.startswith("|"):
                    continue
                cells = [c.strip() for c in text.strip().strip("|").split("|")]
                if not cells or cells[0] in ("", "Shortcut") or set(cells[0]) <= set("-: "):
                    continue
                shortcut = parse_glyph(cells[0].strip("` "))
                if shortcut:
                    rows.add(shortcut)
            TABLE_CACHE.append(rows)
    return TABLE_CACHE[0]


def keycode_constants():
    if not KEYCONST:
        table = {}
        for root, _, names in os.walk("macos/Sources"):
            for name in names:
                if name.endswith(".swift"):
                    for m in KC_CONST.finditer(read_text(os.path.join(root, name)) or ""):
                        table[m.group(1)] = int(m.group(2))
        KEYCONST.append(table)
    return KEYCONST[0]


def resolve_keycode(token):
    if token.isdigit():
        return int(token)
    return keycode_constants().get(token)


def line_mods(code):
    tail = code
    if "intersection(" in code and "==" in code:
        # flags.intersection([...]) == .command tests exactly the token after ==.
        tail = code[code.rfind("=="):]
    return set(MOD_TOKEN.findall(tail))


def enclosing_mods(codes, idx):
    """Modifiers tested by the if/else-if blocks that enclose line idx."""
    mods = set()
    depth = 0
    for j in range(idx - 1, max(-1, idx - 80), -1):
        code = codes[j]
        for ch in reversed(code):
            if ch == "}":
                depth += 1
            elif ch == "{":
                if depth == 0:
                    mods.update(CONTAINS_MOD.findall(code))
                else:
                    depth -= 1
    return mods


def display(shortcut):
    mods, key = shortcut
    glyphs = "".join(g for g, name in GLYPH_ORDER if name in mods)
    return glyphs + KEY_GLYPH.get(key, key.upper())


def check_shortcuts(path, added, lines):
    if not (path.startswith("macos/Sources/") and path.endswith(".swift")):
        return
    if os.path.basename(path) == "MenuBar.swift":
        return
    codes = [split_code(t)[0] for t in lines]
    joined = "\n".join(codes)
    found = []
    for m in KS_CALL.finditer(joined):
        n = joined.count("\n", 0, m.start()) + 1
        if n in added:
            shortcut = parse_ks(m.group(1))
            if shortcut:
                found.append((n, shortcut))
    for idx, code in enumerate(codes):
        n = idx + 1
        if n not in added:
            continue
        for m in KC_CMP.finditer(code):
            value = resolve_keycode(m.group(1))
            if value is None:
                continue
            mods = line_mods(code) | enclosing_mods(codes, idx)
            if mods:
                found.append((n, (frozenset(mods), KEYNAME.get(value, "keycode %d" % value))))
    if not found:
        return
    table = load_table()
    for n, shortcut in sorted(found, key=lambda item: item[0]):
        if table is None:
            add(path, n, "R-KEY-1",
                "no '## Keyboard shortcuts' table in docs/UX.md to check %s against"
                % display(shortcut))
        elif shortcut not in table:
            add(path, n, "R-KEY-1",
                "shortcut %s is not in the table in docs/UX.md (CONV-MAC-06)"
                % display(shortcut))


# --- R-CHECK-1: weakened checks (REVIEW) -------------------------------------

LIMITS = "macos/scripts/nfr-limits.json"
E2E = "macos/scripts/check-e2e.sh"
NUMBER = re.compile(r"\d+(?:\.\d+)?")


def is_emulator_script(path):
    rest = path[len("tools/emulator/"):]
    return path.startswith("tools/emulator/") and path.endswith(".sh") and "/" not in rest


def load_json(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def check_weakened(path, info, lines, base, base_text_for):
    if path == E2E or is_emulator_script(path):
        for n, text in info["removed"]:
            if re.match(r'\s*(bad|ok) "', text):
                add(path, n, "R-CHECK-1",
                    "removed check line: %s" % text.strip())
        for n, text in sorted(info["added"].items()):
            # A comment that names SKIP is not a skip.
            if re.search(r"\bSKIP\b", text) and not text.lstrip().startswith("#"):
                add(path, n, "R-CHECK-1", "new SKIP: %s" % text.strip())
    if path == LIMITS and base is not None:
        new = load_json("\n".join(lines))
        if new is None:
            add(path, 1, "R-CHECK-1", "limits file is not valid JSON")
            return
        old = load_json(base_text_for() or "{}") or {}
        for key in sorted(set(old) | set(new)):
            before = old.get(key, MISSING)
            after = new.get(key, MISSING)
            if before != after:
                line = next((i for i, t in enumerate(lines, 1) if '"%s"' % key in t), 1)
                add(path, line, "R-CHECK-1", "limit %s changed %s -> %s"
                    % (key, "none" if before is MISSING else json.dumps(before),
                       "none" if after is MISSING else json.dumps(after)))
    if path == "docs/NFR.md":
        for hunk in info["hunks"]:
            before = sorted(NUMBER.findall(" ".join(t for _, t in hunk["removed"])))
            after = sorted(NUMBER.findall(" ".join(t for _, t in hunk["added"])))
            if before and after and before != after and hunk["added"]:
                add(path, hunk["added"][0][0], "R-CHECK-1",
                    "NFR text changed: %s -> %s; limits need the reviewer's sign-off"
                    % (" ".join(before), " ".join(after)))


# --- report ------------------------------------------------------------------

def report(args, file_count):
    fails = [f for f in FINDINGS if f[2] not in REVIEW_RULES]
    reviews = [f for f in FINDINGS if f[2] in REVIEW_RULES]
    if args.all:
        for path, line, rule, message in sorted(FINDINGS):
            tag = " REVIEW" if rule in REVIEW_RULES else ""
            print("%s:%d: %s%s %s" % (path, line, rule, tag, message))
        print("legacy counts (--all: every line as it is, nothing fails here):")
        for rule in RULE_ORDER:
            print("  %-11s %d" % (rule, sum(1 for f in FINDINGS if f[2] == rule)))
        print("check-rules --all: %d findings in %d files" % (len(FINDINGS), file_count))
        return 0
    for path, line, rule, message in sorted(FINDINGS):
        tag = " REVIEW" if rule in REVIEW_RULES else ""
        print("%s:%d: %s%s %s" % (path, line, rule, tag, message))
    tail = ""
    if reviews:
        tail = "; %d REVIEW line%s need%s the reviewer's sign-off" % (
            len(reviews), "" if len(reviews) == 1 else "s", "s" if len(reviews) == 1 else "")
    if fails:
        print("check-rules: FAIL (base %s): %d failure%s%s" % (
            args.base, len(fails), "" if len(fails) == 1 else "s", tail))
        return 1
    print("check-rules: PASS (base %s, %d files checked)%s" % (args.base, file_count, tail))
    return 0


def main():
    parser = argparse.ArgumentParser(prog="check-rules.sh")
    parser.add_argument("--base", default="main", help="ref to compare against (default main)")
    parser.add_argument("--all", action="store_true",
                        help="count every line, legacy included; never fails")
    args = parser.parse_args()
    if not args.all:
        rc, _ = git("rev-parse", "--verify", "--quiet", args.base + "^{commit}")
        if rc:
            die("base '%s' not found; pass --base REF" % args.base)
    base = None if args.all else args.base
    files = all_files() if args.all else changed_files(args.base)
    for path in sorted(files):
        info = files[path]
        if not info["added"] and not info["removed"]:
            continue
        lines = lines_of(read_text(path))
        added = info["added"]
        check_swift_source(path, added)
        check_swift_tests(path, added)
        check_kotlin_tests(path, added, lines)
        check_privacy(path, added)
        check_suppressions(path, added)
        check_shortcuts(path, added, lines)
        check_weakened(path, info, lines, base,
                       lambda p=path: git_show(base, p) if base else None)
    return report(args, len(files))


if __name__ == "__main__":
    sys.exit(main())
PY
