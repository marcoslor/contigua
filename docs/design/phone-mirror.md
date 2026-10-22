# Phone Mirror = mirror of the phone's own screen

The Phone Mirror (`window.open` with `mode: phone`) shows display 0 1:1: home
screen, apps, notification shade, lock screen, whatever the panel shows.

## How the shell process mirrors display 0

`DisplayManager.createVirtualDisplay(name, w, h, displayIdToMirror, surface)`:
a hidden static method (Android 14+) that creates a virtual display whose
content is display 0's layer stack, scaled to fit w×h. The caller needs
`CAPTURE_VIDEO_OUTPUT`, which the shell UID (Shizuku) holds.

Why this and not `SurfaceControl.createDisplay` + `setDisplayProjection`
(the older open-source mirroring path):
- `SurfaceControl.createDisplay` is gone or blocked for non-system callers on
  recent releases; the DisplayManager call is the supported replacement and is
  what current open-source mirroring tools try first on API 34+.
- It goes through DisplayManagerService, so OEM builds (One UI 8 / Android 16)
  keep their normal secure-layer and power handling; we add no flags.
- Verified on the API 36 emulator (home, apps, shade, rotation, input).

## Rules

- Nothing is launched and no VD flags are set: the mirror is passive. A phone
  stream on its own never enters the power keep-alive (`activeDisplayIds` skips
  display 0, input doesn't poke, and a mirrored frame is not a reason to light
  the panel). The panel is woken only by an explicit `phone.wake` (window open,
  Wake Screen); it is never unlocked: a locked phone shows its lock screen.
  While the Phone Mirror is open and unpaused the panel is also never powered off
  behind the mirror (`PanelStrategy.PANEL_ALONE`): the mirror shows what the
  panel shows, and an app window sharing the panel's group still renders on the
  group the keep-alive holds awake.
- "Turn Off Phone Screen" (`phone.panel`, off by default) is the one exception,
  and only when the person asks for it: their Phone Mirror's Navigate menu item
  or its bar control holds the panel's power mode off while the mirror keeps
  rendering. The bar shows an `iphone.slash` glyph and a "Phone screen off" pill
  for 2 s; the person's power button on the phone ends it (the Mac unchecks it
  and shows "Phone screen on" for 2 s), and closing the window, disconnecting or
  a crash restores the panel. It is remembered per phone.

  The hold is one state machine on the phone (`PanelHold.kt`: `Off`, `Applying`,
  `Held`, `Suspended`, `Restoring`, with a pure transition and an action list),
  not a set of flags. Every way out of `Applying`/`Held` writes the panel back
  to NORMAL — request on, power press, window close, session end, disconnect,
  crash recovery — so the panel can never be left in power mode OFF once the
  hold has ended. A paused Phone Mirror (covered, minimised) suspends the hold
  instead of ending it: the panel comes back, `state.panel` reads `"on"`, and
  the request is applied again on resume. `state.panel` is derived from the
  machine's state, never from a local guess. The transition reports it first,
  before the panel write and the wake wait; the watchdog's clean stop reaps its
  child on its own thread instead of stalling the session reader. On the 16:44
  log those ran before the report and took 1.1 s, and the Mac's button follows
  the report, so a report sent last is a button 1.1 s late.

  Settings ▸ Devices has a per-phone switch, "Keep the phone screen off until I
  turn it on from the Mac", off by default, sent as `ignorePower` with the
  request. On, a power press lights the screen only until the next keep-alive
  step (2 s) re-applies the panel off, and the hold stands. It changes nothing
  else: every end in the paragraph above still applies, so the phone can never
  stay dark without a Mac holding it, and the phone stays locked either way.

  **The Mac button tells the truth.** Its check and glyph follow `state.panel`
  only. When the phone answers `phone.panel` with `error` (`bad_request`,
  `unavailable`), or `state.panel` has not changed within 2 s of the request,
  the window shows "The phone didn't turn its screen off" for 2 s and leaves
  the button unchecked.
- The stream fits inside the Mac's box at display 0's aspect (`MirrorFit`),
  never above display 0's size. Input maps over display 0's real size.
- Rotation: the stream polls display 0's logical size every 300 ms while open.
  On a change the box turns with the screen and the encoder is rebuilt; a new
  VIDEO_CONFIG goes out and the Mac window turns to match.
- A mirror's projection is fixed at creation, so a size change recreates the
  mirror VD instead of `VirtualDisplay.resize` (which left the picture small).
