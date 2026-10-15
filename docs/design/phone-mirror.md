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
  doesn't poke). The panel is never woken, unlocked or turned off: a locked or
  off phone shows the lock screen or black.
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
