# Non-functional requirements (NFR)

The app must not only work; it must also stay fast, readable, honest and free
of side effects. Every limit below lives in one machine-readable file,
`macos/scripts/nfr-limits.json`. The Swift tests read it through
`Tests/PocketDeckTests/NFRTestLimits.swift`; the shell checks read it through
`nfr_limit <key>` in `macos/scripts/check-e2e.sh`. No check carries its own
copy of a limit.

Numbers marked **measured** come from the host e2e run of 2026-10-20 with
profile `nfr1` (the raw lines are in `.agent/nfr-checks/progress.md`). A time
budget is about three times the measured p95, rounded up; the safety limits
(contrast, layout, stale picture, hanging reply) come from the product
promise in `AGENTS.md`, not from a measurement.

## Requirements

| Requirement | Limit (json key) | Measured today | Why | Enforced by |
| --- | --- | --- | --- | --- |
| Connect to a phone | `connect_ms` = 1500 ms | 418–696 ms (launch → `paired`/`auth_ok`) | A person waiting at a spinner loses trust in the app after a few seconds | e2e `nfr` (time limits) |
| First frame of an app window | `first_frame_ms` = 1500 ms | 133 ms (`window.open` → `VIDEO_CONFIG`) | The window must show the app, not a blank surface | e2e `nfr` |
| First frame of the Phone Mirror | `first_frame_phone_ms` = 1500 ms | 136 ms (`window.open` → `VIDEO_CONFIG`) | Mirroring is the app's first screen | e2e `nfr` |
| Panel control redraw | `panel_glyph_ms` = 300 ms | 3–11 ms (click → `panel_off`; the fake answers at once). With a report 1000 ms late, the glyph arrived 4 ms after it | A click must show the phone's new panel state in a person's reaction time: the 16:44 report had the button 2–3 s behind the screen because the phone sent `state.panel` last, after a 1.1 s blocking restore. The Mac draws as soon as the report arrives | e2e `mirror` (bar-control click → `panel_off` in the chrome state, both ways; a `--panel-delay-ms` run pins "state, never the click"); K1 `PanelHoldTest` (report before the platform action) |
| App list | `app_list_ms` = 1500 ms | 60 ms (`apps.list` → its reply) | The Deck is what a person sees first | e2e `nfr` |
| Small Finder fetch | `fetch_small_ms` = 3000 ms | not measured on the host (the files domain is VM-only; pre-fix it was 20 s) | A Quick Look preview is a person's first hour bug: it took 20 s | e2e `files-domain` (VM) |
| Stale picture | `stale_picture_ms` = 2000 ms | — (safety limit) | A frozen frame shown as live makes a person act on a lie | e2e `mirror` and `nfr` |
| Density burst: first frame | `density_burst_first_frame_ms` = 600 ms | — (safety limit; the 10-27 report had 7 s with no frame) | Ten ⌘+/⌘− presses in one second must leave the picture live at the final density, not re-attach the phone's encoder once per press | the emulator burst (`deckctl density-burst`, real encoder: one attach, the frame after the last request); K2 `ResizeCoalescerTests`, K1 `ResizeLedgerTest` |
| Density burst: no stall | `density_burst_stall_ms` = 1500 ms | — (safety limit: the window's own "Not responding" rule) | During the burst no window may go a second and a half without a frame, which is what an overlapping encoder re-attach costs | e2e `density` (ten ⌘+ presses: two requests, never a repeat — the Mac side); the emulator burst measures the phone's gap |
| Control contrast | `contrast_min` = 3.0 | — (safety limit) | Bar controls sit over white, black and busy video | K2 `BarContrastTests` |
| Smallest supported screen | `layout_min_screen` = [1280, 800] | — (safety limit) | Every control must be reachable on the smallest Mac screen we support | K2 `SettingsLayoutTests`, `LayoutTests`; e2e `nfr` |
| Settings design height | `settings_design_height_pt` = 560 pt | 560 | What the 1280×800 layout was designed around | K2 `SettingsLayoutTests` |
| Request/reply return | `hanging_reply_ms` = 100 ms | — (safety limit) | A terminal reply ends a request; a peer that keeps the socket open must not add the 20 s receive timeout | K2 `HangingPeerTests` |
| Input behind a transfer | `input_latency_ms` = 100 ms | 33.1 ms (pathbulk, a 64 MiB drop on a 600 Mbit/s path) | A key typed while a file is being sent must reach the phone in a person's reaction time, not behind the transfer; a 12 MiB queue on a 100 Mbit/s LAN is about a second | e2e `pathbulk` (a KEY sent during a throttled 64 MiB drop reaches the fake phone within the limit, `[PATH-23]`) |
| Icon source size | `icon_min_source_scale` = 1.0 | — (safety limit) | An icon is never upscaled from a smaller source | K2 `IconReferenceTests` |
| Covered flat icon scale | `icon_covered_flat_scale` = 1.3 | 1.3× (visual) | A covered flat (legacy) icon enlarges its crop to the body, so the source is smaller than the tile by design (docs/design/dock.md §Icons). The Deck's 432 px request gives a 288 px flat: 0.84× at worst (a 38 % rounded square), no upscaling. The Dock's 1296 px request gives 864 px: 1.28× at worst, and the crop rule's own ceiling is 1.29×. Anything past 1.3× means the Dock drew a covered icon from the Deck's flat, or the crop rule was widened | K2 `IconReferenceTests.testACoveredLegacyIconStaysInsideTheUpscaleBound` |
| Icon reference tolerance | `icon_mean_tolerance` = 3.0 | — (safety limit) | Renderer output must match the committed references within a few 8-bit levels | K2 `IconReferenceTests` |
| Deck drag frame time | `deck_drag_frame_p95_ms` = 21 ms (quiet; a visible run allows two display intervals, measured per run) | 19 ms (main `805e1c7` + the same display-link harness), 18 ms (this branch); step p50 12.64 ms / p95 15.69 ms on main vs 12.63 / 14.13 on the branch. Visible host runs, 2026-10-27: refresh 16.67 ms, drag step p95 15.3-17.5 ms, drag p95 17 / 23 / 33 ms across runs of the same code — the window server composites a live resize at every refresh at best and every other one at worst | A live drag-resize must not jank, and the branch must not make the window's `setFrame` step dearer. The like-for-like run is main plus the new harness, not the old sample: the probe drives the drag from the same display link that samples it (one resize per frame). 21 = main's 19 + 2 ms | e2e `deck` (display-link drag, `deck-zoom.py`) |
| Deck zoom frame time | `deck_zoom_frame_p95_ms` = 40 ms | 40 ms (~25 fps) | Double-clicking the Deck's title bar must not jank. The grid is laid out from the width of the pass that draws it (`DeckGridLayout`), so it lays out once per pass by design and the old `frames / 3` relayout budget is gone; frame time is the metric. Measured on the e2e host with the phone's 200-app launcher (201 cells, icons settled): p95 17 ms (zoom), 18 ms (unzoom), 18–21 ms (scripted drag-resize, its own row), single frames 43–67 ms; one full layout pass (sizeThatFits + placeSubviews, 201 cells) p95 0.10–0.14 ms, max 0.19 ms. The probe's per-cell geometry observers are part of the sampled frame time, so these are upper bounds. 40 ms leaves room for a settle frame on a 1× host; the strict part is the per-frame fit check (cells inside the visible width, even insets, column count from that frame's width) | e2e `deck` (display-link sampling of `NSWindow.zoom`, a scripted drag-resize, `deck_zoom_frame_p95_ms`) |