- Back / Home / Recents = KEYCODE_BACK / HOME / APP_SWITCH on display 0.
- No full screen for the Phone Mirror. A phone mirror across a whole display is
  letterboxed or stretched (the stream keeps the phone's aspect), and the
  person's report is that it looks bad. The window opts out with
  `.fullScreenNone`: no green-button full-screen mode, no Window ▸ Enter Full
  Screen (disabled for it), no ⌃⌘F. The green button zooms to the phone's
  aspect fit inside the screen's visible frame instead. App windows keep full
  screen.
- Failure → `error` `mirror_unavailable` (pre-14 phones).

The old phone mode (a VD running PocketDeck's own launcher activity) was
deleted with its activity: nothing else used it.

## Screen off and wake

A mirror is only useful while the phone's own panel is on. Two things follow:

**The window says when the screen is off.** `state` carries `screen` (`"on"` /
`"off"`, display 0's power state; doze counts as off, so an Always-On Display
does not pass for a live picture). The phone sends it with every `state`, on
change, from a display listener on display 0 (event driven, no polling). A Mac
that gets no `screen` field treats the screen as on: nothing is overlaid.

While `screen` is `"off"` the Phone Mirror blurs the frame it is holding,
dims it, and shows "The phone's screen is off" with a **Wake Screen** button.
The window no longer shows the last frame as if it were live. A click anywhere
on the blurred frame is the Wake Screen button, never a touch: while the
overlay is up the window sends no input at all to the phone. `screen: "on"`
(and the first new frame that follows it) clears the overlay. App windows get
no overlay: virtual displays do not sleep with the panel.

## Secure screens

Android does not let a screen capture read a secure surface: the lock screen's
PIN/password pad, the keyguard bouncer and any app window with `FLAG_SECURE`
come back black. `state` carries `secure` (`true` while display 0 shows such a
surface). The Phone Mirror shows the same blurred, dimmed cover as screen-off,
with "Android doesn't let PocketDeck show this screen." and **no button**: there
is nothing to wake, and a click must never reach the PIN pad. The cover clears
when the phone reports `secure` false again.

A phone that does not report `secure` yet is covered by its frames: half a
second of (near) black frames while the screen is on is treated as a secure
surface, and the first frame with any content takes the cover away again. A
dark app or a dimmed picture is content, never a cover (the pixel test samples
a grid and every sampled pixel has to be black).

**Opening the window wakes the panel.** A new, re-opened or reconnected phone
window sends `phone.wake` with no fields after its `window.open`. The phone
wakes display 0 at shell UID with the display-scoped wake used for virtual
displays (`wakeUpWithDisplayId(0)`) and falls back to
`input keyevent KEYCODE_WAKEUP` when that call is unavailable, then logs
`phone.wake ok`, `phone.wake fallback` or `phone.wake failed`. Waking only:
the keyguard stays up, nothing is unlocked, no lock or screen-timeout setting
is touched, and the panel turns off again on the phone's own screen timeout.
There is no keep-awake for display 0 beyond the platform's normal input
activity.

The Wake Screen button sends the same `phone.wake`; it is there for a person
who does not want to reopen the window.

## Results

Host e2e (`check-e2e.sh mirror`, fakephone with `--rotate-after 6
--screen-off-after 14`): opening the Phone Mirror sends one `phone.wake`; when
the fake panel times out the window reports `screen=off overlay=1` within 2 s
and the last frame is under the blurred cover; the Wake Screen route sends a
second `phone.wake`, the fake comes back on, a new VIDEO_CONFIG follows and the
cover clears (`screen=on overlay=0`). The same run still passes the rotation
and aspect checks. `pair` and `chrome` are unaffected (13/13 and 21/21, the
usual native-full-screen SKIP).

Not verified, and why:
- **Emulator (second boot spent, API 36)**: the rig booted, installed 102,
  paired and stayed locked, but the section never reached its checks: deckctl
  had `wake-test` in its argument parser and no handler in `COMMANDS`, so it
  died with `KeyError: 'wake-test'` before sending `phone.wake`. The device was
  left in Dozing by the `KEYCODE_SLEEP`, which is why `dumpsys power` read
  `mWakefulness=Dozing` and the keyguard mask did not show. deckctl now
  dispatches `wake`/`wake-test`, and preflight asserts that every subcommand has
  a handler (it failed on the old file), so the next boot's section is the first
  real test of `state.screen`, `phone.wake` and the keyguard staying locked. No
  second boot is allowed here.
- The real phone's Always-On Display: Samsung may report display 0 as `doze`
  (or `doze-suspend`) while the AOD clock is lit. `ScreenState.of` maps doze to
  `off`, so the window shows the cover rather than the clock; that mapping is
  the intended reading but has only been unit-tested.
- Samsung's lock screen after a wake: the code only ever calls the display
  wake and never touches the keyguard, but whether One UI re-shows the lock
  screen with its short timeout (or the AOD) right after the wake is a
  device-only observation.
