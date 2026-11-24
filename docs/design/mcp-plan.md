# MCP epic #171: the work, in PR-sized tasks

Temporary: the PO deletes this file when the epic ships. The contract is
`docs/design/mcp.md`, the behaviour `docs/specs/mcp.md` (`MCP-n`), the wire
`docs/PROTOCOL.md` "UI tree" (items 6–10, #171's deltas on top of #162) and
`state.lockSource`. If this plan
and those disagree, they win.

## How to read a task

- **Closes** — the issue the PR's `Fixes #N` names (several tasks may share
  one; the last closes it).
- **Rows** — the spec rows it implements; each test named below carries its
  ID in brackets in its name or its `ok` line.
- **Files** — every file it may touch. A file not listed is out of scope;
  needing one is a question for the lead, not an edit.
- **Wire** — yes/no; yes means PROTOCOL.md, the phone, the Mac and the fake
  phone move together, and the PR lists the messages.
- **Review** — ⚠ marks protocol, concurrency or state-machine work: every line
  is reviewed and the PR carries device proof (emulator, and the real phone
  where named).
- **Tests** — the failing-first checks, with input and expected output.
  "K2" is `cd macos && swift build && swift test --filter <Name>`, "K1" the
  Docker run filtered to the class, "e2e" one `check-e2e.sh mcp` run over the
  fake phone, "emulator" a `tools/emulator/` run (all through `heavy.sh`,
  `.agent/WORKER.md`).
- **Depends** — tasks that must be merged first.

**PR #162 merges first.** Its fix list ships S1 (refs the Mac issues as
`s<snapshot>e<row>`; a ref from any read but the window's latest is refused
with a sentence naming both snapshots), S2 (`size: [w, h]`, the pixel space of
`box`; `at` is TOUCH's 0..1 input space), S3 (`layers`/`l` for the display's
Android windows) and F9 (`off: true`, no `at`, the ref refused, `box` clipped),
and it changes `macos/scripts/mcp-driver.py`. Every task but T0 starts from
`main` after #162 has merged, uses those names, and renames none of them back.
T0 started from `spec/mcp-contract` before #162 merged, so it leaves the driver
alone.

General rules for every task: tests first (they fail on `main`, pass with the
change, both runs in the PR); a log line never carries a label, text, package,
URL, path or title (AGENTS.md); the phone stays locked; nothing here changes a
product default except where a row says so.

## Schedule: two at a time, disjoint files

