# Focus sync (ROADMAP v0.2 #5)

A Mac Focus turns the phone's Do Not Disturb on and off again, the menu bar can
toggle phone DND by hand, and a Shortcut can set it. The phone's zen mode is the
only phone setting this touches.

## The wire

Mac → phone:

```
{"t":"phone.dnd","mode":"priority"|"alarms"|"none"|"off"}
```

Phone → Mac (inside the existing `state`):

```
{"t":"state","locked":false,"battery":74,"charging":false,"dnd":"priority"}
```

`dnd` is `"off"`, `"priority"`, `"alarms"` or `"none"`. The phone sends `state`
on change as before, so a mode the person changes on the phone reaches the Mac
through the same stream. An old Mac ignores the new field; an old phone ignores
`phone.dnd` (it logs the unknown message once) and sends no `dnd`, which the new
Mac reads as "this phone cannot do it".

Mapping to Android's `Settings.Global.zen_mode`:

| dnd | zen_mode |
|---|---|
| `off` | 0 |
| `priority` | 1 |
| `none` | 2 |
| `alarms` | 3 |

Any other mode answers `error` `bad_request`; nothing is changed.

## Phone side

`ZenControl` owns the setting and the memory:

- **Set** with `cmd notification set_dnd <priority|alarms|none|off>` at shell UID,
  run as an argv array (no shell). Nothing else is touched: no ringer mode, no
  lock settings.
- **Read** `Settings.Global.zen_mode` every time a `state` is built, and through
  a `ContentObserver` on the same setting. Where a shell-UID observer is not
  reachable, it polls at most every 5 s while a session is up. Lock and battery
  events keep their existing sources.
- **Remember what PocketDeck did.** `setByMac` holds the mode PocketDeck last
  turned on. The memory belongs to the shell service, not the session: a Mac
  that disconnects and reconnects does not forget it. It is cleared on reboot,
  which is fine.

The restore rule, in both directions:

1. **Turn on** (`priority`, `alarms`, `none`):
   - phone DND off → set that mode, remember it as `setByMac`;
   - phone already in that mode with `setByMac` equal to it → nothing (a
     reconnect must not re-apply it);
   - phone DND already on in any other mode → leave it alone and forget
     `setByMac`: it is the person's own DND.
2. **Turn off** (`off`, or the Focus ended):
   - `setByMac` is set and the phone is still in that mode → set `off`, clear
     `setByMac`;
   - `setByMac` is set but the phone is now in another mode → the person
     changed it; clear `setByMac` and leave the phone alone;
   - `setByMac` is not set → leave the phone alone. A person's own DND is never
     turned off by PocketDeck.

An observed mode that differs from `setByMac` clears `setByMac` as soon as it
is seen, so a person's change between two Mac commands is not mistaken for
PocketDeck's DND. Logs carry mode names only.

## Mac side

### Focus filter

`PocketDeckFocusFilter` is a `SetFocusFilterIntent` (macOS 13+) with two
parameters:

- **Silence my phone** — Bool, default on. Off means "not wanted".
- **Allow** — priority (default), alarms only, or nothing. It maps to
  `phone.dnd` `priority`, `alarms` and `none`.

`perform()` stores the wanted state in the profile's defaults and, when the app
is running, asks the controller to reconcile now. A phone that connects later
is reconciled once, when its first `state` arrives; repeated `state` messages
do not send again, so a reconnect can only apply it once. "Not wanted" is sent
as `phone.dnd off`, which the phone's restore rule turns into a no-op when the
DND is not PocketDeck's.

The system only calls `perform()` for a Focus that has the filter; the app also
refreshes `SetFocusFilterIntent.current` when it starts and before reconciling a
connection, so a Focus that ended while PocketDeck was not running is read as
"not wanted". No Focus = not wanted.

### Manual control

- Menu bar extra: **Phone Do Not Disturb**, checkmark from `state.dnd`. It is
  disabled when no phone is connected or when the phone sends no `dnd` (an old
  phone). Clicking it sends `priority` when off and `off` when on.
- `SetPhoneDNDIntent` (Shortcuts, Siri): on/off plus a mode, default priority.

Both go through the same controller methods as the Focus filter and the
`--debug-focus` / `--debug-dnd` hooks; on the phone, anything the Mac turns on
counts for `setByMac`, so the restore rule also covers manual sets.

### Metadata

The bundle's `Metadata.appintents` must list the filter and the manual intent
next to the six existing actions. `bundle.sh` builds it exactly as before
(docs/design/intents.md); the e2e `focus` check reads the built bundle and the
`intents` check's metadata assertion includes both.

## Compatibility

- Old Mac, new phone: the new field is ignored; no behaviour change.
- New Mac, old phone: no `dnd` in `state`; the menu item is disabled, the
  filter/manual actions send nothing, and the phone logs the unknown message
  once at most.
- The phone's DND mode is the only phone setting involved. Ringer mode, lock
  screen settings and other apps are never touched.