The measured values are one warm run against the host `fakephone`; the
budgets are three times the p95 of that run rounded up. A slower Mac has
headroom, and a regression to the old behaviour (a blank window, a 20 s
reply) is far outside them.

## Rules that do not need a number

- **Read-only flows send zero writes.** Browsing the Deck, listing apps and
  icons, opening and closing phone windows, listing/statting/reading through
  the files bridge, entering and leaving Live Text, and watching media state
  must leave the fake phone's `writes` counter unchanged.
- **Frozen modes send zero input.** While the picture is frozen (Live Text in
  an app window or the phone window, screen off, a secure surface hidden by
  Android, disconnected/reconnecting),
  bar controls, menu shortcuts, clicks, scrolls and typing send no input
  event (pointer, key, scroll, hover, or a `nav`/`text` action from a
  control). Leaving the mode restores the same controls.
- **Honest settings.** A control whose capability the build or the phone does
  not have is disabled and says why. An error only suggests a restart when a
  restart would change the state.
- **No stale picture.** When frames stop without a state change, the window
  says so within `stale_picture_ms` instead of presenting the old frame as
  live. A covered or paused window is not a live picture: AppKit throttles an
  occluded app, so its silence is not a stall, and the clock restarts when the
  window is visible again. A power press the phone reports (`power.locked`,
  docs/PROTOCOL.md "Phone screen") is the person's own action: the window holds
  the last frame for the watchdog's grace and only then says so, and the grace
  with one timer tick stays under `stale_picture_ms` (K2 `FrameWatchdogTests`).
- **Drive the real control.** A check that proves a control works goes through
  the event path a person uses (a hit test and mouse events, a menu item, a
  key event), not a debug verb that calls the action directly.

## Running the gate

```sh
macos/scripts/nfr.sh
```

It runs the NFR K2 tests (`NFRTestLimits`, `BarContrastTests`,
`SettingsLayoutTests`, `LayoutTests`, `HangingPeerTests`,
`HonestSettingsTests`, `IconReferenceTests`, `ControlsRealPathTests`) and the
host e2e check `nfr`, one after the other through the machine-wide heavy lock
(never beside a second heavy step). On a UI or protocol change, run it before
asking for review.

`nfr.sh` uses `PD_E2E_PORT` (47980) and `PD_E2E_PROFILE` (nfr1), like the
single-check command above. A red run names the limit and the measured value;
`failures` in `nfr` are product bugs, not flaky numbers, so read the line
before re-running.
