# Automation server (MCP)

An AI agent on this Mac (any MCP client) drives the connected
phone through Contigua: see what a window shows, tap/type/swipe, open
apps, send links and files, read the phone's state. Everything stays local, is
off by default, and is visible while it is in use.

The behaviour is specified in [specs/mcp.md](../specs/mcp.md) (`MCP-n`); this
page is the contract a client sees: the tools, their arguments, their exact
descriptions and their answer shapes. The contract below is the target of epic
#171; `docs/design/mcp-plan.md` is the order it ships in, and a row of the spec
marked **target** has not shipped yet. Until each task lands, the code answers
as the previous revision of this page described (see "What breaks"), with PR
#162's fixes: refs the Mac issues as `s<snapshot>e<row>`, `size: [w, h]` for
the pixel space of `box`, a display's Android windows as `layers`/`l`, and an
off-screen node as `off: true` with no `at`. Every task starts from `main`
after #162 has merged.

## Transport

The app listens on a UNIX socket in the profile's Application Support folder:

```
~/Library/Application Support/Contigua/mcp.sock          (default profile)
~/Library/Application Support/Contigua-<profile>/mcp.sock (any other profile)
```

The folder is `0700` and the socket `0600`; the app checks the connecting
process's uid with `getpeereid(2)` and closes the connection unless it is our
own uid. There is no TCP listener and no network exposure (MCP-1, MCP-2).

A small stdio shim, `contigua-mcp`, ships inside the app as
`Contents/Helpers/contigua-mcp` (compiled by `bundle.sh` with `swiftc`, like
the Dock shim, and codesigned with the bundle). It relays bytes between its
stdin/stdout and the socket without interpreting them. `--profile NAME` chooses
the socket; without it the default profile is used.

The shim's exits are part of the contract, because a harness that shells out
reads only them (MCP-11, MCP-12):

| Situation | stdout | stderr | exit |
|---|---|---|---|
| `--help` / `-h` | usage | — | 0 |
| unknown argument, bad `--profile` | — | the reason, then usage | 1 |
| socket missing or refused (setting off, stale file) | — | `Turn on Settings › Automation in Contigua` | 1 |
| stdin closed; the app answered every relayed request (or none was sent) | the replies | — | 0 |
| stdin closed; requests were relayed and the connection ended with no byte back | — | `contigua-mcp: the app closed the connection with no reply` | 1 |
| the app closed the connection (setting off, Disconnect agent, quit) | what had arrived | — | 0 |

On stdin EOF the shim half-closes its write side and keeps relaying until the
app closes; the app, seeing EOF, finishes the requests it has read, writes
every reply, then closes (MCP-10). So
`printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n' | contigua-mcp`
prints the `initialize` reply and exits 0.

The MCP client configuration is:

```json
{"command": "/Applications/Contigua.app/Contents/Helpers/contigua-mcp"}
```

Settings › Automation shows this snippet with a Copy button (with
`"args": ["--profile", "NAME"]` added for a non-default profile).

## Gate and visibility

Settings › Automation › "Allow AI agents to control your phone" is off by
default. While it is off the socket does not exist and the shim's hint above is
the only thing an agent sees.

While at least one client is connected, the menu bar extra shows a small
indicator and the menu has "Disconnect agent", which closes every client. The
toggle also stops the server immediately. The app logs one line per tool call:
tool name, duration, outcome code and window id only (MCP-14). Arguments, typed
text, labels, packages, URLs, file names, titles and pixels are never logged,
and neither is the client's `clientInfo` name.

## Protocol

MCP revision `2025-06-18`, JSON-RPC 2.0, newline-delimited JSON over the socket.
One request or notification per line; a line longer than 1 MiB is refused.
`initialize`, `ping`, `tools/list` and `tools/call` are implemented;
notifications (no `id`) get no reply. The implementation is hand-written in a
pure `MCPCore` (parse, dispatch, schemas, argument validation) with unit tests;
no third-party MCP SDK is used. Up to four clients may be connected at once.

`initialize` answers with protocol version `2025-06-18`, `tools: {}` and
`serverInfo` naming Contigua. JSON-RPC errors are only for protocol faults:
malformed JSON (`-32700`), an invalid request or oversized line (`-32600`), an
unknown method (`-32601`), and an unknown tool or arguments that do not match
the tool's schema (`-32602`) (MCP-4).

**Answers (MCP-5).** A successful `tools/call` result is

```json
{"content": [{"type": "text", "text": "<the answer, serialised>"}],
 "structuredContent": { "…the answer object…" },
 "isError": false}
```

with one extra `{"type": "image", "mimeType": "image/png", "data": …}` block
first for `screenshot`. `tools/list` declares each tool's `outputSchema`, the
answer shapes below.

**Errors (MCP-6).** A failure of the moment (no phone, a window that closed, a
ref whose element is gone) is a tool result with `isError: true` and one text
block holding

```json
{"error": {"code": "no_window",
           "message": "Window 4 closed 3 s ago: the app exited. Call list_windows to see what is open.",
           "window": 4,
           "closed": {"reason": "app_exited", "closedBy": "phone", "closedAgoMs": 3120}}}
```

`code` is closed — a client may switch on it — and `message` is one sentence
that names the next step. Extra fields depend on the code:

| code | means | sentence (`<…>` filled in) | extra fields |
|---|---|---|---|
| `no_phone` | no phone is paired or in use | No phone is paired with Contigua. Pair one in Contigua's Settings, then try again. — or, with phones paired and none in use: No phone is in use: <n> phones are paired and none is connected. Connect one in Contigua, then call phone_status. | — |
| `phone_offline` | the phone in use is connecting, reconnecting or offline; nothing was sent or queued | <phone> is not connected. Wait until phone_status says connected, then try again. | — |
| `no_window` | the window is not open | No window <id>. Call list_windows to see what is open. — or, when it closed recently: Window <id> closed <n> s ago: <reason sentence>. Call list_windows to see what is open. | `window`, `closed` when it closed recently (MCP-53) |
| `not_ready` | the window is `opening` or `stalled`, or the app list has not arrived | Window <id> is <opening: still opening \| stalled: not responding>. Call wait on it, then try again. — or: The phone's app list has not arrived yet; try again in a few seconds. — or, for `ui_tree` on a display with nothing to read yet: Window <id> has nothing on screen to read yet: its app may still be opening. Try again in a moment. | `window`, `state` |
| `stale_ref` | with S1's refs: the ref is from a read that is not the window's latest; from T10 on: the ref's element is gone or not visible | S1 (#162's words, MCP-86): <ref> is from snapshot s<n>, but the window is at s<m>. Call ui_tree again. — a ref the latest read never had: <ref> is not in the window's latest tree (s<m>). Use a ref from that tree, or call ui_tree again. — no read since the window opened or the phone reconnected: <ref> names nothing: this window has had no tree read since it opened or since the phone reconnected. Call ui_tree first. — from T10 on: <ref> is no longer on window <id>; its latest tree is snapshot <m>. Use a ref from snapshot <m>, or call ui_tree. | `window`, `ref`, `snapshot` (the latest) |
| `off_screen` | the ref's node is off the display (F9, MCP-106) | <ref> is off screen: scroll it into view and read the tree again. | `window`, `ref`, `in` (its scrollable's ref) when known |
| `covered` | the ref's element is under another one | Element <ref> is covered by <cover ref \| another window>. Close or move what covers it, or tap the cover. | `window`, `ref`, `coveredBy` (a ref or `"window"`) |
| `no_field` | `type_text` needs a focused field and none has input focus (MCP-109) | Window <id> has no focused text field. Tap the field first. | `window` |
| `not_found` | no app matches | No app on the phone matches "<query>". Call list_apps and pass its package as app. (T9: "Call list_apps with a query to find it.") | — |
| `ambiguous` | several apps match | Several apps match "<query>". Pass one of these packages as app. — or, where no list is at hand: Several apps match "<query>". Call list_apps and pass one package as app. (T9: "…with a query to see them.") | `matches: [{label, package}]` (empty in the second form) |
| `too_many_windows` | the phone's window cap is reached | The phone allows <n> app windows at once. Close one with close_window, then try again. | `maxWindows` |
| `bad_url` | LinkPolicy refused the URL | That link can't be opened: only http, https, geo, tel and mailto links up to 8 KiB are allowed. | — |
| `bad_file` | the path is missing, unreadable, not a regular file or over the cap | That file can't be sent: it must be an absolute path to a readable regular file of at most <cap>. | — |
| `no_frame` | no keyframe arrived within 2 s | Window <id> is <state word>: no new picture arrived in 2 s. Use ui_tree, or try again. | `window`, `state` |
| `not_supported` | this phone, or the focused field, cannot do it (no tree, no foreground read, a field that takes no set text) | <phone> can't <read this window's accessibility tree \| …>. — or, for `type_text`: The focused field on window <id> can't take this text: type only letters, digits and symbols a keyboard has, or pass clear: true to replace what is there. | `window` for a field |
| `timeout` | the phone did not answer within the call's bound | <phone> did not answer in time. Try again; if it keeps failing, check phone_status. | — |
| `failed` | anything else, and `close_window` on the person's window without `force` | The phone's or the app's own sentence. — or: Window <id> was opened by the person. Pass force: true to close it anyway. | `window` when one is named |

The query, the reason and the phone's name in a sentence are on-screen or
user content: they live in the tool result only, never in a log line (MCP-14).

## Design rules

The contract holds five rules; each tool below follows them.

1. **One envelope for every action.** `tap`, `swipe`, `type_text` and
   `press_key` answer the same object: what was pressed, the tree and frame it
   acted on, whether the screen settled, the window's state and freshness after
   it, and (by default) the new tree. `open_app` and `send_link` answer the same
   envelope with the window they opened in place of `did`. There is no `ok`:
   an answer is a fact the phone reported, never "the frames were queued".
2. **Every screen answer says how fresh it is.** `frame: {seq, ageMs}` — a
   per-window count of the frames the Mac received and the age of the newest —
   and `state`, on every answer that reflects a window. Two answers about one
   window compare by `seq`.
3. **Closed codes.** Errors, settle states, window states, openers and close
   reasons are closed sets, listed here and in the spec.
4. **Nothing to compute.** Tap points are `at` in the space `tap` takes; refs
   name elements (and, from T10, survive re-reads); `openedBy` is already
   relative to the caller; every pixel space is one `size: [w, h]`; a
   screenshot crops to a ref; `swipe` takes a direction; an off-screen match
   names the scrollable that holds it. A model never scales, diffs or counts
   to act.
5. **Fewer tools, clear arguments.** 14 tools for an agent (`long_press` folded
   into `tap`, `wait` added); `input_probe`, a measurement tool, is listed only
   when the app runs with `--mcp-dev-tools` (MCP-99).

## Tools

The descriptions are the `tools/list` text, word for word (MCP-7), as they
stand once every task has shipped. Until T10 ships stable refs, the `tap` and
`ui_tree` descriptions carry S1's rule instead of the cross-read sentence: "A
ref works only from the window's latest tree; an older one is refused."
(MCP-71). Coordinates
are `0..1` of the window (the same space TOUCH frames carry). `window` is an id
from `list_windows`, `open_app` or `send_link`.

Two arguments recur on every tool that acts or opens:

- `wait`: `"settle"` (default) or `"none"`. Settle waits, after the action,
  until the window's accessibility tree has not changed for 300 ms, at most 2 s
  (MCP-81).
- `observe`: `"tree"` (the default), `"text"` or `"none"`: what screen to
  return after the settle (MCP-82). `"text"` is taken once T9 ships the text
  view (MCP-74); until then the argument is `"tree"` or `"none"`.

`open_app` and `send_link` also take `shape`: `"phone"` (the default for a new
window) or `"window"` (MCP-100, "A window an agent opens" below).

