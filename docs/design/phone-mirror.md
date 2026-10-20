# Phone window = mirror of the phone's own screen

The phone window (`window.open` with `mode: phone`) shows display 0 1:1: home
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

- Nothing is launched and no VD flags are set: the mirror is passive. Phone
  streams never enter the power keep-alive (`activeDisplayIds` skips them, input
  doesn't poke, and a mirrored frame is not a reason to light the panel). The
  panel is woken only by an explicit `phone.wake` (window open, Wake Screen);
  it is never unlocked or turned off: a locked phone shows its lock screen.
- The stream fits inside the Mac's box at display 0's aspect (`MirrorFit`),
  never above display 0's size. Input maps over display 0's real size.
- Rotation: the stream polls display 0's logical size every 300 ms while open.
  On a change the box turns with the screen and the encoder is rebuilt; a new
  VIDEO_CONFIG goes out and the Mac window turns to match.
- A mirror's projection is fixed at creation, so a size change recreates the
  mirror VD instead of `VirtualDisplay.resize` (which left the picture small).
- Back / Home / Recents = KEYCODE_BACK / HOME / APP_SWITCH on display 0.
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

While `screen` is `"off"` the phone window blurs the frame it is holding,
dims it, and shows "The phone's screen is off" with a **Wake Screen** button.
The window no longer shows the last frame as if it were live. A click anywhere
on the blurred frame is the Wake Screen button, never a touch: while the
overlay is up the window sends no input at all to the phone. `screen: "on"`
(and the first new frame that follows it) clears the overlay. App windows get
no overlay: virtual displays do not sleep with the panel.

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
--screen-off-after 14`): opening the phone window sends one `phone.wake`; when
the fake panel times out the window reports `screen=off overlay=1` within 2 s
and the last frame is under the blurred cover; the Wake Screen route sends a
second `phone.wake`, the fake comes back on, a new VIDEO_CONFIG follows and the
cover clears (`screen=on overlay=0`). The same run still passes the rotation
and aspect checks. `pair` and `chrome` are unaffected (13/13 and 21/21, the
usual native-full-screen SKIP).

Not verified, and why:
- The emulator run never reached its checks: one boot was spent and the rig's
  Shizuku shell service did not bind its port after the app launch (`start.sh`
  failed at the listening-socket step). The boot budget allows no second boot,
  so `state.screen` on a real device, `phone.wake ok` and the keyguard staying
  locked are unverified here. `tools/emulator/phone-screen.sh --check` passes,
  and the script now retries that known first-launch flake through the rig's
  `restart_server`; the reviewer's boot is the first real test.
- The real phone's Always-On Display: Samsung may report display 0 as `doze`
  (or `doze-suspend`) while the AOD clock is lit. `ScreenState.of` maps doze to
  `off`, so the window shows the cover rather than the clock; that mapping is
  the intended reading but has only been unit-tested.
- Samsung's lock screen after a wake: the code only ever calls the display
  wake and never touches the keyguard, but whether One UI re-shows the lock
  screen with its short timeout (or the AOD) right after the wake is a
  device-only observation.
