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
| Connect to a phone | `connect_ms` = 1500 ms | 418 ms (launch → `paired`/`auth_ok`) | A person waiting at a spinner loses trust in the app after a few seconds | e2e `nfr` (time limits) |
| First frame of an app window | `first_frame_ms` = 1500 ms | 133 ms (`window.open` → `VIDEO_CONFIG`) | The window must show the app, not a blank surface | e2e `nfr` |
| First frame of the phone window | `first_frame_phone_ms` = 1500 ms | 136 ms (`window.open` → `VIDEO_CONFIG`) | Mirroring is the app's first screen | e2e `nfr` |
| App list | `app_list_ms` = 1500 ms | 60 ms (`apps.list` → its reply) | The Deck is what a person sees first | e2e `nfr` |
| Small Finder fetch | `fetch_small_ms` = 3000 ms | not measured on the host (the files domain is VM-only; pre-fix it was 20 s) | A Quick Look preview is a person's first hour bug: it took 20 s | e2e `files-domain` (VM) |
| Stale picture | `stale_picture_ms` = 2000 ms | — (safety limit) | A frozen frame shown as live makes a person act on a lie | e2e `mirror` and `nfr` |
| Control contrast | `contrast_min` = 3.0 | — (safety limit) | Bar controls sit over white, black and busy video | K2 `BarContrastTests` |
| Smallest supported screen | `layout_min_screen` = [1280, 800] | — (safety limit) | Every control must be reachable on the smallest Mac screen we support | K2 `SettingsLayoutTests`, `LayoutTests`; e2e `nfr` |
| Settings design height | `settings_design_height_pt` = 560 pt | 560 | What the 1280×800 layout was designed around | K2 `SettingsLayoutTests` |
| Request/reply return | `hanging_reply_ms` = 100 ms | — (safety limit) | A terminal reply ends a request; a peer that keeps the socket open must not add the 20 s receive timeout | K2 `HangingPeerTests` |
| Icon source size | `icon_min_source_scale` = 1.0 | — (safety limit) | An icon is never upscaled from a smaller source | K2 `IconReferenceTests` |
| Icon reference tolerance | `icon_mean_tolerance` = 3.0 | — (safety limit) | Renderer output must match the committed references within a few 8-bit levels | K2 `IconReferenceTests` |

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
  an app window or the phone window, screen off, disconnected/reconnecting),
  bar controls, menu shortcuts, clicks, scrolls and typing send no input
  event (pointer, key, scroll, hover, or a `nav`/`text` action from a
  control). Leaving the mode restores the same controls.
- **Honest settings.** A control whose capability the build or the phone does
  not have is disabled and says why. An error only suggests a restart when a
  restart would change the state.
- **No stale picture.** When frames stop without a state change, the window
  says so within `stale_picture_ms` instead of presenting the old frame as
  live.
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
