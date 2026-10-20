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

## The perform route (spike 0a)

**Assumption, not yet verified.** The extension's intents are hosted by the
widget extension and talk to the app over the App Group socket above. The
alternatives, in the order the spike tries them, are:

1. the intent type compiled into both the app and the extension, so the system
   runs `perform()` in the app process (logged pid/bundle proves it);
2. the extension runs `perform()` and talks to the app over the group socket
   (the design above);
3. the intent opens the app (`openAppWhenRun`; last resort, it steals focus).

The spike logs the pid and executable in `perform()`. Until it has run, only
option 2's code exists. If the log shows option 1, the extension keeps the
snapshot but the intents move into the app's module; if it shows option 3, the
DND and Ring controls become app-opening buttons.

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