| tool | arguments | description |
|---|---|---|
| `phone_status` | — | The phone in use: connected or not, its name, battery, screen and lock state, the app in front on the phone's own screen, and how many windows are open. App windows take input whether or not the phone is locked. |
| `list_apps` | `query`?, `limit`? (1–500, default 20 with a query) | Apps on the phone that can be opened, as label and package. Pass query to get only the apps whose label or package contains it, best matches first. |
| `open_app` | `app`, `newWindow`?, `shape`? (`"phone"`/`"window"`), `wait`?, `observe`? | Open a phone app in a window on this Mac, or bring its window to the front if it has one, and return that window and the screen it shows. The app opens on whatever screen it last showed. A new window has the phone's shape unless shape is "window"; a window brought to the front keeps its shape, and size says what it is. newWindow: true opens a second window of an app that allows it. |
| `send_link` | `url`, `shape`?, `wait`?, `observe`? | Open a link (http, https, geo, tel or mailto) on the phone in a new window, in the app the phone picks, and return that window and the screen it shows. The window has the phone's shape unless shape is "window". |
| `send_file` | `path` | Copy one file from this Mac to the phone's Download/Contigua folder and wait until the phone has it. Nothing on the phone is replaced or removed. |
| `list_windows` | — | Every open window: its id, what it shows, who opened it (you, another agent, the person or the app itself), its state and how fresh its picture is, and the windows that closed in the last 10 minutes with the reason. A window id is a handle, never reused for another window while Contigua runs. |
| `close_window` | `window`, `force`? | Close a window. On the phone this ends the app's screen on that window's own display; the app is not uninstalled and its data (a browser's tabs, a document) stays. A window the person opened needs force: true. |
| `screenshot` | `window`, `ref`?, `wait`? | A PNG of the window, from a frame the phone sends after this call (never an older one), longest side at most 1280 px. ui_tree's box values are in the window's pixels (size), not the image's. Pass ref to get only that element. |
| `ui_tree` | `window`, `format`? (`"tree"`/`"text"`), `find`?, `wait`? (default `"none"`) | What the window shows, as accessibility nodes in reading order: text, role, view id, states, a tap point (at, 0..1) and a ref for tap; box is in the display's pixels (size). A ref names one element for as long as it is on screen, across reads; a ref whose element is gone is refused. Only what is on screen is listed: a list says how many items it hides before and after; find also searches those and names the list to swipe. A field showing its hint has hint: true and no text. loading: true means the screen is still loading. format: "text" gives one line per label; find keeps only the nodes whose text contains it. Exact, and cheaper than a screenshot for finding what to press. |
| `wait` | `window`, one of `ms` (1–30000), `text` (+ `gone`?) or `settle: true`; `timeoutMs`? (≤ 30000, default 10000), `observe`? | Wait on a window: for ms milliseconds, until text appears on it (with gone: true, until it disappears), or with settle: true until it stops changing and nothing on it is loading, at most timeoutMs; if timeoutMs ends first, reason says whether it was still loading. Use this instead of sleeping or re-reading the tree as a clock. |
| `tap` | `window`, `ref` or `x`+`y`, `holdMs`? (1–3000), `wait`?, `observe`? | Tap an element by its ref from ui_tree (preferred), or a point x, y (0..1 of the window); holdMs makes it a long press. A ref names one element for as long as it is on screen, across reads; a ref whose element is gone, off screen or covered is refused and nothing is pressed. The answer names what was pressed (its role and label). By default the call waits for the screen to settle and returns the new tree. |
| `swipe` | `window`, `direction` (+ `ref`?) or `x1`,`y1`,`x2`,`y2`; `ms`? (1–2000, default 300), `wait`?, `observe`? | Swipe in a window. direction is the way the finger moves (swipe up to see what is further down), through the centre of ref's element or of the window; or give the points x1,y1 to x2,y2. By default the call waits for the screen to settle and returns the new tree. |
| `type_text` | `window`, `text` (≤ 2000), `clear`?, `submit`?, `wait`?, `observe`? | Type text into the window's focused field at the cursor: what is there stays, and entry in the answer says inserted. clear: true replaces the field's text instead (entry: replaced); submit: true presses Enter after. The phone's clipboard is never used. Tap the field first if nothing is focused. |
| `press_key` | `window`, `key`, `wait`?, `observe`? | Press one key in a window. back, home and recents are the phone's navigation; home and recents act only in the Phone Mirror. back on an app's last screen closes the window, and the answer says so. The rest (enter, delete, tab, escape, up, down, left, right) are keys. |
| `input_probe` | `window`, `x`, `y`, `w`?, `h`? (0.05–1) | Measurement: tap a point and return the milliseconds until the window's picture changed (input-to-photon), or null after 2 s. Not for driving an app. (Listed only when Contigua runs with --mcp-dev-tools.) |

## Answer shapes

Field order is not significant. `?` marks a field that may be absent; every
closed token is listed in the spec row cited.

### The act envelope (`tap`, `swipe`, `type_text`, `press_key`; MCP-80)

```json
{
  "window": 3,
  "did": {"action": "tap", "ref": "e12", "at": [0.5, 0.651],
          "box": [144, 1060, 1296, 1140],
          "node": {"role": "Button", "text": "Continue"}},
  "on": {"snapshot": 7, "frame": 1302},
  "settle": {"state": "settled", "waitedMs": 412},
  "state": "live",
  "frame": {"seq": 1340, "ageMs": 35},
  "alsoActed": ["person"],
  "tree": {"…": "the ui_tree answer, read after the settle"}
}
```

- `did` by action:
  - `tap` by ref: `{action: "tap", ref, at, box, node: {role, text?, desc?}, holdMs?}` — `at` and `box` are where the phone pressed, now (MCP-86), and `node` is the node as the phone read it at the press, so a button that relabelled itself is named by its new label (MCP-108; with S1's refs, from the tree the ref came from).
  - `tap` by point: `{action: "tap", at, holdMs?, hit?: {ref, role, text?, desc?}}` — `hit` is the node under the point in the tree `on.snapshot` names (MCP-87).
  - `swipe`: `{action: "swipe", from: [x, y], to: [x, y], ms, direction?, ref?}`.
  - `type_text`: `{action: "type", characters: 2, clear: false, submit: false, entry: "inserted", via: "keys"}` — never the text. `entry`: `inserted` (at the cursor; what was there stays), `replaced` (`clear`), `unknown` (keys sent with no focused field seen); `via`: `keys` or `set_text` (MCP-109).
  - `press_key`: `{action: "key", key: "back"}`; `ignored: true` for `home`/`recents` in an app window, where they send nothing (MCP-94).
- `on.snapshot` is the tree the ref (or `hit`) came from, null when none was read; `on.frame` the frame `seq` when the input was sent.
- `settle.state`: `settled`, `still_changing`, `not_waited`, `not_ready`, `unavailable`, `window_closed`, `interrupted` (MCP-81). `waitedMs` is absent for `not_waited`. A `still_changing` carries `reason`: `changes` (the screen kept changing) or `loading` (it went quiet but still showed a spinner or an empty web page, MCP-107). A call its deadline ended (MCP-8) says `reason: "deadline"`: `not_waited` when no settle was sent yet, else `still_changing` with `waitedMs` counted from the settle's send. A settle that finds the display gone answers `window_closed`, holding the answer up to 500 ms for the phone's close reason; a window the Mac closed itself answers `closed: {reason: "closed", closedBy: "person" | "agent"}` until T7's ledger names the connection.
- `state`: `opening`, `live`, `paused`, `stalled`, `offline`, `closed` (MCP-21).
- `alsoActed?`: `person`, `another_agent` — other input that reached the window during this call (MCP-84).
- `closed?`: when the window closed during the call, `{reason, closedBy}` (MCP-83); then `state: "closed"`, `settle.state: "window_closed"`, and no `tree`.
- `tree?` (observe `tree`), `text?` (observe `text`), `treeError?` (a code, when that read failed after the action: MCP-82).

A `press_key back` that ends the app:

```json
{"window": 3, "did": {"action": "key", "key": "back"},
 "on": {"snapshot": 9, "frame": 2210},
 "settle": {"state": "window_closed"},
 "state": "closed", "frame": {"seq": 2214, "ageMs": 170},
 "closed": {"reason": "app_exited", "closedBy": "phone"}}
```

### `open_app` and `send_link` (MCP-41, MCP-43)

```json
{"window": 5, "kind": "app", "package": "com.google.android.calculator",
 "label": "Calculator", "opened": "new", "openedBy": "you", "size": [590, 1280],
 "settle": {"state": "settled", "waitedMs": 640},
 "state": "live", "frame": {"seq": 14, "ageMs": 22},
 "tree": {"…": "…"}}
```

`kind` is `app` for `open_app` and `link` for `send_link`; a link window's
`package` and `label` are null until the phone names the app it opened in
(`window.title`), and the answer waits for that within the open bound.
`opened` is `new` or `raised`; a raised window keeps its first `openedBy` and
its shape. `size` is the window's display pixels, the space of `ui_tree`'s
`box` (for an app window, equal to its stream: what `shape` gave a new window,
what a raised one already had; MCP-50, MCP-100, MCP-101). An
open with no first frame at the 10 s bound answers `state: "opening"` and
`settle: {"state": "not_ready"}` — the window exists; call `wait` or
`ui_tree` on it.

### `ui_tree` (MCP-70…75)

```json
{"window": 3, "displayId": 64, "snapshot": 8, "state": "live",
 "frame": {"seq": 1340, "ageMs": 35}, "truncated": false, "size": [1080, 2364],
 "omitted": 41,
 "layers": [{"i": 0, "title": "Wikipedia", "type": "app", "active": true}],
 "nodes": [
   {"i": 0, "ref": "e3", "role": "TextView", "text": "Ada Lovelace", "heading": true,
    "box": [48, 420, 1032, 520], "at": [0.5, 0.196]},
   {"i": 1, "ref": "e7", "role": "EditText", "hint": true, "hintText": "Search Wikipedia",
    "edit": true, "focus": true, "box": [48, 160, 1032, 260], "at": [0.5, 0.089]},
   {"i": 2, "ref": "e20", "role": "RecyclerView", "scroll": true, "hidden": [0, 41],
    "box": [0, 560, 1080, 2364], "at": [0.5, 0.618]},
   {"i": 3, "ref": "e9", "p": 2, "role": "Button", "text": "Read more", "click": true,
    "box": [48, 2210, 1032, 2290], "at": [0.5, 0.934], "covered": "e31"}
 ]}
```

Rows are WIN-79's as #162 leaves them (`i`, `ref`, `p`, `l`, `role`, `text`,
`desc`, `id`, `box`, `at`, `off`, `click`, `edit`, `scroll`, `check`, `sel`,
`focus`, `disabled`, `pwd`), plus `heading` and `covered` (MCP-72, MCP-73),
`loading` (MCP-103), `hint` and `hintText` (MCP-104) and a scrollable's
`hidden: [before, after]` (MCP-106). `size` is the pixel space of `box`; `at` is
TOUCH's 0..1 input space. A layer is one of the display's Android windows;
`active` marks the one with input focus, and `focus` is only ever on a node of
that layer (MCP-105). `omitted` counts the off-screen nodes left out;
`loading: true` on the answer appears while any node has it. With `find`,
`nodes` holds only the matches, off-screen ones included as `off: true` with no
`at` and `in` (the scrollable to swipe), and the answer adds `"matched": 1,
"total": 87`.

Refs by stage: once #162 has merged a ref is `s<snapshot>e<row>` and works only
from the window's latest tree; from T10 a ref is `e<k>`, the phone's key for the
node, and works for as long as the node is on screen (MCP-71). The example shows
the T10 form.

`format: "text"`:

```json
{"window": 3, "snapshot": 8, "state": "live", "frame": {"seq": 1340, "ageMs": 35},
 "format": "text",
 "text": "# Ada Lovelace\nSearch Wikipedia (hint) [e7 EditText edit focus]\n[e20 RecyclerView scroll, 0 before, 41 after]\nRead more [e9 Button]"}
```

### `screenshot` (MCP-60…64)

Content: the PNG block, then the text block of

```json
{"window": 3, "state": "live", "frame": {"seq": 1341, "ageMs": 12},
 "image": [1280, 740],
 "size": [2860, 1654],
 "crop": [130, 1052, 1310, 1148],
 "blank": true,
 "settle": {"state": "settled", "waitedMs": 300}}
```

`image` is the PNG's pixels and `size` the display's pixels for the window
(the space of `box`, MCP-50): for the Phone Mirror that is the phone's screen
(say 1080×2340), larger than its stream (592×1280). `crop` is in the same
display pixels, the ref's `box` plus 8 on each side, clamped to `size`; the
Mac scales it by frame/`size` to cut the decoded frame. `crop` only with `ref`, `blank` only when true, `settle` only with
`wait: "settle"`.

### `wait` (MCP-96, MCP-97, MCP-111)

```json
{"window": 3, "waitedMs": 5004, "until": "met", "match": {"ref": "e14", "text": "00:05.02"},
 "state": "live", "frame": {"seq": 4410, "ageMs": 8}, "tree": {"…": "…"}}
```

`until` is `met` or `timeout`, absent for a plain `ms` wait; `match` only when
met on `text` (none with `gone: true`), the first node whose text or
description contains it ignoring case and accents, with its own text; `reason` (`loading` or `changes`) only
for a `settle: true` wait that timed out. `tree` is the `observe` read: after
the clock or the settle, or the poll's last read for `text`; `treeError` when
that read failed. The tree is read at most every 500 ms, each read in the
phone's read queue (MCP-9) and bounded by the call (MCP-8): `ms` + 3 s, or
`timeoutMs` + 3 s for `text` and `settle`. A `busy` read is retried at the next
poll; a wait that ends on one fails `busy`. A settle longer than the wire's
10 s is a chain of settles, each its own turn in the queue. With none of `ms`,
`text` or `settle` the call is `-32602` "wait needs ms, text or settle".

### `list_windows` (MCP-50…52)

```json
{"windows": [
   {"id": 3, "kind": "app", "package": "com.google.android.calculator", "label": "Calculator",
    "title": "Calculator", "openedBy": "you", "openedAgoMs": 42000, "state": "live",
    "frame": {"seq": 1340, "ageMs": 35}, "size": [590, 1280]},
   {"id": 4, "kind": "app", "package": "com.example.shop", "label": "Shop",
    "title": null, "openedBy": "person", "openedAgoMs": 9000, "state": "paused",
    "frame": {"seq": 220, "ageMs": 8800}, "size": [2860, 1654]}],
 "recentlyClosed": [
   {"id": 2, "kind": "link", "package": "org.example.browser", "reason": "closed",
    "closedBy": "another_agent", "closedAgoMs": 5100}]}
```

A window stays open when the client that opened it disconnects, and keeps its
opener (MCP-102). `kind`: `app`, `link`, `handoff`, `mirror`. `openedBy`: `you`, `another_agent`,
`person`, `app`. `reason`: `closed`, `app_exited`, `moved_to_phone`,
`phone_closed`, `open_failed`, `phone_switched`; `closedBy`: `you`,
`another_agent`, `person`, `phone`.

### The rest

```json
// phone_status (MCP-30…32)
{"connected": true, "name": "My phone", "battery": 81, "charging": false,
 "screen": "off", "locked": true, "lockSource": "keyguard_listener", "lockChangedAgoMs": 360000,
 "input": "App windows take input whether or not the phone is locked; the Phone Mirror shows the lock screen until the person unlocks it.",
 "foreground": {"package": "org.example.browser", "label": "Browser"},
 "windows": 2, "maxWindows": 4}

// list_apps (MCP-33, MCP-34)
{"apps": [{"label": "Calculator", "package": "com.google.android.calculator"}], "total": 1}

// send_file (MCP-44)
{"bytes": 1048576, "state": "delivered"}

// close_window (MCP-54)
{"window": 3, "closed": {"reason": "closed", "closedBy": "you"}}

// input_probe (MCP-99, unchanged; listed only with --mcp-dev-tools)
{"window": 3, "frames": 4, "sent_ms": 1823344.2, "changed_ms": 48.1}
```

`phone_status` with no phone: `{"connected": false, "name": null, "battery":
null, "charging": false, "screen": null, "locked": null, "foreground": null,
"windows": 0}`. `foregroundError` (`not_supported`, `timeout`) appears when
`foreground` is null because the phone could not answer.

## Freshness

`frame.seq` counts the access units the Mac received for that window (a whole
`VIDEO_FRAME` or a reassembled chunk set), from 1, never reset while the window
lives; `frame.ageMs` is the time since the newest arrived (MCP-20). It is the
Mac's count: the wire has no frame id, and needs none, because the Mac is the
one place every answer is made. A live stream sends a frame at least every
500 ms (repeat-previous, PROTOCOL.md "Video rules"), so `ageMs` above ~1 s
means the window is `paused`, `stalled` or `offline`, and `state` says which.

**Why round 1's screenshots were stale (#165).** A window the person covered or
minimised pauses its stream (`StreamPause`, `window.pause`): the phone stops
encoding, and `copyDisplayedFrame()` kept answering the layer's last buffer for
minutes while `ui_tree`, which reads the phone directly, stayed current. Two
changes close it:

- **The agent hold (MCP-22).** A window an agent called a tool on in the last
  15 s does not pause, whether it is covered or minimised. The person sees nothing change; the phone keeps encoding
  that one window while it is being driven.
- **A screenshot is a frame from after the call (MCP-60).** The Mac asks for a
  keyframe and decodes the first one that arrives with the window's snapshot
  decoder (`beginFrameSnapshot`), stamped with its `seq`. The display layer's
  buffer is never the answer, so a screenshot cannot be older than the call.
  The decoder is one per window, shared with Live Text's freeze: each begin
  gets a token, a cancel acts only on its own token, and a newer begin
  displaces the older request, which fails at once.
  The cost is one keyframe per screenshot. A window that sends none in 2 s
  fails `no_frame` with its state.

A black first frame of a new window (the app had not drawn) is answered
`blank: true`; with `wait: "settle"` the screenshot waits for the tree to settle
first.

## Settle and observe

Settle is the phone's answer to "has this screen stopped changing", measured
where the screen lives: the phone watches the accessibility events of the
window's display and answers when none came for 300 ms, or at 2 s
(`ui.settle`, PROTOCOL.md "UI tree" §7). The phone receives the input frames
and the settle request on the same reliable, ordered lane, so the watch starts
after the input reached it. Only content changes count (a window's content
or state, the window list, a text change, a scroll); focus, selection, click,
hover and announcement events do not (MCP-107). When 300 ms pass quietly the
phone also looks for a **loading signal** before it says `settled`: a visible
indeterminate progress bar, or a visible WebView with no content yet
(MCP-103). While one shows, the watch goes on, checking again after every
quiet period. This is round 1's skeleton tree — a bare WebView, a sheet with
none of its chips — read right after navigating with nothing saying it was
still loading. A watch the 2 s cap ends answers `still_changing` with
`reason: "loading"` (quiet, but still loading) or `"changes"` (it kept
changing), and the tree it returns carries `loading: true` on the spinner or
the empty page and on the answer.

`settled` means *no accessibility change for 300 ms and nothing loading*, not
*the app finished*: a sheet that fills in without a spinner a second later can
still change, and a canvas, a video or a map can move without changing a node.
A screen that never stops (a running stopwatch) answers `still_changing` at
2 s, which is not an error; pass `wait: "none"` there.

The Mac's side is one pure machine per call, `MCPActMachine` (spec "One act
call"): queue on the window → press or send → settle → read → answer, with the
window closing, the link dropping, the deadline and the client leaving as
events from every state. Input calls on one window run one at a time across
clients (MCP-84), and `ui.*` requests to the phone one at a time per phone
(MCP-9), so two agents never see the phone's `busy`.

`observe: "tree"` folds the read every round-1 run made after every action into
the same call. With stable refs (below) the tree it returns is the one the next
`tap` uses: read once, then act-and-observe.

## Windows and who opened them

The Mac keeps a ledger per window (MCP-50…53): its kind, its opener and when,
its state, and — after it closes — why and by whom, for the last 16 closes or
10 minutes. `openedBy` and `closedBy` are relative to the asking connection
(`you` vs `another_agent`), so two agents sharing the phone each see their own
windows as `you` without comparing ids. A window id that is gone answers
`no_window` with its close record, so "the app exited", "the person closed it",
"another agent closed it" and "the phone switched" are four different answers
instead of one sentence.

Close reasons map from the wire as follows: `window.closed` `app_exited` →
`app_exited`, `moved_to_phone` → `moved_to_phone`, `requested`/`error` →
`phone_closed` (closedBy `phone`); the Mac's own `window.close` → `closed` with
the closer that asked (an MCP connection, or `person` for ⌘W, the close light,
Close All); an open the phone refused → `open_failed`; Use This Phone →
`phone_switched`.

## A window an agent opens (MCP-100, MCP-101)

A person's new window is 900×600 pt, landscape, at the Mac's full backing
resolution (WIN-5): to the app, a 900×600 dp tablet. Most phone apps do not
adapt to that shape — a shopping app shows its phone layout stretched, with
sheets and bars in odd places — and the stream carries pixels the agent never
sees, because a screenshot is capped at 1280 px. So a window an MCP client
opens (a new window, not a raise) takes `shape: "phone"` by default:

- **The phone's shape.** Portrait, at the aspect of the phone's own screen
  (`welcome.device.screen`), and the phone's own dp width, so the app lays out
  as it does in the person's hand.
- **A small stream.** The long side is at most 1280 px, the screenshot cap,
  each side rounded down to the encoder's alignment; the dpi is
  `round(160 × width ÷ phoneDpWidth)`. A 1080×2340 phone at 450 dpi is
  384×832 dp, so its windows stream at 590×1280 px and 246 dpi (576×1280 at
  240 dpi on an encoder that aligns to 16).
- **Points.** The stream area is the phone's dp size in points (384×832 pt),
  shrunk with its aspect kept to fit the screen's visible frame with the
  style's chrome. The layer scales the stream to it.
- **The person's action wins.** A resize (a drag, Zoom, tiling, full screen) or
  a density change makes it an ordinary window for good: WIN-5, WIN-6 and
  WIN-13 apply from then on. A move alone keeps the shape. A phone-shape
  window never becomes the app's remembered frame, so the person's next window
  of that app opens as it always did.
- **A raise keeps the shape it has**, whatever `shape` says, and the answer's
  `size` tells the agent what it got.

`shape: "window"` asks for a person's ordinary window. There is no pixel or dp
argument: a further shape (a landscape phone, say) is added as an enum value
when a task needs one.

## The accessibility tree

`ui_tree` exists because a window's screen is not only pixels. The window's app
runs on its own virtual display, where neither an accessibility service nor
`uiautomator dump` can see it; at shell UID the phone can, so it reads that
display's tree and the Mac answers with it (PROTOCOL.md "UI tree", WIN-79).

The phone trims it for a reader, following what accessibility-driven automation
clients learned the hard way:

- **What can be acted on, not the layout.** A node with no label and no action is
  folded away and its children take its place, so a screen reads as its labels
  and controls rather than as `FrameLayout` after `FrameLayout`.
- **Short names, no defaults.** `Button`, not `android.widget.Button`; `save`,
  not `com.example:id/save`; a false flag is left out, and only a checkable
  box's `check: false` is sent, because it is a real answer.
- **A tap point, not arithmetic.** Each node carries its bounds in display
  pixels and `at`, the centre as 0..1 of the window: exactly the space `tap`
  takes. Models that compute a tap from a scaled screenshot tap the wrong
  quarter of the screen; this leaves nothing to scale.
- **A ref that names the element (S1), then for as long as it is there
  (MCP-71).** Once #162 has merged, the Mac issues refs as `s<snapshot>e<row>`
  from its own per-window read count, and a ref from any read but the window's
  latest is refused with a sentence naming both snapshots: a ref can never
  press whatever took its row in a newer tree. From T10 the phone sends each
  row `k`, a key it keeps for the node's life (the accessibility node's
  identity: the window id and source node id `AccessibilityNodeInfo.equals`
  compares) and never gives another node; the Mac names the ref `e<k>`. A
  `tap` by ref is then resolved **by the phone, at the moment of the press**
  (`ui.press`): it refreshes the node, presses the centre of its bounds as they
  are now, answers the node's role and label as it read them, and refuses with
  `stale_ref` when the node is gone or not visible, `off_screen` when it is
  off the display, or `covered` when something is drawn over its centre. So a
  ref from three reads ago still works if the button is still there, never
  presses whatever moved under the point it once had, and a cart's "Add to
  cart" that turned into "Buy now" is named as "Buy now" in the answer
  (MCP-108). Both refusals keep one sentence shape: the ref, the window, its
  latest snapshot, the next step.
