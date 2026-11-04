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

## Sweeping test registrations

A test copy registered with LaunchServices can claim `pocketdeck://`, and a
test build's Share extension can appear in the person's Share menu. A killed
run never reaches a clean-exit unregister, so the sweep runs at both ends:

- `sweep_test_registrations` lives in
  `macos/scripts/sweep-test-registrations.sh`. `check-e2e.sh` calls it after
  taking the run's lock, before the build, and again from its exit path
  (`finish`) while it still holds the lock. Any other runner calls the same
  script at its start and in its trap; the prototype shooter
  (`macos/scripts/proto-shoot.sh`, on the prototype branch today) does so when
  it lands on `main`.
- It reads `lsregister -dump` `path:` lines and `pluginkit -m -A -v` paths,
  keeps only paths under an allow-list, and never uses a deny-list:
  `~/dev/pd-wt/`, `~/dev/pocketdeck/`, `/private/tmp/`, `/tmp/`, `~/.t3/`, and
  `~/Library/Application Support/PocketDeck-<profile>/` for a non-empty
  profile suffix (the Dock shims of test profiles).
- An app's PlugIns' appexes are removed with `pluginkit -r` first, then the
  app with `lsregister -u`; an `.appex` found on its own is removed with
  `pluginkit -r`. It then runs `lsregister -gc`.
- It prints one line, `sweep: lsregister N, pluginkit M`, with counts only:
  never a path of the person's.
- The share check still runs `pluginkit -a`/`-e use` because that run needs the
  extension; the exit sweep and the next run's start sweep remove it. The
  check's own `unregister_share` stays as the fast path for a clean exit.

The person's `/Applications/PocketDeck.app`, its two extensions, the default
profile folder `~/Library/Application Support/PocketDeck/` and every display
that is not the rig's are outside the allow-list and are never touched.
