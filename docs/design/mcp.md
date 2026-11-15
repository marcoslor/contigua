# Automation server (MCP)

An AI agent on this Mac (Claude Code, Claude Desktop, any MCP client) drives the
connected phone through Contigua: see what a window shows, tap/type/swipe, open
apps, send links and files, read the phone's state. Everything stays local, is
off by default, and is visible while it is in use.

## Transport

The app listens on a UNIX socket in the profile's Application Support folder:

```
~/Library/Application Support/Contigua/mcp.sock          (default profile)
~/Library/Application Support/Contigua-<profile>/mcp.sock (any other profile)
```

The folder is `0700` and the socket `0600`; the app checks the connecting
process's uid with `getpeereid(2)` and closes the connection unless it is our
own uid. There is no TCP listener and no network exposure.

A small stdio shim, `contigua-mcp`, ships inside the app as
`Contents/Helpers/contigua-mcp` (compiled by `bundle.sh` with `swiftc`, like
the Dock shim, and codesigned with the bundle). It relays bytes between its
stdin/stdout and the socket without interpreting them. `--profile NAME` chooses
the socket; without it the default profile is used. When the socket is missing
or refuses the connection the shim writes
`Turn on Settings › Automation in Contigua` to stderr and exits non-zero.

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
tool name and duration only. Arguments, typed text, URLs, file names and pixels
are never logged.

## Protocol

MCP revision `2025-06-18`, JSON-RPC 2.0, newline-delimited JSON over the socket.
One request or notification per line; a line longer than 1 MiB is refused.
`initialize`, `ping`, `tools/list` and `tools/call` are implemented;
notifications (no `id`) get no reply. The implementation is hand-written in a
pure `MCPCore` (parse, dispatch, schemas, argument validation) with unit tests;
no third-party MCP SDK is used. Up to four clients may be connected at once.

`initialize` answers with protocol version `2025-06-18`, `tools: {}` and
`serverInfo` naming Contigua. `tools/call` results are
`{"content": [...], "isError": false}`; errors caused by the moment a tool runs
(no phone connected, no such window, a file that vanished) are tool results with
`isError: true` and a human sentence, not JSON-RPC errors. JSON-RPC errors are
only for protocol faults: malformed JSON (`-32700`), an invalid request or
oversized line (`-32600`), an unknown method or tool (`-32601`/`-32602`), and
arguments that do not match the tool's schema (`-32602`).

## Tools

Coordinates are `0..1`, normalized to the window's video rect (the same
coordinates the TOUCH frames carry). Window ids are the stream ids
`list_windows` reports.

| tool | arguments | result |
|---|---|---|
| `phone_status` | — | connected, phone name, battery level/charging, locked, open window count |
| `list_apps` | — | every app the phone reports, as `label`, `package` |
| `open_app` | `app`: package or label | the opened window's id, package and label |
| `list_windows` | — | `id`, `package` (null for the Phone Mirror), width and height (stream pixels) |
| `screenshot` | `window` | PNG image content of the last displayed frame, longest side ≤ 1280 px |
| `ui_tree` | `window` | the display's accessibility tree, trimmed for a reader: one row per label or control, with its text, view id, bounds and a tap point in 0..1 |
| `tap` | `window`, `x`, `y`, or `window`, `ref` | down/up at the point, or at the element the ref named in the latest `ui_tree` |
| `long_press` | `window`, `x`, `y`, `ms` ≤ 3000 | down, wait, up |
| `swipe` | `window`, `x1`, `y1`, `x2`, `y2`, `ms` ≤ 2000 | down, interpolated moves at ~60 Hz, up |
| `type_text` | `window`, `text` ≤ 2000 chars | the same `text` frame the keyboard sends |
| `press_key` | `window`, `key` = back/home/recents/enter/delete/tab/escape/up/down/left/right | nav or KEY frames |
| `input_probe` | `window`, `x`, `y`, optional `w`, `h` (0.05–1) | taps, then the ms until the displayed picture's watched region changed; `changed_ms` null when nothing changed in 2 s |
| `close_window` | `window` | closes the window the way its close button does |
| `send_link` | `url` | LinkPolicy validates it; the existing link path sends it |
| `send_file` | `path` (absolute, regular, readable file) | the existing drop path sends it |

`open_app`, `send_link` and `send_file` reuse the App Intents core and bridge
(`IntentsCore`, `IntentsBridge`): the same phone resolution, app matching, link
policy and drop limits. There is deliberately no notification reading:
notifications are a separate privacy surface.

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
- **A ref, so the action names the element.** Every node also carries `ref`,
  and `tap` takes a ref as well as a point. The refs belong to the tree that was
  just read: a newer tree replaces them, so a ref the client kept from an older
  screen is refused instead of pressing whatever moved under that point. This is
  the same ref-per-snapshot rule accessibility-driven automation clients use;
  it turns "tap at 0.42, 0.31" into "tap that button".
- **An empty tree says so.** `nodes: []` with a `note`, never a silent blank
  screen. `truncated` marks the node cap; scrolling and asking again is the
  way through a long list.
- **Password fields carry no text**, only `pwd: true`.

Text in the answer is on-screen content, so it lives in the tool result only:
the app logs the tool name and duration, and the phone logs counts and the
display, never a label (PROTOCOL.md "UI tree" §5). The tool sits behind the same
Settings › Automation switch as every other one, and the agent indicator and
Disconnect stay visible while it runs. #[111](https://github.com/marcoslor/contigua/issues/111)
still owns the per-app allowlist and confirmations before launch; screenshots
already expose the same text, so this adds no new surface of its own.

Screenshots use the frame routes Live Text freezes on (docs/design/livetext.md):
the frame the display layer shows (`copyDisplayedFrame()`, the same frame the
person sees), else the phone's next keyframe decoded once
(`beginFrameSnapshot`), for a window whose layer reports no displayed buffer.
`FrameGrab` only scales the frame (longest side ≤ 1280 px) and encodes the PNG.

### Input

`tap` is TOUCH down and up at the mapped point on that stream. `long_press` is
down, a wait, up. `swipe` is down, interpolated TOUCH moves at roughly 60 Hz for
`ms`, then up. All of it goes through the same `Session` methods the pointer and
keyboard use (`Session.touch`, `Session.key`, `Session.text`); no NSEvents are
synthesized and the test-only `DebugInput` path is not used. `back`, `home` and
`recents` are the session `nav` action; the other keys are KEY down/up frames
with Android keycodes (enter 66, delete 67, tab 61, escape 111, arrows 19–22).

`input_probe` is the measurement tool built for the pmaxx epic: it takes the
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
  action; every call is logged by name and duration. No arguments, text, URLs,
  file names or pixels are recorded, so the log itself is not a transcript of
  what the agent did.
* **What an agent can do.** Read the app list and phone state; open windows;
  see the last displayed frame of any window; inject pointer and keyboard input
  into any window; close windows; send an http/https/geo/tel/mailto link; send
  one readable regular file the Mac's user can read (up to the existing drop
  cap) to the phone. That is equivalent to a person at the Mac with the same
  windows open, plus the ability to read a screenshot.
* **What it cannot do.** Read notifications, media sessions or clipboard
  contents; open arbitrary file URLs on the phone; read or change pairings,
  identity keys or defaults; write files on the Mac; run shell commands or
  launch Mac apps; reach another user's processes; reach the phone except
  through the existing paired, encrypted session. Input into the phone stops at
  the phone's own permission boundaries, exactly like the person's pointer.
* **Opt-in is per profile.** Each profile has its own setting and socket; the
  test profiles are never the user's installed profile.