Lane A is the Mac's MCP core (it shares `MCPCore.swift`, `ConnectionController.swift`
and `Session.swift`, so most of it is serial); lane B is the phone, the fake
phone, the shim, and Mac work that touches none of lane A's files in that round.
The two tasks of a round share no file (each task's **Files** list is the proof).

| Round | Lane A | Lane B | Why this order |
|---|---|---|---|
| 1 | T0 the shim and EOF (#169) | B1 phone: `ui.settle`, loading signals | #169 is the epic's first item and starts now; T0 adds its own suite beside the old driver, which #162 is changing. B1 unblocks T5. |
| 2 | T1 answers, errors, client id; the driver moves into `macos/scripts/mcp/` | B2 phone: stable keys, heading, covered | T1 is the shape every later answer is built on, and the first task after #162, so it moves the driver #162 changed. |
| 3 | T3 fresh screenshots, freshness (#165) | B3 phone: `ui.press` | #165 was every run's top fix. |
| 4 | T5 act, settle, observe (#166) | B4 phone: `lockSource` | #166 is the second cost, and its settle ends the skeleton trees. |
| 5 | T10 Mac: press by ref, refs survive reads | T7 windows ledger (#168) | Refs end read→tap→read; provenance is the third cost. |
| 6 | T11 `wait` (#166) | T8 `phone_status` (#167) | The stopwatch's 13 reads; the lock sentence. |
| 7 | T6 opens answer like actions (#168) | B6 the tree says what it does not show: hint, the active layer, off-screen counts | T6 needs T5 and T7; B6 touches only the phone, the fake phone and `UITree.swift`, none of T6's files. |
| 8 | T12 an agent's window takes the phone's shape (#175) | B5 phone: `ui.type`, no clipboard (#173) | T12 changes `open_app`/`send_link`, so it follows T6; B5 needs B6's active layer. |
| 9 | T13 Mac: `type_text` through `ui.type` (#173) | T14 phone: the person's typing never loses their clip (#173) | T13 needs B5 and T5's machine and shares `MCPCore` and `MCPTools+Input` with T2; T14 reuses B5's `TextEntry` and touches no Mac file. |
| 10 | T2 descriptions and tool shapes (#172) | — | Its doc-match test sees the final tool set, `shape` and `type_text`'s answer included. |

Rounds 9–10 are serial because each touches `MCPCore.swift`; a free worker in
those rounds takes the emulator and real-phone proofs of earlier tasks instead.

---

The task sections below are grouped by area; the schedule above is the order.

## T0 — The shim drains, fails loudly and has `--help`

- **Closes** #169. **Rows** MCP-2 (its missing test), MCP-10, MCP-11, MCP-12. **Wire** no. **Review** ⚠ concurrency (the server's half-close).
- **Files** `macos/Shim/mcp.swift`, `macos/Sources/Contigua/MCPServer.swift`,
  `macos/Tests/ContiguaTests/MCPServerTests.swift`, `macos/scripts/check-e2e.sh`
  (`check_mcp` only), new `macos/scripts/mcp/suite_shim.py` (and new
  `macos/scripts/mcp/common.py` only if the suite needs shared helpers).
  `macos/scripts/mcp-driver.py` is **not** touched: the #162 fix worker is
  changing it; T1 moves it.
- **Work**
  1. Server: on a client's read EOF, mark the client `halfClosed` instead of
     dropping it; keep draining `pending`; after the last reply is written,
     close. `disconnectClients()`/`stop()` still close at once.
  2. Shim: on stdin EOF `shutdown(SHUT_WR)` and keep the socket→stdout relay
     until the socket's EOF; count bytes relayed each way; exit per the table
     in design/mcp.md "Transport".
  3. Shim: `--help`/`-h` prints usage to stdout, exit 0; an unknown argument
     prints the reason and usage to stderr, exit 1.
  4. `check_mcp` runs the old driver (`mcp-driver.py`) as it does today, then
     `macos/scripts/mcp/suite_shim.py`, which drives the shim directly and
     needs no driver. Splitting the driver is T1's first item.
- **Tests**
  - K2 `MCPServerTests.testEOFAfterARequestStillGetsTheReply` `[MCP-10]`: a
    socket client writes `{"jsonrpc":"2.0","id":1,"method":"ping"}\n` and
    immediately `shutdown(SHUT_WR)`; it reads `{"id":1,"jsonrpc":"2.0","result":{}}\n`
    and then EOF within 2 s. Fails today (EOF, no bytes).
  - K2 `MCPServerTests.testEOFWithASlowCallWritesItsReplyFirst` `[MCP-10]`: the
    handler sleeps 300 ms; same client; the reply arrives before EOF.
  - K2 `MCPServerTests.testAForeignUidIsClosed` `[MCP-2]`: with the uid check
    injected to answer "not ours", a connecting client reads EOF with no byte.
  - K2 `MCPServerTests.testDisconnectStillClosesAtOnce` `[MCP-10]`: with a
    300 ms call running, `disconnectClients()` → the client reads EOF within
    100 ms and no reply.
  - e2e `suite_shim.py` `[MCP-11]`: `printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n' | contigua-mcp --profile P`
    → stdout is one line whose `result.protocolVersion` is `"2025-06-18"`,
    exit 0. Fails today (empty, 0).
  - e2e `suite_shim.py` `[MCP-11]`: with the app's socket held by a test
    listener that accepts, reads one line and closes → stderr
    `contigua-mcp: the app closed the connection with no reply`, exit 1.
  - e2e `suite_shim.py` `[MCP-12]`: `contigua-mcp --help` → exit 0, stdout
    contains `--profile`, `mcp.sock` and `Turn on Settings › Automation in Contigua`;
    `contigua-mcp --bogus` → exit 1, stderr contains `unknown argument --bogus`
    and `--profile`.
  - e2e: every existing `MCP …` ok line still passes from the old driver.
- **Tier** K2, e2e. **Depends** —.

## T1 — One answer shape, closed error codes, the client's identity

- **Closes** — (foundation; #172's `ok` item closes with T5). **Rows** MCP-5, MCP-6, MCP-14, MCP-40/MCP-70 (their codes), MCP-33 (`not_ready` before the app list). **Wire** no. **Review** normal.
- **Files** `macos/Sources/Contigua/MCPCore.swift`,
  `macos/Sources/Contigua/MCPTools.swift` (split into `MCPToolHost.swift` —
  `perform`, helpers, `requireWindow` — and `MCPTools+Phone.swift`
  (phone_status, list_apps), `MCPTools+Open.swift` (open_app, send_link,
  send_file), `MCPTools+Windows.swift` (list_windows, close_window),
  `MCPTools+Screen.swift` (screenshot, input_probe), `MCPTools+Tree.swift`
  (ui_tree), `MCPTools+Input.swift` (tap, long_press, swipe, type_text,
  press_key)), new `macos/Sources/Contigua/MCPToolError.swift`,
  `macos/Sources/Contigua/MCPServer.swift` (pass a client id only),
  `macos/Sources/Contigua/MCPAutomation.swift` (the log line),
  `macos/Tests/ContiguaTests/MCPCoreTests.swift`, new
  `macos/Tests/ContiguaTests/MCPToolErrorTests.swift`,
  `macos/scripts/mcp-driver.py` (moved, as #162 left it, to
  `macos/scripts/mcp/driver.py`), `macos/scripts/mcp/common.py`, new
  `macos/scripts/mcp/suite_core.py`, `macos/scripts/check-e2e.sh` (`check_mcp`
  only), `tools/emulator/overrun.sh` (the driver's path only),
  `tools/stream-bench/README.md` (the driver's name only).
- **Work**
  0. Move the driver: `mcp-driver.py` becomes `macos/scripts/mcp/driver.py`
     with `--suite NAME` running `suite_NAME.py`; its assertions, as #162 left
     them, move to `suite_core.py` unchanged (same `ok` lines); shared helpers
     go to `common.py` beside T0's. `check_mcp` stops running the old driver and
     runs every `suite_*.py` in name order, so a later task adds a suite
     without touching `check-e2e.sh`. `overrun.sh` and the bench README name
     the new path.
  1. `MCPToolResult` becomes `.answer([String: Any])`, `.image(Data, [String: Any])`,
     `.failure(MCPToolError)`; `MCPToolError` has `code: MCPErrorCode`
     (an enum of exactly MCP-6's 17 codes), `message`, `extra: [String: Any]`.
  2. `resultBody`: an answer is `content: [text(JSON)]` + `structuredContent`;
     an image puts the image block first; a failure is `isError: true`,
     `content: [text({"error": {...}})]`, no `structuredContent`. JSON
     through `JSONEncoder`-equivalent output with sorted keys and no 17-digit
     doubles (the `UITree.encoded` rule, WIN-79).
  3. Map every existing throw: `IntentFailure.phoneNotConnected` → `phone_offline`,
     no phone resolved → `no_phone`, `appNotFound` → `not_found`,
     `severalApps` → `ambiguous` (+ `matches`), link refused → `bad_url`,
     file refused → `bad_file`, "No window N." → `no_window`, #162's
     older-snapshot ref → `stale_ref` (+ `snapshot`, the sentence kept),
     #162's off-screen ref → `off_screen`, tree timeout → `timeout`, tree failures per MCP-70, no frame →
     `no_frame`, anything else → `failed`.
  4. `tools/list` declares `outputSchema` per tool: the answer shapes of
     design/mcp.md for the tools as they are **today** (each later task
     updates its own tool's schema).
  5. `MCPDispatcher.handle(line:client:perform:log:)` — `perform` receives an
     `MCPClientID` (the server's per-connection counter); the log hook gets
     `(tool, duration, code?, window?)`.
  6. Behaviour of every tool is otherwise unchanged (answers keep today's
     fields, now as structured content).
- **Tests**
  - K2 `MCPCoreTests.testEveryAnswerIsStructuredAndMirroredAsText` `[MCP-5]`:
    perform returns `.answer(["window": 3])` → result
    `{"content":[{"type":"text","text":"{\"window\":3}"}],"isError":false,"structuredContent":{"window":3}}`.
  - K2 `MCPCoreTests.testImageAnswerPutsTheImageFirst` `[MCP-5]`: `.image(png, ["window": 3])`
    → `content[0].type == "image"`, `content[1].text == "{\"window\":3}"`.
  - K2 `MCPCoreTests.testToolListDeclaresAnOutputSchemaForEveryTool` `[MCP-5]`.
  - K2 `MCPToolErrorTests.testEveryFailureMapsToOneClosedCode` `[MCP-6]`: a
    table of each thrown error above → its code; `MCPErrorCode.allCases.count == 17`.
  - K2 `MCPToolErrorTests.testAFailureIsJSONWithCodeAndSentence` `[MCP-6]`:
    `.failure(no_window, "No window 9. Call list_windows to see what is open.", ["window": 9])`
    → `isError: true`, text parses to `{"error":{"code":"no_window","message":"No window 9. Call list_windows to see what is open.","window":9}}`.
  - K2 `MCPToolErrorTests.testTreeFailuresMapToClosedCodes` `[MCP-70]`: phone
    `ui.tree` codes `no_window`, `not_available`, `no_a11y`, `no_display`,
    `busy`, `failed` and a 3 s silence → `no_window`, `not_supported`,
    `not_supported`, `no_window`, `failed`, `failed`, `timeout`.
  - K2 `MCPToolHostTests.testNoAppListYetIsNotReady` `[MCP-33]`: an empty
    cached list for an online phone → `list_apps` and `open_app` fail `not_ready`.
  - K2 `MCPCoreTests.testTheLogLineCarriesNameDurationCodeAndWindowOnly` `[MCP-14]`:
    a `type_text` call with text `"secret"` → the log hook receives
    `(.typeText, d, nil, 3)` and nothing else; the formatted line contains
    no `secret`.
  - e2e `suite_core.py` `[MCP-6]`: `ui_tree {window: 999}` → `isError`,
    `error.code == "no_window"` (replaces the old sentence assertion).
  - e2e: every `MCP …` ok line the old driver printed (as #162 left it) is
    printed by `suite_core.py`, and `check_mcp` no longer runs `mcp-driver.py`.
- **Tier** K2, e2e. **Depends** —.

## T3 — A screenshot is a frame from after the call; every answer says how fresh

- **Closes** #165. **Rows** MCP-20, MCP-21, MCP-22, MCP-50 (`size` only), MCP-60, MCP-61, MCP-62, MCP-63. **Wire** no. **Review** ⚠ state machine (AgentHold) and concurrency (the video queue's counter, the snapshot decoder shared with Live Text).
- **Files** new `macos/Sources/Contigua/FrameClock.swift`, new
  `macos/Sources/Contigua/AgentHold.swift`, `StreamPause.swift`,
  `StreamWindow.swift` (the hold input to `shouldPause`, the per-window
  `FrameClock`), `VideoLayerView.swift` (count each access unit on the video
  queue; stamp the snapshot decoder's frame with its `seq`; a 16×16 luma grid
  of the snapshot), `MCPTools+Screen.swift`, `MCPToolHost.swift` (call the
  hold on every window-naming call; `frame`/`state` helpers),
  `MCPTools+Tree.swift` and `MCPTools+Windows.swift` (add `frame`/`state`
  only, and `list_windows`' `size`), `MCPCore.swift` (screenshot `ref`), tests below, new
  `macos/scripts/mcp/suite_screen.py`, `macos/Sources/Contigua/DebugControl*.swift`
  only if a `pause <stream>` setup verb is missing.
- **Work**
  1. `FrameClock` (pure, value type): `received(atUptime:) -> seq`, `newest`,
     `age(now:)`. Owned per window; incremented on the video queue where an
     access unit is complete (whole frame, or a chunk set reassembled), read
     on main under the existing lock discipline.
  2. `AgentHold` (pure machine, spec "The agent hold"): `Released`/`Held(until)`
     × `agentCall(now)`, `tick(now)`, `windowClosed`; hold 15 s (constant,
     MCP-22). `StreamPause.shouldPause` gains `agentHold: Bool`, which
     returns false before every other rule, for a covered and a minimised
     window alike.
  3. Screenshot: `beginFrameSnapshot` always (never `copyDisplayedFrame`);
     the decoder delivers `(buffer, seq)`; the answer is `.image(png, {window,
     state, frame: {seq, ageMs}, image: [w, h], size: [w, h], blank?, crop?})`. No frame
     in 2 s → `no_frame` with `state` and the sentence per state. If Live Text
     holds the decoder, wait for it to finish (≤ 2 s) rather than fail.
  4. `blank`: every cell of the 16×16 luma grid within 2 levels of the
     others (reuse the probe's grid code; no new image path).
  5. `ref` crop: latest tree's box for the ref + 8 px, clamped; then scale.
  6. `frame` and `state` on `ui_tree`, `list_windows` rows and every input
     answer (input answers keep their other fields until T5).
- **Tests**
  - K2 `FrameClockTests.testSeqCountsAccessUnitsAndAgeIsSinceArrival` `[MCP-20]`:
    received at 10.0 s, 10.5 s → `newest == 2`; `age(now: 11.0) == 500 ms`;
    a fresh clock → `seq 0`, `ageMs nil`.
  - K2 `MCPWindowStateTests.testEveryLifecycleStateHasOneToken` `[MCP-21]`:
    opening, live, paused, stalled, link-down/reconnecting/offline, closed →
    `opening`, `live`, `paused`, `stalled`, `offline`, `offline`, `offline`, `closed`.
  - K2 `AgentHoldTests` `[MCP-22]`, one test per row of the spec table, e.g.
    `testACallHoldsForFifteenSeconds`: `agentCall(100)` → `Held(115)`;
    `tick(114.9)` → still Held; `tick(115)` → Released with action
    `reevaluatePause`.
  - K2 `StreamPauseTests.testAnAgentHoldKeepsACoveredWindowLive` `[MCP-22]`:
    `shouldPause(miniaturized: false, key: false, main: false, occludedVisible: false, menuTracking: false, agentHold: true) == false`,
    and `StreamPauseTests.testAnAgentHoldKeepsAMinimisedWindowLive` `[MCP-22]`:
    `miniaturized: true, agentHold: true` → false.
  - K2 `ScreenshotSourceTests.testTheAnswerIsAFrameThatArrivedAfterTheCall` `[MCP-60]`:
    with a fake snapshot source whose clock is at seq 40 when the call starts
    and that delivers seq 41 → answer `frame.seq == 41`; `copyDisplayedFrame`
    is never called (the fake traps).
  - K2 `ScreenshotSourceTests.testNoKeyframeIsNoFrame` `[MCP-61]`: the source
    never delivers; at 2 s → `no_frame`, `extra.state == "paused"` for a paused
    window, message `Window 3 is paused: no new picture arrived in 2 s.`
  - K2 `ScreenshotSourceTests.testAOneColourFrameIsBlank` `[MCP-62]`: a
    64×64 BGRA all-black buffer → `blank: true`; a half-white one → no `blank` key.
  - K2 `ScreenshotSourceTests.testARefCropsToItsBox` `[MCP-63]`: window
    1080×2400, ref box `[100,200,300,260]` → `crop == [92,192,308,268]`;
    unknown ref → `stale_ref`.
  - e2e `suite_screen.py` `[MCP-60]`: `screenshot` twice → second `frame.seq`
    > first, both `state: "live"`, the fake phone's event log shows one
    `window.keyframe` per call; `image[0] ≤ 1280`, `size` equals
    `list_windows`' `size` (T3 renames that row's `width`/`height` to `size`,
    MCP-50).
  - e2e `suite_screen.py` `[MCP-22]`: pause the window with the debug-control
    verb (setup), call `screenshot` → the fake's log shows `window.resume`
    before the keyframe and the answer's `state` is `live`; 16 s after the
    call (fake clock not available: real wait, bounded 20 s) the log shows
    `window.pause`.
  - emulator `[MCP-60]` ⚠: open Calculator, cover its window with another
    window, tap `7` by ref, `screenshot` → the image shows `7` (decoded-frame
    check per macos/AGENTS.md), `frame.ageMs < 1000`.
  - real phone `[MCP-60]` (PO run): repeat round 1's unit-converter task;
    four screenshots minutes apart differ and their `seq` grows.
- **Tier** K2, e2e, emulator, real phone. **Depends** T1.

## B1 — Phone: `ui.settle`, and a tree that says it is still loading

- **Closes** — (#166 with T5). **Rows** MCP-81 (phone half), MCP-103, MCP-107, PROTOCOL.md "UI tree" items 6, 7 and item 9's `loading`. **Wire** yes: `ui.settle` both ways (with `reason`); one `ui.*` at a time; `loading` on a row and on the reply. **Review** ⚠ protocol, state machine, concurrency (the a11y event thread; the loading check runs off it).
- **Files** new `android/app/src/main/java/app/contigua/server/SettleWatch.kt`
  (pure), new `LoadingSignal.kt` (pure: a node's class, visibility, range and
  child count → loading or not), `UiTree.kt` (keep and mark a loading node;
  `loading` on the reply), `UiAutomationTree.kt` (event listener filtered to
  MCP-107's content types, window-id→display map, the loading check),
  `UiTreeSource` interface (in `UiTree.kt` or its own file; add
  `settle(displayId, quietMs, timeoutMs)`), `Session.kt` (`ui.settle`
  dispatch, the shared `ui.*` busy flag replacing `uiTreeBusy`), new
  `android/app/src/test/java/app/contigua/server/SettleWatchTest.kt`,
  new `LoadingSignalTest.kt`, `UiTreeTest.kt` (the loading cases),
  `tools/fakephone/fakephone.py` (`ui.settle` answering after
  `--settle-ms` (default 120) or `settled: false, reason: "changes"` at
  `timeoutMs` with `--never-settle`, `reason: "loading"` with
  `--settle-loading` (which also marks a spinner row `loading` in the tree),
  `--ignore-ui-settle`; `--close-on-back`: a `nav back` closes the stream with
  `window.closed reason app_exited`).
- **Tests**
  - K1 `SettleWatchTest` `[MCP-81]`, one test per row of the spec table
    "Settling a display", e.g.:
    `testQuietForQuietMsSettles`: start(q=300, t=2000, now=0), event(100),
    tick(400) → Watching; tick(400+…)… tick(400) with last=100 → reply
    `settled: true, waitedMs: 400, events: 1`;
    `testTimeoutAnswersNotSettled`: events every 100 ms from 0 to 2100,
    ticks → at 2000 reply `settled: false, waitedMs: 2000`;
    `testAnotherDisplaysEventsAreIgnored`; `testASecondStartIsBusy`;
    `testDisplayGoneAnswersNoDisplay`; `testSessionEndRepliesNothing`;
    `testOnlyContentChangesCount` `[MCP-107]`: start(q=300, t=2000, now=0),
    `TYPE_VIEW_FOCUSED` and `TYPE_VIEW_CLICKED` every 50 ms → at tick(300)
    Checking, `loading(false)` → reply `settled: true, waitedMs: 300, events: 0`;
    `testASpinnerKeepsTheWatchOpen` `[MCP-107]`: quiet from 0, `loading(true)`
    at 300 and 600, `loading(false)` at 900 → reply `settled: true, waitedMs: 900`;
    `testATimeoutWhileLoadingSaysLoading` `[MCP-107]`: `loading(true)` at every
    check to 2000 → `settled: false, reason: "loading"`; a content event at
    1900 → `reason: "changes"`; `testALateLoadingCheckIsIgnored`.
  - K1 `LoadingSignalTest` `[MCP-103]`: `android.widget.ProgressBar`, visible,
    no `RangeInfo` → loading; with `RangeInfo(0, 100, 40)` → not; invisible →
    not; `android.webkit.WebView`, visible, 0 children → loading; 3 children →
    not; a class `com.example.FancyProgressBar` with no range → loading.
  - K1 `UiTreeTest.testALoadingNodeIsKeptAndMarked` `[MCP-103]`: an unlabelled
    indeterminate ProgressBar → kept, `"loading":true`, and the reply has
    `"loading":true`; with none → no `loading` key on the reply.
  - K1 `SessionTest.testUiSettleClampsItsArguments` `[MCP-81]`:
    `{"t":"ui.settle","stream":3,"seq":1,"quietMs":5,"timeoutMs":99999}` →
    the source is called with (100, 10000).
  - K1 `SessionTest.testOneUiRequestAtATime` `[MCP-9]`: a `ui.tree` arriving
    while a settle runs → `{"t":"ui.tree","stream":3,"seq":2,"ok":false,"code":"busy",…}`.
  - fake phone selfcheck: `ui.settle` with `--settle-ms 120` answers
    `settled: true, waitedMs ≥ 120` within 300 ms.
  - emulator `[MCP-81]` `[MCP-103]` `[MCP-107]`, `tools/emulator/settle.sh`
    (the image has no Calculator and its browser exposes no page nodes, so the
    vehicles are native): a tap on a Clock tab by ref → `settled: true` within
    2 s; Clock stopwatch running → `settled: false`, `reason: "changes"`,
    `waitedMs == 2000 ± 50`; a native indeterminate `ProgressBar` found through
    `ui.tree` class names → `loading: true` on its row and the reply, and a
    settle during it → `reason: "loading"`; a settle sent right after
    `window.open` or `link.open` → never `no_display`. Web spinners are not a
    loading signal (MCP-103), so no web page is used.
- **Tier** K1, fake-phone selfcheck, emulator. **Depends** —.

## T5 — Every action answers the envelope, settles and observes

- **Closes** #166 (with T11), #172's `ok` item. **Rows** MCP-8, MCP-9, MCP-64, MCP-70 (settle clause), MCP-80, MCP-81, MCP-82, MCP-83, MCP-84, MCP-85, MCP-87, MCP-103 (Mac pass-through), MCP-107 (Mac half: `reason`), MCP-108 (S1 stage). **Wire** consumes `ui.settle` with `reason` and `loading` (B1). **Review** ⚠ state machine, concurrency (two queues, continuations, deadlines).
- **Files** new `macos/Sources/Contigua/MCPActMachine.swift` (pure, the whole
  spec table including the Pressing and Opening states used later by T10 and
  T6), new `PhoneReadQueue.swift`, new `WindowActQueue.swift`,
  `ConnectionController.swift` (route `ui.tree` through `PhoneReadQueue`; add
  `uiSettle(stream:quietMs:timeoutMs:)`; report other input sources per
  window — the person's pointer/keyboard path already passes through
  `StreamWindow` → add one counter call there), `StreamWindow.swift` (that
  counter call only), `Session.swift` (send `ui.settle`, parse its reply),
  `MCPCore.swift` (`wait`, `observe` on tap/long_press/swipe/type_text/press_key;
  `wait` on screenshot and ui_tree), `MCPTools+Input.swift`,
  `MCPTools+Screen.swift`, `MCPTools+Tree.swift`, `UITree.swift` (parse and
  encode `loading` on a row and on the answer), `UITreeTests.swift`, tests
  below, new `macos/scripts/mcp/suite_act.py`.
- **Work** The machine is pure; a thin runner owns the continuation, the
  deadline timer and the seq. The envelope replaces `ok` on every input tool.
  A ref tap takes the S1 path (the machine's note under "One act call"): the
  ref is checked against the window's latest tree, refused `stale_ref` or
  `off_screen` as #162 refuses it, and pressed at its `at`; `did.node` is that
  tree's row (MCP-108). Point taps add `hit` from the latest tree (MCP-87).
  Calls to one window are serialised in `WindowActQueue`; all `ui.*` sends in
  `PhoneReadQueue`, which takes over #162's per-session serialisation of
  `ui.tree` (F6) and extends it to `ui.settle` (and later `ui.press`,
  `ui.type`). `observe` defaults to `"tree"` (MCP-82).
- **Tests**
  - K2 `MCPActMachineTests` `[MCP-80]`/`[MCP-81]`/`[MCP-83]`/`[MCP-85]`: one
    test per row of "One act call", each `(state, event) → (state, actions)`
    asserted exactly, e.g. `testSettledThenTreeAnswersWithTheTree`:
    Sent(settle, tree) + entry → Settling, `[sendSettle(300, 2000)]`;
    + `settle.reply(settled, 412)` → Observing, `[sendTree]`; + `tree.reply(T)`
    → Done, `[answer(settle: {state: settled, waitedMs: 412}, tree: T)]`.
    `testAWindowThatClosesDuringTheSettleSaysWhy`: Settling +
    `windowClosed(app_exited, phone)` → Done,
    `[answer(state: closed, closed: {reason: app_exited, closedBy: phone}, settle: {state: window_closed})]`.
    `testNoInputBeforeTheWindowIsLive`: Queued + turn(window opening) →
    Done, `[fail(not_ready)]`, no `sendInput`.
    `testTheDeadlineAnswersTimeout` `[MCP-8]`; `testLateRepliesAreIgnoredBySeq`.
  - K2 `MCPActMachineTests.testObserveTreeReadsAfterTheSettle` and
    `testATreeFailureAfterTheActionIsNotAnError` `[MCP-82]`: Observing +
    `tree.failed(timeout)` → answer with `treeError: "timeout"`, not `fail`.
  - K2 `MCPActMachineTests.testAPointTapNamesTheNodeUnderIt` `[MCP-87]`:
    latest tree (snapshot 4) has s4e1 box `[108,1440,972,1680]` (click) inside
    s4e0 `[0,0,1080,2400]`; tap at (0.5, 0.65) on 1080×2400 → `did.hit.ref == "s4e1"`,
    `on.snapshot` = that tree's.
  - K2 `MCPActMachineTests.testATapByRefNamesItsNode` `[MCP-108]`: latest
    tree row `s4e5` Button "Add to cart" → `did.node == {role: "Button", text: "Add to cart"}`;
    `testATimeoutCarriesItsReason` `[MCP-107]`: `settle.reply(still_changing, reason: loading)`
    → `settle == {state: still_changing, reason: loading, waitedMs: 2000}`.
  - K2 `MCPCoreTests.testObserveDefaultsToTree` `[MCP-82]`: `tap {window:3, x:.5, y:.5}`
    → `.tap(…, observe: .tree)`.
  - K2 `UITreeTests.testLoadingPassesThrough` `[MCP-103]`: a reply row
    `{"loading":true}` and reply `loading: true` → both in the encoded answer.
  - K2 `PhoneReadQueueTests.testTwoClientsReadsAreSerialised` `[MCP-9]`: two
    `ui_tree` calls at once → the session sees one `ui.tree`, then the second
    after the first reply; neither answer is `busy`.
  - K2 `WindowActQueueTests.testCallsOnOneWindowRunInOrder` and
    `testThePersonsInputDuringASettleIsReported` `[MCP-84]`: a pointer event
    on window 3 during call A's settle → A's answer `alsoActed == ["person"]`.
  - e2e `suite_act.py` `[MCP-81]`: `tap {window, x:.5, y:.65}` →
    `settle.state == "settled"`, `120 ≤ settle.waitedMs ≤ 1000`, `tree.nodes`
    non-empty, no `ok` key; with fake `--never-settle` → `still_changing`,
    `waitedMs` 2000 ± 100, `reason: "changes"`, call returns in < 3.5 s; with
    `--settle-loading` → `reason: "loading"` and `tree.loading == true`.
  - e2e `suite_act.py` `[MCP-83]`: fake `--close-on-back`; `press_key back`
    → `state: "closed"`, `closed.reason: "app_exited"`, `isError` false.
  - e2e `suite_act.py` `[MCP-8]`: fake `--ignore-ui-settle` → `tap` answers
    `settle.state: "still_changing"` (deadline) within 2 s + 3 s.
  - e2e `suite_act.py` `[MCP-64]`: `screenshot {wait: "settle"}` → answer
    has `settle`.
  - emulator ⚠ `[MCP-81]`: round 1's Calculator arithmetic by refs with
    default arguments — no `ui_tree` call between taps; every answer
    `settled` and its tree shows the digit typed.
- **Tier** K2, e2e, emulator. **Depends** T1, T3, B1.

## B2 — Phone: keys that live as long as their node; heading; covered

- **Closes** — (#170's heading item; T9 closed #170). **Rows** MCP-71 (phone half), MCP-72, MCP-73. **Wire** yes: `k`, `heading`, `covered` on a `ui.tree` row (PROTOCOL.md "UI tree" item 9). The phone still sends no `ref` (S1); the Mac keeps issuing `s<snapshot>e<row>` until T10. **Review** ⚠ protocol.
- **Files** `UiTree.kt` (shaping: `k`, heading, covered by drawing order and
  layer), new `UiTreeKeys.kt` (pure identity→key table, 4096 cap),
  `UiAutomationTree.kt` (pass `isHeading`, `drawingOrder`, window `layer`,
  node identity; keep the latest read's nodes per display for B3),
  `UiTreeTest.kt`, new `UiTreeKeysTest.kt`, `tools/fakephone/fakephone.py`
  (stable keys: the fixed tree's rows keep `k` 1…3; a `--tree-variant` flag
  that adds a heading row, a covered button, and a second read that drops
  `k: 2`).
- **Tests**
  - K1 `UiTreeKeysTest.testANodeKeepsItsKeyAcrossReads` `[MCP-71]`: read 1
    identities {A, B} → 1, 2; read 2 {B, C} → B is 2, C is 3.
  - K1 `UiTreeKeysTest.testAKeyIsNeverReused` `[MCP-71]`: A gone in read 2
    and back in read 3 → A is 1 again while remembered; after 4096 newer
    identities evict it → a new key, never 1 for another node.
  - K1 `UiTreeTest.testAHeadingIsMarked` `[MCP-72]`: node with `heading=true`
    → row has `"heading":true`; false → key absent.
  - K1 `UiTreeTest.testAPointUnderALaterSiblingIsCovered` `[MCP-73]`: link L
    box `[0,2200,1080,2300]` drawing order 1, banner close C box
    `[900,2180,1080,2320]` drawing order 2 in a sibling branch, both
    clickable → L's `at` (0.5, 0.937) is not inside C → no `covered`; with C
    `[0,2180,1080,2320]` → L has `"covered":<C's k>`, C has none.
  - K1 `UiTreeTest.testAWindowAboveCoversTheNode` `[MCP-73]`: an overlay
    window of higher layer with no readable node over the point → `"covered":"window"`.
  - K1 `UiTreeTest.testAChildIsNotCoveredByItsOwnParent` `[MCP-73]`.
  - emulator ⚠: two reads of an idle Calculator → identical `k` per node.
- **Tier** K1, fake-phone selfcheck, emulator. **Depends** —.

## T11 — `wait`: a clock and a condition

- **Closes** #166 (with T5). **Rows** MCP-96, MCP-97, MCP-111. **Wire** consumes `ui.settle` (B1) for `settle: true`. **Review** ⚠ concurrency (a polling loop with a deadline).
- **Files** `MCPCore.swift` (the `wait` tool, its schema and description),
  new `MCPWait.swift` (pure poll plan: next read time, match test),
  new `MCPTools+Wait.swift`, tests, new `macos/scripts/mcp/suite_wait.py`.
- **Tests**
  - K2 `MCPCoreTests.testWaitNeedsMsOrText` `[MCP-96]`: `{window: 3}` →
    `-32602` "wait needs ms, text or settle"; `{window:3, ms: 30001}` → `-32602`.
  - K2 `MCPWaitTests.testAPlainWaitReturnsAfterMs` `[MCP-96]`: injected clock;
    `ms: 5000` → answer at 5000, `waitedMs: 5000`, no `until`.
  - K2 `MCPWaitTests.testWaitForTextPollsAtMostTwiceASecond` `[MCP-97]`:
    text `"00:05"`, trees whose text is `00:03`, `00:04`, `00:05.1` at reads
    1–3 → reads at 0, 500, 1000 ms; answer `until: "met"`, `match.ref` the
    node; never two reads < 500 ms apart.
  - K2 `MCPWaitTests.testGoneWaitsForDisappearance` and
    `testTimeoutIsNotAnError` `[MCP-97]`: never met in `timeoutMs: 1500` →
    `until: "timeout"`, `isError` false.
  - e2e `suite_wait.py` `[MCP-96]`: `wait {window, ms: 1000}` returns in
    1000–1500 ms; `[MCP-97]` `wait {window, text: "Continue"}` → `met`, `match.ref` the Continue button's ref in the fake's tree.
  - K2 `MCPWaitTests.testWaitUntilSettledAnswersWhenTheDisplaySettles` and
    `testWaitUntilSettledTimesOutWithItsReason` `[MCP-111]`: settle answers
    settled at 900 ms → `until: "met"`, `waitedMs: 900`; still loading at
    `timeoutMs: 2000` → `until: "timeout"`, `reason: "loading"`, `isError` false.
  - K2 `MCPCoreTests.testSettleTakesNoMsOrText` `[MCP-111]`: `{window: 3,
    settle: true, ms: 500}` → `-32602`.
  - e2e `suite_wait.py` `[MCP-111]`: a fake phone whose settle answers after
    1200 ms → `met`, `waitedMs` ≥ 1200.
- **Tier** K2, e2e. **Depends** T5.

## B3 — Phone: `ui.press`

- **Closes** — (#166 with T10). **Rows** MCP-86, MCP-89, MCP-108 (phone half). **Wire** yes: `ui.press` both ways, by `k`, answering the node's `role`, `text`, `desc` (PROTOCOL.md "UI tree" item 8). **Review** ⚠ protocol, concurrency (input injection off the a11y thread).
- **Files** new `UiPress.kt` (pure decision: node state → press or code),
  `UiAutomationTree.kt` (resolve `k` against the latest read, `refresh()`,
  bounds, off-screen, covered, the label as read now), `Session.kt` (`ui.press` dispatch; inject through the
  same injector and timestamps as TOUCH), new `UiPressTest.kt`,
  `tools/fakephone/fakephone.py` (`ui.press`: logs a `touch` event at the
  node's `at`, answers `box`/`at`/`role`/`text`; `gone` for a `k` not in its
  latest tree; `covered` for the `--tree-variant` covered button; `--relabel`:
  the button's text at the press differs from the tree's, so a press with the
  tree's `expect` answers `changed`).
- **Tests**
  - K1 `UiPressTest.testAPresentVisibleNodeIsPressedAtItsCentreNow` `[MCP-86]`:
    latest read had k 5 at `[0,0,100,100]`; refresh gives `[0,500,100,600]` →
    decision `Press(50, 550)`, answer `box [0,500,100,600]`.
  - K1 `UiPressTest.testThePressAnswersTheLabelItPressed` `[MCP-108]`: text
    "Add to cart" at the read and at `refresh()` → the reply's `text` is
    "Add to cart", `role` "Button"; a password node → no `text`.
  - K1 `UiPressTest.testANodeThatNowReadsDifferentlyIsNotPressed` `[MCP-86]`
    (#188): `expect` "Add to cart", "Buy now" at `refresh()` → `changed`, `now`
    "Buy now", nothing injected; a row with no label of its own compares the
    first labelled node under it.
  - K1 `UiPressTest.testAnOffScreenNodeIsNotPressed` `[MCP-86]`: bounds now
    below the display → `off_screen`, nothing injected.
  - K1 `UiPressTest.testAGoneNodeIsNotPressed` `[MCP-86]`: refresh false →
    `gone`, nothing injected; unknown key 999 → `gone`.
  - K1 `UiPressTest.testAnInvisibleNodeIsNotPressed` → `not_visible`.
  - K1 `UiPressTest.testACoveredNodeIsNotPressed` `[MCP-89]` → `covered`,
    `coveredBy` the cover's ref.
  - K1 `SessionTest.testUiPressHoldsForHoldMs` `[MCP-86]`: `holdMs: 800` →
    down at t, up at t+800 (fake injector clock).
  - emulator ⚠: Calculator, read, then press `e<digit 7>` → display shows 7;
    scroll a list between read and press → the press lands on the same item
    at its new place.
- **Tier** K1, fake-phone selfcheck, emulator. **Depends** B2.

## T10 — Mac: tap by ref goes to the phone; refs survive reads

- **Closes** — (#166's "7 reads for 7 taps", with T5). **Rows** MCP-71 (Mac half), MCP-72/73 parse, MCP-86, MCP-89, MCP-108 (target stage). **Wire** consumes `k`, `ui.press`, `heading`, `covered`. **Review** ⚠ protocol.
- **Files** `ConnectionController.swift` (`uiPress(stream:k:holdMs:)` via
  `PhoneReadQueue`), `Session.swift` (send/parse `ui.press`), `UITree.swift`
  (parse `k`, `heading`, `covered`; name refs `e<k>` in place of S1's
  `s<snapshot>e<row>`, and a covering key as its ref; the Mac's ref table
  stops refusing older refs — it becomes the echo cache of the latest tree for
  `hit` and maps `e<k>` back to `k`), `MCPTools+Input.swift` (the Pressing
  path; `did.node` from the press's reply), `MCPCore.swift` (the `tap` and
  `ui_tree` descriptions' ref sentence only: S1's "A ref works only from the
  window's latest tree; an older one is refused." becomes "A ref names one
  element for as long as it is on screen, across reads; a ref whose element is
  gone is refused.", MCP-71), `UITreeTests.swift`, `MCPCoreTests.swift`, new
  `macos/scripts/mcp/suite_refs.py`.
- **Tests**
  - K2 `UITreeTests.testHeadingAndCoveredPassThrough` `[MCP-72]`/`[MCP-73]`:
    a reply row `{"heading":true,"covered":"e9"}` → the encoded result
    carries both; absent → absent.
  - K2 `MCPActMachineTests.testAGonePressIsStaleRefAndPressesNothing` `[MCP-86]`
    (machine already has the row from T5; this task wires it): runner with a
    fake session that answers `ui.press ok:false code gone` → tool result
    `stale_ref`, the session saw no TOUCH frame.
  - e2e `suite_refs.py` `[MCP-86]`: `ui_tree` (read 1) → `ui_tree` (read 2) →
    `tap {ref: "e1"}` (from read 1) → not an error; the fake's event log has
    one `touch` at e1's `at`; the answer's `did.box` equals the fake's box.
  - e2e `suite_refs.py` `[MCP-86]`: fake `--tree-variant` second read drops
    `k: 2` → `tap {ref: "e2"}` → `stale_ref`, no `touch` in the log.
  - e2e `suite_refs.py` `[MCP-89]`: the covered button → `covered`,
    `coveredBy` present, no `touch`.
  - e2e `suite_refs.py` `[MCP-108]`: fake `--relabel` → `did.node.text` is the
    label at the press, not the tree's.
  - K2 `UITreeTests.testRefsAreTheKeys` `[MCP-71]`: a reply row `{"k":12}` →
    ref `"e12"`; `covered: 31` → `"e31"`; no ref matches `^s\d+e\d+$`.
  - K2 `MCPToolErrorTests.testAGoneRefSendsTheAgentToANewTree` `[MCP-71]`:
    `ui.press` `gone` for e12 on window 3 whose latest snapshot is 6 →
    `stale_ref`, message `e12 is no longer on window 3: the screen changed after its latest tree (snapshot 6). Call ui_tree and use a ref from it.`
  - K2 `MCPCoreTests.testTheRefRuleIsOneSentence` `[MCP-71]`: the `tap` and
    `ui_tree` descriptions contain the target sentence and not S1's.
- **Tier** K2, e2e, emulator (B3's run, driven through the tool). **Depends** T5, B3.

## T7 — Windows say who opened them and why they closed

- **Closes** #168 (with T6). **Rows** MCP-50, MCP-51, MCP-52, MCP-53, MCP-54 (answer), MCP-102. **Wire** no. **Review** normal.
- **Files** new `macos/Sources/Contigua/MCPWindowLedger.swift` (pure: open,
  raise, close records, the 16/10-minute window, relative `openedBy`),
  `WindowManager.swift` (report opens with their opener and closes with their
  reason at the one open-or-raise and close paths), `MCPTools+Windows.swift`,
  `MCPToolHost.swift` (`requireWindow` adds `closed` to `no_window`), new
  `MCPWindowLedgerTests.swift`, new `macos/scripts/mcp/suite_windows.py`.
- **Tests**
  - K2 `MCPWindowLedgerTests.testOpenedByIsRelativeToTheAsker` `[MCP-51]`:
    client 1 opens w3, the person opens w4 → client 1 sees w3 `you`, w4
    `person`; client 2 sees w3 `another_agent`.
  - K2 `MCPWindowLedgerTests.testARaiseKeepsTheFirstOpener` `[MCP-51]`.
  - K2 `MCPWindowLedgerTests.testEveryCloseKeepsItsReasonAndCloser` `[MCP-52]`:
    one test per mapping row of design/mcp.md "Windows and who opened them"
    (e.g. wire `requested` → `phone_closed`/`phone`; ⌘W → `closed`/`person`;
    Use This Phone → `phone_switched`).
  - K2 `MCPWindowLedgerTests.testOnlyTheLast16ForTenMinutesAreKept` `[MCP-52]`:
    17 closes → 16 kept; a close at t=0 is gone at t=600.001 s.
  - K2 `MCPToolErrorTests.testAClosedWindowSaysWhyItClosed` `[MCP-53]`: w4
    closed `app_exited` 3 s ago → `no_window`, `closed == {reason: app_exited, closedBy: phone, closedAgoMs: 3000}`,
    message `Window 4 closed 3 s ago: the app exited. Call list_windows to see what is open.`
  - K2 `MCPWindowLedgerTests.testRowsCarryKindOriginAgeAndState` `[MCP-50]`.
  - e2e `suite_windows.py` `[MCP-53]`: two shim clients; A opens Settings,
    B calls `close_window` on it → A's `list_windows` has it in
    `recentlyClosed` with `closedBy: "another_agent"`; A's `tap` on it →
    `no_window` with that `closed`.
  - K2 `MCPWindowLedgerTests.testADisconnectedClientsWindowsStayOpenAndKeepTheirOpener` `[MCP-102]`:
    client 1 opens w3 and disconnects → w3 is still open, no close record;
    client 2 and a new client 3 see `openedBy: another_agent`.
  - e2e `suite_windows.py` `[MCP-102]`: client A opens Settings and exits;
    client B's `list_windows` has it with `openedBy: "another_agent"`, and the
    fake phone's log has no `window.close`.
- **Tier** K2, e2e. **Depends** T1 (client id).

## B4 — Phone: which source said `locked`

- **Closes** — (#167 with T8). **Rows** MCP-31 (phone half). **Wire** yes: `state.lockSource`. **Review** ⚠ protocol.
- **Files** `AndroidDeviceState.kt`, `DeviceStateTracker.kt` (the tracker
  records the source with each lock change; a change of source alone is a
  change), the `state` serialiser in `Session.kt`, their tests,
  `tools/fakephone/fakephone.py` (`lockSource` in `state`, `--lock-source`).
- **Tests**
  - K1 `DeviceStateTrackerTest.testEveryLockChangeNamesItsSource` `[MCP-31]`:
    initial read locked=true → source `initial_read`; keyguard listener
    false → `keyguard_listener`; broadcast with the same value → no new state
    unless the source differs, then one state with `broadcast`.
  - K1 `SessionTest.testStateCarriesLockSource` `[MCP-31]`: the serialised
    `state` has `"lockSource":"keyguard_listener"`.
- **Tier** K1, fake-phone selfcheck. **Depends** —.

## T8 — `phone_status` says what locked means and what is in front

- **Closes** #167. **Rows** MCP-31, MCP-32. **Wire** consumes `state.lockSource`; `task.front` unchanged. **Review** normal.
- **Files** `MCPTools+Phone.swift`, `ConnectionController.swift` (an MCP
  `task.front` read sharing the panel's seq and its 2 s budget), `Session.swift`
  (parse `lockSource`; keep `locked`'s change time), new
  `MCPToolHostTests.swift` cases, new `macos/scripts/mcp/suite_status.py`.
- **Tests**
  - K2 `MCPToolHostTests.testStatusSaysWhatLockedMeans` `[MCP-31]`: state
    `{locked: true, screen: "off", lockSource: "keyguard_listener"}` received
    360 s ago → answer `locked: true`, `screen: "off"`, `lockSource:
    "keyguard_listener"`, `lockChangedAgoMs: 360000`, `input` equals the
    spec's sentence; no phone → `locked: null`, `screen: null`.
  - K2 `MCPToolHostTests.testStatusNamesTheForegroundApp` `[MCP-32]`:
    `task.front` answers `org.example.browser` with Browser in the app list →
    `foreground: {package: "org.example.browser", label: "Browser"}`;
    `pkg: null` → `foreground: null`, no `foregroundError`; `not_available` →
    `foregroundError: "not_supported"`; silence → `"timeout"` at 1 s; a card read 1 s earlier → no new `task.front`, its answer reused.
  - K2 `MCPToolHostTests.testTwoStatusCallsInTwoSecondsShareOneRead` `[MCP-32]`.
  - e2e `suite_status.py` `[MCP-32]`: fake phone's `task.front` package →
    `foreground.package` equals it; `--ignore-task-front` → `"timeout"`.
- **Tier** K2, e2e. **Depends** T1, B4.

## T6 — Opens answer like actions

- **Closes** #168 (with T7). **Rows** MCP-41 (with `size`, today's window size until T12), MCP-42, MCP-43, MCP-44. **Wire** no. **Review** ⚠ state machine (the Opening entry of `MCPActMachine`, wired here).
- **Files** `MCPCore.swift` (`wait`/`observe` on `open_app`/`send_link`),
  `MCPTools+Open.swift`, `ConnectionController.swift` (an MCP open that does
  not queue while offline; an awaitable `drop.result` for one drop id),
  `IntentsBridge.swift` (return the link window's stream from
  `WindowManager.openLink`), tests, new `macos/scripts/mcp/suite_open.py`.
- **Tests**
  - K2 `MCPActMachineTests.testAnOpenWaitsForTheFirstFrameThenSettles` `[MCP-41]`:
    Opening + `window.opened` → Opening; + `firstFrame` → Settling; +
    `settle.reply(settled)` → Observing … answer `opened: new`, `openedBy: you`,
    `size` the stream's `[w, h]`.
    Opening + open bound (10 s) → Done `[answer(state: opening, settle: {state: not_ready})]`.
  - K2 `MCPToolHostTests.testOfflineOpensQueueNothing` `[MCP-42]`: link
    offline → `open_app` → `phone_offline`, `pendingOpen` nil; `send_link`
    → `phone_offline`, `pendingLink` nil.
  - K2 `MCPToolHostTests.testSendLinkAnswersTheWindowItOpened` `[MCP-43]`:
    answer `window` equals the stream `WindowManager.openLink` allocated,
    `kind: "link"`; `launch_failed` → `failed` with `window`.
  - K2 `MCPToolHostTests.testSendFileWaitsForTheDropResult` `[MCP-44]`:
    `drop.result ok` after 200 ms → `{bytes: N, state: "delivered"}`; none in
    30 s → `state: "sending"`; `ok: false` → `failed` with the phone's sentence;
    the answer has no `name`/`path` key.
  - e2e `suite_open.py` `[MCP-41]`: `open_app {app: "Settings"}` → `opened:
    "new"`, `settle.state: "settled"`, `tree.nodes` non-empty; again →
    `opened: "raised"`; `[MCP-43]` `send_link` → `window` present in
    `list_windows` with `kind: "link"`; `[MCP-44]` the 1 MiB file →
    `state: "delivered"`.
- **Tier** K2, e2e, emulator (open Calculator lands on its last screen and the
  tree shows it). **Depends** T5, T7.


## B6 — Phone: the tree says what it does not show

- **Closes** — (round 1b's papercuts on #166 and #172). **Rows** MCP-104, MCP-105, MCP-106 (phone half and the Mac's pass-through). **Wire** yes: `hint`, `hintText`, a layer's `active` (its `focused` dropped), `focus` only in the active layer, off-screen rows left out, a scrollable's `hidden`, the reply's `omitted`, the `offscreen` request field (PROTOCOL.md "UI tree" item 9). **Review** ⚠ protocol.
- **Files** `UiTree.kt` (shaping: hint, the active layer and its one focus,
  leaving out `off` rows, `hidden`, `omitted`, `offscreen`),
  `UiAutomationTree.kt` (pass `isShowingHintText`, `hintText`, the layer's
  `isFocused`, `findFocus(FOCUS_INPUT)` on the active layer's root),
  `Session.kt` (read `offscreen` from the request), `UiTreeTest.kt`,
  `tools/fakephone/fakephone.py` (the fixed tree gains a hint field, a second
  layer and a list with off-screen rows; `offscreen: true` sends them `off`),
  `macos/Sources/Contigua/UITree.swift` (parse and encode `hint`, `hintText`,
  `hidden`, `omitted`, a layer's `active`; no `focused`),
  `macos/Tests/ContiguaTests/UITreeTests.swift`.
- **Tests**
  - K1 `UiTreeTest.testAShownHintIsNotText` `[MCP-104]`: an EditText whose
    text is its hint "Search products" with `showingHint` true →
    `{"hint":true,"hintText":"Search products"}`, no `text`; holding "milk" →
    `"text":"milk"`, no hint keys.
  - K1 `UiTreeTest.testOnlyTheActiveLayersFocusIsSent` `[MCP-105]`: layer 0
    (an app) and layer 1 (a dialog), each with a focused EditText, layer 1
    `isFocused` → only layer 1's node has `"focus":true`; layers
    `[{"i":0,…},{"i":1,"active":true,…}]`; no `focused` key; no layer focused →
    no `active` and no `focus`.
  - K1 `UiTreeTest.testOffScreenNodesAreCountedNotSent` `[MCP-106]`: a list
    with 3 rows above the display, 4 on it and 112 below → 4 rows sent, the
    list's row `"hidden":[3,112]`, the reply `"omitted":115`; a list with
    nothing off screen → no `hidden`; `"omitted":0` on a fully visible screen.
  - K1 `UiTreeTest.testOffscreenTrueSendsThemMarked` `[MCP-106]`: the same
    list with `offscreen: true` → 119 rows, 115 with `"off":true` and no `at`,
    `omitted: 0`.
  - K2 `UITreeTests.testHintPassesThrough` `[MCP-104]`,
    `testActivePassesThroughAndFocusedIsGone` `[MCP-105]`,
    `testHiddenAndOmittedPassThrough` `[MCP-106]`: each reply field reaches
    the encoded answer, and a layer's `focused` from an old fake is dropped.
  - emulator ⚠: a search screen with an empty field → `hint: true`, no
    `text`; the same screen with the keyboard up → the IME layer is not
    `active` and only the app's field has `focus`; a long settings list →
    `hidden` on the list and `omitted` equal to its off-screen rows.
- **Tier** K1, K2, fake-phone selfcheck, emulator. **Depends** — (B2 for the
  shared files' order: round 2 before this one).

## B5 — Phone: `ui.type`, typing that never touches the clipboard

- **Closes** — (#173 with T13). **Rows** MCP-109, MCP-110 (phone half). **Wire** yes: `ui.type` both ways (PROTOCOL.md "UI tree" item 10). **Review** ⚠ security (it writes into another app's field and must never touch the clipboard), protocol, concurrency (accessibility actions off the event thread).
- **Route chosen** (design/mcp.md "Typing without the clipboard"): key-map
  text as KEY events at the cursor; any other text, whole, by
  `ACTION_SET_TEXT` on the active layer's focused node with the text before
  and after the selection kept, then `ACTION_SET_SELECTION`. It costs: set
  text replaces the field's whole text (the phone rebuilds it, so the person
  sees an insertion, but the field's undo history and composing span reset);
  a password field holding text can only be replaced (`clear: true`), because
  its text cannot be read; a view that draws its own text (a game, a terminal,
  a canvas editor) offers no `ACTION_SET_TEXT` and gets `not_supported` for
  text outside the key map. No clipboard fallback exists.
- **Files** new `android/app/src/main/java/app/contigua/server/TextEntry.kt`
  (pure: the text, the focused node's editable/password/hint state, its text
  and selection, and whether it offers `ACTION_SET_TEXT` → a plan of keys, a
  set text and a selection, or a refusal code), `UiAutomationTree.kt` (find
  the active layer's input focus, B6; perform `ACTION_SET_TEXT` and
  `ACTION_SET_SELECTION`), `Session.kt` (`ui.type` dispatch under the one
  `ui.*` flag; keys through the same injector and timestamps as KEY frames),
  `AndroidInjector.kt` (a key-map-only key method beside `text`, which it does
  not change), new `TextEntryTest.kt`, `SessionTest.kt`,
  `tools/fakephone/fakephone.py` (`ui.type`: logs `type` with its character
  count, `via` and `entry`; `--type-refuse CODE` answers that code).
- **Tests**
  - K1 `TextEntryTest` `[MCP-109]`, one test per decision, e.g.
    `testKeyMapTextIsKeys`: "milk 42" → keys, `entry: inserted`, `via: keys`;
    `testOtherTextIsSetAtTheCursor`: field "garrafa 500ml", selection (8, 8),
    typed "térmica " → set "garrafa térmica 500ml", selection (16, 16);
    `testASelectionIsReplaced`: selection (0, 7) → set "térmica 500ml";
    `testNoSelectionGoesAtTheEnd`; `testAShownHintCountsAsEmpty`: hint
    showing, typed "café" → set "café";
    `testClearReplaces` (`entry: replaced`, with and without set text);
    `testAPasswordWithTextNeedsClear` → `not_supported`;
    `testNoFocusForOtherTextIsNoField` → `no_field`;
    `testNoFocusForKeyMapTextIsUnknown` → keys, `entry: unknown`;
    `testNoSetTextActionIsNotSupported`; `testARefusedActionFails` → `failed`,
    nothing else performed.
  - K1 `TextEntryTest.testNoRouteTouchesTheClipboard` `[MCP-110]`: a
    recording clipboard handed to every path above sees no call.
  - K1 `SessionTest.testUiTypeAnswersHowItTyped` `[MCP-109]`:
    `{"t":"ui.type","stream":3,"seq":1,"text":"café"}` with a fake source →
    `{"t":"ui.type","stream":3,"seq":1,"ok":true,"entry":"inserted","via":"set_text","characters":4}`;
    a `ui.tree` during it → `busy`.
  - K1 `AndroidInjectorTest.testANonTextClipSurvivesTyping` `[MCP-110]`
    (#173's failing test, on the old `text` path, kept as the record of the
    bug and marked expected-to-fail until the person's path moves: the
    spec's open question).
  - emulator ⚠ `[MCP-109]`/`[MCP-110]`: an `EditText` (the emulator's
    contacts editor), a WebView `<input>` on a local page and a Compose
    `TextField` (a test screen in the debug build's own activity, or a stock
    app that uses one): `ui.type "garrafa térmica 500ml"` with the cursor
    inside existing text → the field reads before + typed + after, the cursor
    after the typed text; a field with no `ACTION_SET_TEXT` (a local canvas
    page) → `not_supported` and the field unchanged; a clip set before the
    run is the same afterwards (its description and first item), and no
    clipboard-access toast is posted during any call.
- **Tier** K1, fake-phone selfcheck, emulator. **Depends** B6 (the active
  layer's focus).

## T12 — An agent's new window takes the phone's shape

- **Closes** #175. **Rows** MCP-100, MCP-101, MCP-41 (`size`), WIN-5's and WIN-13's exceptions. **Wire** no: `window.open`/`link.open` already carry `w`, `h`, `dpi`, and `welcome.device.screen` the phone's size and dpi. **Review** ⚠ state machine (the hand-back flag) and geometry.
- **Files** new `macos/Sources/Contigua/AgentWindowShape.swift` (pure: the
  phone's screen, the encoder's alignment and limits, the visible frame and
  the style's chrome → stream pixels, dpi and window points),
  `MCPCore.swift` (`shape` on `open_app`/`send_link`, its schema),
  `MCPTools+Open.swift` (pass the shape; answer `size`), `WindowManager.swift`
  (open with a shape; a phone-shape window does not read or write the
  remembered frame), `AppWindow.swift`, `LinkWindow.swift` (the first size
  from the shape), `StreamWindow.swift` (the hand-back: a person's resize,
  Zoom, tiling or full screen clears the phone shape; a move does not),
  `VideoGeometry.swift` (the phone shape's size in place of WIN-5's while the
  shape holds), `WindowDensity.swift` (a density change hands back; the
  open question decides whether the shape ignores an override), new
  `AgentWindowShapeTests.swift`, new `macos/scripts/mcp/suite_shape.py`,
  `docs/specs/app-windows.md` (WIN-5 and WIN-13's proof cells only).
- **Tests**
  - K2 `AgentWindowShapeTests.testA1080x2340PhoneAt450Dpi` `[MCP-100]`: dp
    384×832; alignment 2 → 590×1280 px at 246 dpi; alignment 16 → 576×1280 at
    240 dpi; stream area 384×832 pt.
  - K2 `AgentWindowShapeTests.testA1440x3120PhoneAt600Dpi` `[MCP-100]`: dp
    384×832; alignment 2 → 590×1280 at 246 dpi.
  - K2 `AgentWindowShapeTests.testALandscapeReportIsTurnedPortrait`
    `[MCP-100]`: `screen {w: 2340, h: 1080, dpi: 450}` → the same as 1080×2340.
  - K2 `AgentWindowShapeTests.testTheWindowFitsTheVisibleFrame` `[MCP-100]`:
    a 1280×800 pt screen with a 775 pt visible height and Framed's 43 pt of
    chrome → the stream area's height is 732 pt and its width keeps the
    aspect (338 pt).
  - K2 `AgentWindowShapeTests.testAPhoneShapeWindowRemembersNoFrame`
    `[MCP-100]`, `testThePersonsResizeHandsTheWindowBack` `[MCP-101]`,
    `testADensityChangeHandsTheWindowBack` `[MCP-101]`, `testAMoveKeepsTheShape`
    `[MCP-101]`, `testARaiseKeepsTheShape` `[MCP-101]`.
  - K2 `MCPCoreTests.testShapeIsPhoneOrWindow` `[MCP-100]`: no `shape` →
    `.phone`; `"window"` → `.window`; `"tablet"` → `-32602`.
  - e2e `suite_shape.py` `[MCP-100]`: `open_app {app: "Settings"}` → the fake
    phone's `window.open` has `h > w`, `max(w, h) ≤ 1280`, and
    `w × 160 ÷ dpi` within 1 dp of the fake's own `screen` width in dp; the
    answer's `size` equals `[w, h]`; `open_app {app: "Settings", shape:
    "window"}` after closing it → today's size and dpi.
  - e2e `suite_shape.py` `[MCP-101]`: a debug-control resize of the
    phone-shape window → one `window.resize` at WIN-5's size for the new
    frame; `open_app` again → `opened: "raised"`, `size` unchanged, no
    `window.open`.
- **Tier** K2, e2e, emulator (a shopping-style list app opened by an agent
  lays out as on the phone: the tree's root `size` is portrait). **Depends**
  T6 (the opened-window answer).

## T13 — `type_text` goes through `ui.type`

- **Closes** #173 with B5 and T14 (the last of the three to merge names it). **Rows** MCP-92 (target), MCP-109 and MCP-110 (Mac half). **Wire** consumes `ui.type`. **Review** ⚠ security (no clipboard on the Mac side either), state machine (the Typing state).
- **Files** `MCPCore.swift` (`type_text`'s `clear`/`submit` and its output
  schema), `MCPTools+Input.swift` (the Typing path), `MCPActMachine.swift`
  (Typing: `type.ok` → Sent, `type.failed` → Done), `ConnectionController.swift`
  (`uiType(stream:text:clear:submit:)` via `PhoneReadQueue`), `Session.swift`
  (send and parse `ui.type`; the tool stops sending `text`),
  `MCPToolHostTests.swift`, `MCPActMachineTests.swift`, new
  `macos/scripts/mcp/suite_type.py`.
- **Tests**
  - K2 `MCPActMachineTests` `[MCP-109]`: Queued + turn(type) → Typing,
    `[sendType]`; + `type.ok(inserted, set_text)` → Settling; +
    `type.failed(no_field)` → Done `[fail(no_field)]`; Typing + `windowClosed`
    → `fail(no_window)`; Typing + `linkLost` → `fail(phone_offline)`.
  - K2 `MCPToolHostTests.testTypeTextAnswersHowItTyped` `[MCP-92]`/`[MCP-109]`:
    `type_text {window: 3, text: "café", clear: true, submit: true}` → the
    session sent `{"t":"ui.type","stream":3,…,"text":"café","clear":true,"submit":true}`
    and no `text` message; `did == {action: type, characters: 4, clear: true, submit: true, entry: replaced, via: set_text}`;
    the log hook saw no text.
  - K2 `MCPToolHostTests.testTypeTextNeverTouchesThePasteboard` `[MCP-110]`:
    the general pasteboard's change count is the same before and after.
  - e2e `suite_type.py` `[MCP-109]`: the fake's log has one `type` with
    `characters: 4`; `--type-refuse not_supported` → `isError`, `error.code ==
    "not_supported"`, the sentence names `clear: true`.
- **Tier** K2, e2e, emulator (B5's run, driven through the tool). **Depends**
  T5, B5.

## T14 — The person's typing never loses their clip

- **Closes** #173 with B5 and T13 (the last of the three to merge names it). **Rows** WIN-80. **Wire** no. **Review** ⚠ security (it writes into another app's field, and its fallback writes the clipboard), concurrency (one paste at a time).
- **Files** `android/app/src/main/java/app/contigua/server/AndroidInjector.kt`
  (`text`: key-map runs as keys, other runs through B5's `TextEntry` plan and
  `UiAutomationTree`'s set text, then the fallback), `ShellClipboard.kt` (save
  and restore a whole `ClipData`; mark the temporary clip so SHARE-1 skips it,
  as `isOurClip` skips the app's own image clips today), `AndroidInjectorTest.kt`,
  `docs/specs/app-windows.md` (WIN-80 from target to shipped).
- **Work**
  1. A `text` run the key map cannot produce goes in through `TextEntry`
     exactly as `ui.type` does (MCP-109) when the focused node offers
     `ACTION_SET_TEXT`. No clipboard call on that path.
  2. Otherwise, the fallback, under one lock: save the whole primary
     `ClipData` (or that there was none), set the run, inject `KEYCODE_PASTE`,
     put the saved clip back. If the saved clip cannot be put back whole (a URI
     the shell cannot hand back, a clip the system will not let it read), do
     not paste: drop the run and log its length only.
  3. The temporary clip is marked as ours, and the phone's SHARE-1 watcher
     never sends it to the Mac.
- **Tests** WIN-80's K1 names, each failing first on `main`; the emulator run
  finds out which clip types the shell can put back and the PR says which.
- **Tier** K1, emulator ⚠ (WIN-80's run). **Depends** B5.

---

## After the last task

- Round 2 of the dogfood (#171): the same four tasks, four threads, on the
  build with every task merged; the comparison (calls per task, wrong calls,
  retries, tasks finished) goes on #171.
- WIN-79 in `docs/specs/app-windows.md` is edited by B2/T10 to point at
  MCP-71…73 for refs, heading and covered (its "a ref the latest reply does
  not name SHALL fail" clause, as #162 left it for S1's refs, is replaced, not
  appended to), and by B6 to point at MCP-104…106 for hints, the active layer
  and off-screen rows.
- Every **target** marker in `docs/specs/mcp.md` is gone, each row's proof
  names the merged tests, and this file is deleted.