- **Headings and covers (MCP-72, MCP-73).** `heading: true` comes from
  `isHeading`, so a section title reads differently from a table-of-contents
  row with the same text. `covered: "e31"` marks a node whose tap point lies
  under a node drawn after it (by drawing order, outside its own subtree) or a
  window above it, naming the cover: the promo banner's close button sitting on
  a link is visible as such before a tap lands on the wrong one.
- **A text view and a filter (MCP-74, MCP-75).** `format: "text"` answers "what
  does this screen say" in reading order, one line per label, headings as `# `
  and each actionable node with its ref and role, so a text read can still act.
  `find` keeps only matching nodes: a browser page's ninety rows become the one
  the client was looking for.
- **Only what is on screen, and how much is not (MCP-106).** A node off the
  display, not visible to the user or under 8×8 visible pixels is left out
  (#162's F9 marked it `off: true`; a long WebView list still sent hundreds).
  Each scrollable says what it hides as `hidden: [before, after]`, and the
  answer counts every left-out node as `omitted`, so "is there more" is a
  number, not a guess. `find` searches the left-out nodes too: an off-screen
  match comes back `off: true`, with no `at` and `in` naming the scrollable
  to swipe (`swipe {direction, ref}`); a tap on it is refused `off_screen`.
- **A hint is not a value (MCP-104).** A field showing its hint carries
  `hint: true` and the words in `hintText`, never in `text`: an empty search
  box is not read as filled.
- **One focus per window (MCP-105).** A window's display can hold several
  layers (the app, a dialog, the keyboard); each Android window has a focused
  node of its own. Only the layer with input focus is `active`, and only its
  focused node carries `focus`: that is where `type_text` and `press_key`
  land. (Round 1 typed into a node that was focused only in a layer behind.)
- **Still loading says so (MCP-103).** An indeterminate progress bar or an
  empty WebView is kept as `loading: true`, and the answer carries
  `loading: true`.
- **An empty tree says so.** `nodes: []` with a `note`, never a silent blank
  screen. `truncated` marks the node cap; scrolling and asking again is the
  way through a long list.
- **Glyphs are not words.** Icon fonts draw their icons as private-use text
  (`U+EF9E`, `U+EEE8`); those code points are dropped from a label, and a label
  made only of them is no label at all.
- **Password fields carry no text**, only `pwd: true`.
- **`displayId` is an id, `snapshot` is the counter.** The display's own number
  (virtual displays are in the sixties on current builds) and the Mac's read
  count for that window (S1). The tool result leaves `l` out when the display
  holds one layer, where every row would repeat `0`.

An app's own accessibility text can merge a value with its label
(`68,315 Calculation result`); that is the app's text, passed through.

Text in the answer is on-screen content, so it lives in the tool result only:
the app logs the tool name, duration, code and window id, and the phone logs
counts and the display, never a label (PROTOCOL.md "UI tree" §5). The tool sits
behind the same Settings › Automation switch as every other one, and the agent
indicator and Disconnect stay visible while it runs.
#[111](https://github.com/marcoslor/contigua/issues/111) still owns the per-app
allowlist and confirmations before launch; screenshots already expose the same
text, so this adds no new surface of its own.

## Input

`tap` is TOUCH down and up at the point on that stream: for a point, the Mac
sends them; for a ref, the phone injects them at the node's current centre
(`ui.press`). `holdMs` holds the press (the former `long_press`). `swipe` is
down, interpolated TOUCH moves at roughly 60 Hz for `ms`, then up; `direction`
swipes through the centre of the ref's box (else the window's) over 60 % of
its extent along that axis, the finger moving the named way. All of it goes
through the same `Session` methods the pointer and keyboard use
(`Session.touch`, `Session.key`, `Session.text`); no NSEvents are synthesized
and the test-only `DebugInput` path is not used. `back`, `home` and `recents`
are the session `nav` action (home and recents act only in a phone-mode
window, WIN-47); the other keys are KEY down/up frames with Android keycodes
(enter 66, delete 67, tab 61, escape 111, arrows 19–22). `type_text` is the
`ui.type` exchange (MCP-109), and never touches the clipboard (MCP-110).

