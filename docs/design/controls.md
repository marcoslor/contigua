# Control Center controls (ROADMAP v0.2 #4)

macOS 26 Control Center and the menu bar can carry four PocketDeck controls:
**Phone Do Not Disturb** (toggle), **Ring Phone**, **Phone Ringer**
(normal / vibrate / silent), and **Open PocketDeck**. A hotspot control is
research only (below) because the shell UID cannot toggle it without replacing
the person's hotspot configuration.

## Shape

```
app (owns the session)
  ├─ controls.json      snapshot, atomic write, 0600
  ├─ controls.sock      UNIX socket, peer uid checked (MCPSocketServer)
  └─ ControlCenter.shared.reloadControls(ofKind:)
Controls.appex (widget extension, sandboxed, App Group group.dev.pocketdeck.mac.controls)
  ├─ ControlValueProvider reads controls.json
  └─ AppIntent.perform() sends one JSON line to controls.sock
```

The extension never owns a session and never dials the phone. It is opt-in in
`bundle.sh` (`--with-controls`), exactly like the File Provider experiment:
host e2e bundles carry no extension, and no bundle that carries one is launched,
opened, registered or copied on this Mac. It is verified only in the `pd-e2e` VM.

### Snapshot (`controls.json`)

```json
{"version":1,"connected":true,"phone":"Pixel","dnd":"priority",
 "ringer":"normal","ringing":false,"updated":1760000000}
```

- `dnd`: the `state.dnd` wire name, absent when the phone does not report it.
- `ringer`: the `state.ringer` wire name, absent when the phone cannot set it.
- Written when a value changes (a one-second comparison in the app), by atomic
  rename over the old file, in a 0700 folder, file 0600.
- `ControlCenter.shared.reloadControls(ofKind:)` is called after a change, off
  the main actor: the XPC round trip can block for seconds and must not delay a
  control's reply.

The DND toggle is off and labelled "No phone" when the snapshot says
disconnected or has no `dnd`; the Ringer control is labelled unavailable when
there is no `ringer`.

### Requests (`controls.sock`, newline-delimited JSON)

| request | meaning |
|---|---|
| `{"t":"dnd","on":true\|false}` | the toggle; on sends `priority`, off sends `off` |
| `{"t":"ring"}` | `phone.ring`, 30 s |
| `{"t":"ring.stop"}` | `phone.ring.stop` |
| `{"t":"ringer","mode":"normal"\|"vibrate"\|"silent"}` | `phone.ringer` |
| `{"t":"open"}` | bring PocketDeck forward |

Answer: `{"ok":true}` or `{"ok":false,"error":"<code>","message":"<sentence>"}`.
Stable codes: `not_connected`, `no_dnd`, `no_ringer`, `dnd_on`, `bad_request`.
Malformed lines, unknown kinds, wrong types and lines over 4 KiB are
`bad_request`; nothing is sent to the phone.

Every request runs the same `IntentsBridge` / controller code as the menu bar,
the App Intents and the debug hooks. A DND a control turns on therefore counts
as set by the Mac for the phone's restore rule (docs/design/focus.md), and a
control's `off` never turns off a DND the person set.

## The perform route (not proven)

**Unverified.** The extension's intents are hosted by the widget extension and
talk to the app over the App Group socket above. The spike never got a control
into the gallery, so which process runs `perform()` is unknown. The alternatives
the design allows, in order:

1. the intent type compiled into both the app and the extension, so the system
   runs `perform()` in the app process;
2. the extension runs `perform()` and talks to the app over the group socket
   (what this implementation assumes);
3. the intent opens the app (`openAppWhenRun`; last resort, it steals focus).

The extension logs the pid and executable in `perform()` (`controls-ext.log` in
the group container) and sends every action over the socket. A run that proves
the route decides whether this stays; if the system never runs extension-hosted
actions, the intents move into the app (`openAppWhenRun` is already set on Open
PocketDeck) and the other three controls fall back to opening the app.

## Phone side: ringer (spike 0b)

Findings from the Android 16 / API 36 emulator at shell UID:

- **Write:** `cmd audio set-ringer-mode NORMAL|VIBRATE|SILENT` works and changes
  the AudioService mode; a bad value exits non-zero with
  `Error: invalid value of ringerMode`.
- **Read:** `Settings.Global.mode_ringer` tracks the write exactly
  (`silent` 0, `vibrate` 1, `normal` 2). `cmd audio get-ringer-mode` exists
  (`exit 0`) but prints nothing on this build, so it is not the read path.
  `settings put global mode_ringer` changes the setting but not the
  AudioService mode, so it is not the write path either.
