# The e2e rig on the host Mac

`macos/scripts/check-e2e.sh` runs a test copy of the app quietly on the person's
own Mac. Two things it touches outlive a run unless the rig removes them:
display identities (macOS keeps a colour profile and a saved arrangement for
every display it has ever seen) and app registrations (LaunchServices and
PlugInKit remember every copy of the app, including its extensions). This page
records the rules that keep both bounded (ISS-28).

## One display identity for every test run

A virtual display's identity is its vendor, product and serial numbers. The
test display is vendor `0x5044`, product `0xE2E0`, named `PocketDeck e2e`.

- `macos/scripts/pd-vdisplay.swift` (the helper the run holds for its whole
  life) always uses serial `FNV-1a("e2e")`.
- The app uses `VirtualDisplay.displaySerialNumber(for:)`. The deciding
  option is `--background`, the quiet e2e flag parsed in `LaunchOptions`
  (`App.swift`) and acted on by `BackgroundMode.start()`: with it the display
  uses the same `e2e` identity whatever `--profile` says. Without it — a
  person-facing launch — the display keeps the serial of the launch's own
  profile, `FNV-1a(profile)`.
- `VirtualDisplay.testIdentityProfile` is the single source of that name in
  Swift; `VirtualDisplaySerialTests` pins that two test profiles get the same
  serial and that a launch without the flag keeps its profile's serial.
  `pd-vdisplay.swift` is compiled on its own and repeats the literal, with a
  comment naming the constant.

Before this, the serial was the profile's hash for every launch, so each
worker profile and probe added a display identity. By 2026-11-04 the host had
210 colour profiles in `/Library/ColorSync/Profiles/Displays`, 80 of
WindowServer's 100 saved arrangements, and 121 entries in a display utility.
`macos/scripts/clean-ghost-displays.sh` lists and (with `--apply`, as an
administrator) deletes only the profiles named after the rig's displays whose
display is not online now.