**Typing without the clipboard (#173).** Until T13 the tool sends the `text`
message, whose non-ASCII runs go through the phone's clipboard and a paste key:
that overwrites what the person copied (an image is lost outright), tells apps
a paste happened, and races two writers. A process at shell UID has these
routes to a focused field:

| Route | Works for | Cost |
|---|---|---|
| KEY events from the virtual keyboard's key map | any focused view, every app | only characters the key map has (ASCII letters, digits, symbols); `é`, `ç`, CJK and emoji have no key |
| A multi-character key event (`ACTION_MULTIPLE` with `KEYCODE_UNKNOWN`) | nothing on API 34: input injection takes only down and up key actions, and the native event carries no characters | — |
| `ACTION_SET_TEXT` on the focused node, through the `UiAutomation` connection `ui_tree` holds | `EditText`, a WebView's editable field, a Compose `TextField`, most cross-platform toolkits | it sets the whole text, so the phone reads the field's text and selection and sets before + typed + after, then moves the cursor with `ACTION_SET_SELECTION`; a password field's text cannot be read, so it can only be replaced; the field's undo history and composing span reset; a view that draws its own text offers no such action |
| Committing through an input connection | — | only the active input method has one; becoming it changes a phone setting (CONV-AND-04) |
| The clipboard and a paste key (today) | what pastes | the person's clip, apps notified, writers race (#173) |

The tool takes the first and the third: text the key map can type goes as KEY
events at the cursor, exactly as a keyboard would (`via: "keys"`); any other
text goes whole through `ACTION_SET_TEXT` at the cursor (`via: "set_text"`).
Both insert — what was in the field stays, and the answer says
`entry: "inserted"`; `clear: true` replaces (`entry: "replaced"`). Where the
focused field cannot take set text — a custom-drawn editor, a password field
that already holds text without `clear` — the call fails `not_supported` with a
sentence naming the way through, and types nothing; with no focused field it
fails `no_field`. There is no clipboard fallback. `submit` sends ENTER after.

The person's own keyboard still uses the `text` message and its clipboard
paste for non-ASCII runs; moving it to the same route is an open question in
the spec.

`input_probe` is the measurement tool built for the pmaxx epic, listed only
while the app runs with `--mcp-dev-tools` (the stream bench, the e2e `mcp`
check and the `tools/emulator/` bench scripts launch it so): it takes the
frame the display layer is showing right now as the baseline (an idle phone
sends nothing, so waiting for a new frame would never arm a probe on a still
screen), and falls back to the first frame its private decoder delivers when
the layer has nothing drawn yet. It starts that decoder and requests a
keyframe before the tap, sends the same TOUCH down/up `tap` sends, and reports
the first frame whose 16×16 luma grid of the watched region changed: the tap's
send time to that frame's decode is `changed_ms`. The display layer shows the
frame on the next refresh, so the number is the input-to-picture part of
input-to-photon (add at most one refresh period, 16.7 ms at 60 Hz). Baselines
are read from BGRA, biplanar 4:2:0 and the display layer's lossless-compressed
4:2:0 (rendered once through CoreImage); video-range luma is widened to full
range before comparing. The decoder lives only for the probe. It is read-only
measurement, not an input route of its own.

## What breaks for existing clients

No backward compatibility during the alpha; every break is listed so a client
author can update in one pass.

| Was | Now |
|---|---|
| `long_press {window, x, y, ms}` | `tap {window, x, y, holdMs}` (or `ref`, `holdMs`); `long_press` is gone from `tools/list`. |
| Input answers `{"ok": true, "window", …}` answered at once | The act envelope (no `ok`), answered after the settle (≤ ~2.3 s) with a tree by default: pass `wait: "none", observe: "none"` for the old timing. |
| `tap` by ref answered `{ok, ref, snapshot, box, x, y}` | `did: {ref, at, box, node}`, `on: {snapshot, frame}`. |
| A ref `s<snapshot>e<row>` worked only from the window's latest tree (#162) | A ref `e<k>` lives as long as its node; refused only when the node is gone, invisible (`stale_ref`), off screen (`off_screen`) or covered (`covered`). |
| `ui_tree` sent off-screen nodes as `off: true` (#162) | They are left out; a scrollable says `hidden: [before, after]`, the answer `omitted`; `find` still reaches them. |
| A layer had `focused` and `active`; every layer could report a focused node | Only `active`, on the layer with input focus; `focus` only on that layer's node. |
| A field showing its hint carried the hint as `text` | `hint: true`, `hintText`, no `text`. |
| `type_text` answered `ok` and pasted non-ASCII text through the phone's clipboard | `did.entry` (`inserted`, `replaced`, `unknown`) and `did.via` (`keys`, `set_text`); the clipboard is never used, and a field that cannot take the text fails `not_supported` or `no_field`. |
| `open_app`/`send_link` opened a 900×600 pt landscape window | A new window has the phone's shape and a ≤ 1280 px stream unless `shape: "window"`; the answer carries `size`. |
| `screenshot` `windowSize: {width, height}`, `list_windows` `width`/`height` | `size: [w, h]` in both, in the display's pixels (the space of `box`; the Phone Mirror's is its phone's screen, not its stream); `image: [w, h]`. |
| `input_probe` always listed | Listed only when the app runs with `--mcp-dev-tools`. |
| Tool errors were a bare sentence | `{"error": {"code", "message", …}}` JSON text, `isError: true`. |
| Results had only `content` | `structuredContent` too, and `outputSchema` in `tools/list`. |
| `send_link` answered a sentence | The opened-window answer, with the window id. |
| `send_file` answered "Sending…" at once | Waits for the phone's `drop.result` (≤ 30 s): `state: delivered` or `sending`. |
| `open_app`/`send_link`/`send_file` queued while the phone was connecting | They fail `phone_offline` and queue nothing. |
| `screenshot` returned the layer's last buffer, instantly | A keyframe from after the call (one keyframe's latency), plus a text block; fails `no_frame` where it used to return an old picture. |
| `list_windows` rows `{id, package, width, height}` | Plus `kind`, `label`, `title`, `openedBy`, `openedAgoMs`, `state`, `frame`; and `recentlyClosed`. |
| `phone_status` `{connected, name, battery, charging, locked, windows}` | Plus `screen`, `lockSource`, `lockChangedAgoMs`, `input`, `foreground`, `maxWindows`; `locked` is null with no phone. |
| `list_apps` always every app | Unchanged without `query`; with `query`, matches only and `total`. |
| The shim exited 0 with no output on stdin EOF | It relays the replies; no reply to a relayed request is exit 1 with a sentence. `--help` exists. |
| `close_window` closed any window | A window `openedBy: person` needs `force: true`. |

## Threat model

* **Who can connect.** Only processes running as the same local user, enforced
  by file permissions and `getpeereid`. There is no network transport, no
  remote access, and no discovery: a client must know the profile's socket path.
  A different uid cannot connect (the e2e check cannot create a second account
  on this Mac and skips that step; the uid check is the code under test).
* **Off by default.** The socket exists only while the setting is on. Turning it
  off (or choosing "Disconnect agent") closes connected clients and removes the
  socket. A stale socket file left by a crash cannot be used by a client: the
  shim reports the setting hint and exits.
* **Visible while in use.** The menu bar shows an indicator and a Disconnect
  action; every call is logged by name, duration, outcome code and window id.
  No arguments, text, labels, URLs, file names or pixels are recorded, so the
  log itself is not a transcript of what the agent did.
* **What an agent can do.** Read the app list and phone state, including the
  package of the app in front on the phone's own screen (`task.front`, the read
  the panel's "Open <App> on Mac" row already makes); open windows; see a fresh
  frame and the accessibility tree of any window; wait for a window to settle;
  inject pointer and keyboard input into any window, and set the text of the
  focused field of a window it types into; close windows (a person's only with
  `force`); send an http/https/geo/tel/mailto link; send one readable
  regular file the Mac's user can read (up to the existing drop cap) to the
  phone. That is equivalent to a person at the Mac with the same windows open,
  plus the ability to read a screenshot. The agent hold keeps a window's
  encoder running while an agent uses it; it changes no phone setting.
* **What it cannot do.** Read or write notifications, media sessions or the
  clipboard (typing uses keys or the focused field's own set-text action,
  MCP-110); open arbitrary file URLs on the phone; read or change pairings,
  identity keys or defaults; write files on the Mac; run shell commands or
  launch Mac apps; reach another user's processes; reach the phone except
  through the existing paired, encrypted session; unlock the phone. Input into
  the phone stops at the phone's own permission boundaries, exactly like the
  person's pointer.
* **Opt-in is per profile.** Each profile has its own setting and socket; the
  test profiles are never the user's installed profile.