- **DND interaction:** with `zen_mode` `priority`, a ringer write left DND on
  (the effective ringer stayed `SILENT`); with `alarms`, a ringer write ended
  that DND (`zen_mode` 3 → 0). Because a ringer change can therefore clear a
  DND, `phone.ringer` is refused while the phone's DND is on: the Mac answers
  `dnd_on` before sending, and the phone's `RingerControl` refuses the write as
  a second gate. This keeps the "only the ringer changes" rule true.
- Nothing else is touched: no stream volume, no lock setting, no other setting.

`state.ringer` rides the existing tracker (sent on change, like `dnd`). An old
phone sends no `ringer`, and `phone.ringer` is an unknown message to it.

## Hotspot (research only)

On the API 36 emulator at shell UID 2000:

- `cmd wifi start-softap` → `SecurityException: Uid 2000 does not have access to
  start-softap wifi command`.
- `cmd tethering` → `No shell command implementation`.
- `cmd connectivity` only has `airplane-mode`, network preference and similar;
  no tethering toggle.
- `cmd wifi help` lists `get-softap-supported-features` (read-only) and the
  normal scan/connect commands; there is no start/stop of the person's existing
  hotspot without an SSID/passphrase, which would replace its configuration.

No hotspot control is implemented.

## Experiment results (2026-10-20)

Five VM sessions were used for spike 0a (the brief allowed one; the overrun is
recorded here rather than hidden). The bundle was the `e2e` variant built with
`--with-controls`, ad-hoc signed, sandboxed extension with the App Group.

**What worked.**

- The App Group container exists and the app writes `controls.json` into it:
  `{"connected":true,"phone":"FakePhone","dnd":"off","ringer":"normal",…}` while
  fakephone was connected.
- The appex registers. `pluginkit -m -i dev.pocketdeck.mac.controls-e2e` lists it
  after `lsregister -f PocketDeck.app` and
  `pluginkit -a …/Contents/PlugIns/Controls.appex`, both from `~/pd-e2e` and from
  `/Applications`. In the `pluginkit -m -p com.apple.widgetkit-extension` list it
  appeared only after the app was copied to `/Applications` and opened once.
- System Settings › Control Center › Menu Bar has an **Add Controls…** button
  that opens the control gallery (`gallery.png` in
  `macos/build/vm-e2e/controls-spike5/work/`). The gallery lists system
  categories (Clock, Connectivity, Focus, …) and the app's own menu bar item is
  listed separately on the Menu Bar pane.

**What did not work.**

- PocketDeck had no category or item in the gallery, and ControlCenter never
  launched `Controls.appex` (only the system control extensions were running).
  No `controls-ext.log` appeared, so no `perform()` ran and the route is
  unproven.
- No per-app enable switch was seen in the gallery. Whether Login Items &
  Extensions › Extensions has a Widgets/Controls row (the File Provider
  experiment needed a switch there) was **not checked**: the session budget ran
  out first.
- The gallery run used an extension **without** App Intents metadata. After the
  spike, `bundle.sh --with-controls` was changed to run
  `appintentsmetadataprocessor` for the extension too; the built bundle now has
  `Controls.appex/Contents/Resources/Metadata.appintents` listing the four
  actions. The gallery was not re-checked with it.

**Step 5 session (the last one allowed).** With the metadata-bearing extension
in `/Applications`, the app opened through LaunchServices, `pluginkit -p
com.apple.widgetkit-extension` listing the appex, `pluginkit -e use`, and both
ControlCenter and pkd restarted:

- The gallery's search for "Pocket" is empty, and Control Center shows none of
  the four controls.
- System Settings › General › Login Items & Extensions › **Extensions** lists
  only Books; there is no PocketDeck row at all, so there is no switch to turn
  on (not even the app's Share extension appears for this e2e copy).
- No `controls-ext.log` was created; the extension was never launched.

**Consequence.** The extension and the socket route stay **unverified in the
VM**, and the control catalogue does not accept this ad-hoc, e2e-variant
extension in the guest. What is left for a person to check on a machine where
the app is installed normally: build with `--with-controls`, open Control
Center › Edit Controls; if PocketDeck is absent there and in Login Items &
Extensions, the remaining cause is the extension's signing/registration (ad-hoc
signing is enough for the File Provider extension, but not proven for a
ControlCenter control).

## Checks

- Unit: `macos` `ControlsCoreTests` (snapshot round trip, 0600 atomic write,
  request validation, reply codes, ringer cycle) and Android
  `RingerControlTest` / `RingerSessionTest` (wire modes, DND refusal, old phone).
- e2e host `controls` (`macos/scripts/check-e2e.sh controls`, no extension):
  a Python driver stands in for the extension, reads the snapshot and sends
  requests over `--controls-dir`'s socket. Covers DND on/off, Ring, Ringer, the
  restore rule, an old phone and the phone going away.
- VM: a `--with-controls` bundle plus fakephone; registration, the control
  gallery, adding and pressing the controls, and the toggle's state.
