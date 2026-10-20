# nfr-checks: product questions (no product changes made)

The `nfr` check is written to fail on these; the evidence below is from the
host runs (`/tmp/nfr-run2.log`, `/tmp/nfr-run3.log`) and the new counters in
`tools/fakephone/fakephone.py`.

## 1. A stalled picture has no state (step 3.3, expected)

**What the check does.** `fakephone --stall-after 3` sends frames and then
stops, keeping the session and its socket up (a hung phone, not a disconnect).
The app window and the phone window must stop presenting the last frame as
live within `stale_picture_ms` (2000 ms, docs/NFR.md).

**Evidence.** After `{"ev":"stall"}` the chrome state stays
`pill=hidden ... screen=on overlay=0` for the whole window; there is no
staleness timer anywhere in `StreamWindow`/`WindowManager` (the only state is
the link-down "Reconnecting…" pill). Check output:
`FAIL NFR no stale picture: the window kept the last frame as live for 2000 ms`.
This is the one FAIL step 3.3 allows: no such state exists today.

**Options.**
1. Per-window frame watchdog: remember the last frame's time; when the
   session is ready and no frame arrived for `stale_picture_ms`/2, show the
   existing "Reconnecting…"-style pill with "Not responding" and report
   `stall=1` in the chrome state file; clear it on the next frame.
   Smallest: a timer in `StreamWindow` next to the Live Text pause path, no
   protocol change.
2. Only log a line (os_log) and keep the frame — does not meet the product
   promise ("the window says so").
3. Make fakephone send a `state` describing the stall — a protocol change on
   the phone side, which this task may not make.

**Recommendation:** option 1, in a separate product task; the check already
pins the behaviour (`stall=1` in the chrome state and a visible non-live
pill). I did not build it: this task is checks, tools and docs only.

## 2. Screen off freezes the pointer but not the navigation shortcuts

**What the check does.** With the phone's panel off (the cover up), it sends
scroll, typing and the phone navigation shortcuts (⇧⌘H, ⌘[) and reads the
fake phone's `input` counter.

**Evidence.** `FAIL NFR frozen screen off: input 0 -> 1 (last nav)`. The cover
(`PhoneScreenOverlayView`) swallows clicks because it is a view over the
video, but the shortcuts are gated only by Live Text
(`HeaderActionPolicy.allowsPhoneShortcut(liveTextActive:)` and
`StreamWindow.mapper.inputSuspended` both consult `liveText.isActive` only),
so ⇧⌘H reached the phone behind the frozen picture. Live Text in both window
kinds passed (`input stayed 0`), and the same Back after the wake reached the
phone (`input +1`), so the counter path is sound.

**Options.**
1. Treat the cover as a frozen mode: the shortcut gate and
   `mapper.inputSuspended` also return true while
   `phoneOverlay.isShowing` (one extra clause in two places, no protocol
   change); the cover's own Wake Screen click stays the one allowed action.
2. Disable the bar buttons' actions as well (the overlay already covers the
   bar area? it covers the video only), same policy helper.
3. Leave it: a person cannot click the phone behind the cover, but the
   shortcut does act on it — contradicts AGENTS.md "modes block what they
   freeze".

**Recommendation:** option 1 (and the same clause for the bar buttons, which
share the policy). A separate product task; the check stays red until then.

## 3. Not a question: the files read-only phase

The bridge driver's `online` phase includes a denied `create` (a write
attempt) and a read cancel. The read-only check now uses a new `read` phase
(hello, root listing, paging, stat, read) so the file-flow assertion measures
only what a Finder browse and Quick Look send. `online` is unchanged.

## 4. Bar buttons are dead on main (the v103 bug); hotfix-mac already fixes it

**Evidence.** `ControlsRealPathTests.testEveryPhoneBarButtonHitsItselfAndFiresOnce`
is the only red K2 test (12 assertions): `HeaderActionButton.hitTest` compares
a superview-space point with the button's own bounds, so only the first capsule
slot can hit and the wrong button receives the click. The same test passes
against hotfix-mac's `bfffd46` (same hit test, plus `button(for:)` for the e2e
click). I did not copy that fix here: it is another agent's commit and the
reviewer merges it; this branch carries the failing check as its repro.
