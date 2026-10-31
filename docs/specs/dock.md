# Dock and application shortcuts

Prefix: `DOCK`. Owner docs: docs/design/dock.md, docs/UX.md §Deck (the tile's menu), docs/specs/settings.md (the per-phone page). Last reviewed: 2026-10-30, against build 0.1.0.

## Purpose

A phone app can have its own Mac app identity: a small shim bundle with the app's real icon and an "App (Phone)" name, in `~/Applications/PocketDeck Apps` (`~/Applications/PocketDeck Apps` is where Launchpad and Spotlight look, and other launchers scan it too) or the profile's Application Support folder for a test profile. The same bundle is the Dock and ⌘-Tab identity of an open app window (DOCK-10/11), a shortcut the person adds for one app (DOCK-4), and a shortcut the phone's Save all switch adds for every app (DOCK-5). One bundle kind, one icon renderer, four reasons it exists (DOCK-2).

## User stories

| ID | Priority | Story |
|---|---|---|
| DOCK-S1 | P1 | As a person with a paired phone, I want the phone's apps to appear in Launchpad, Spotlight and other launchers as real apps, named for their phone, so that I can launch them like any Mac app. |
| DOCK-S2 | P1 | As a person, I want to add or remove one app's shortcut, so that only the apps I choose live in my Applications folder. |
| DOCK-S3 | P2 | As a person with many apps, I want one switch that saves all of a phone's apps as shortcuts, so that I do not add them one by one. |
| DOCK-S4 | P1 | As a person, I want to see which of these reasons a shortcut exists for, so that turning one switch off never deletes a shortcut I asked for another way. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| DOCK-1 | WHEN a shortcut is built THE Mac SHALL write a shim bundle `<name>/Contents/{Info.plist,MacOS/PocketDeckShim,Resources/AppIcon.icns}` with bundle id `dev.pocketdeck.dock.[<profile>.]<deviceId>.<pkg>`, name "App (Phone)", the app's 1024 px icon and the host's path, ad-hoc sign it and register it with LaunchServices; a test profile SHALL use its own folder, never `~/Applications`. | e2e `dock` (bundle name, id, icon, signature, registration); K2 `DockAppsTests.testNameAndFileName`, `testBundleIdDropsUnsafeCharacters`, `testInfoPlistKeys`, `testTestProfilesNeverUseApplicationsFolder` |
| DOCK-2 | THE shim SHALL record why it exists as an origin set — `dock` (Add to Dock), `manual` (Add to Applications), `all` (Save all), `window` (an open window's automatic identity) — and SHALL exist while the set is non-empty; removing one origin SHALL remove only that origin, and a bundle written before the set existed SHALL load with `dock` when its old marker was pinned (or missing) and `window` when it was unpinned. | K2 `DockAppsTests.testEveryOriginTransition`, `testOriginSetRoundTripsAndKeepsItsOrder`, `testLegacyShimsMigratePinnedToDockAndUnpinnedToWindow`; e2e `shortcuts` `[DOCK-2]` |
| DOCK-3 | WHEN the person chooses Add to Dock THE Mac SHALL add `dock`, build the bundle and launch it, whatever the Show-phone-apps setting; WHEN the person chooses Remove from Dock App THE Mac SHALL remove only `dock` and SHALL keep a shim another origin holds, stopping a running shim that does not stand for a window. | e2e `dock` (Add to Dock, Remove), `shortcuts` `[DOCK-3]`; K2 `DockAppsTests.testEveryOriginTransition` |
| DOCK-4 | THE Deck tile's menu SHALL offer Add to Applications (adds `manual`) and, when the shim carries `manual`, Remove from Applications (removes only `manual`) next to Add to Dock/Remove from Dock App; an app Save all already covers SHALL still offer Add to Applications, which keeps it after Save all is turned off; the item SHALL be disabled with a reason when no phone is connected. | e2e `shortcuts` `[DOCK-4]` (the debug control route creates and removes the bundle in the run's folder; the Dock origin is unaffected); K2 `DockAppsTests.testEveryOriginTransition` |
| DOCK-5 | THE phone's page SHALL offer "Save all apps as shortcuts", per phone, off by default and stored per phone id; WHEN it is turned on THE Mac SHALL add `all` to every app of that phone; WHEN it is turned off THE Mac SHALL remove `all` from every shim of that phone, rewriting the ones another origin keeps and removing the rest. | K2 `DockAppsTests.testSaveAllPlanIsOnEveryAppOffOnlyAll`, `testSaveAllAddsAllOnARefreshAndRemovesOnlyAll`, `testSaveAllSettingIsPerPhoneAndOffByDefault`; e2e `settings` (the switch), `shortcuts` `[DOCK-5]` (40 shims on, two kept off) |
| DOCK-6 | WHILE Save all builds many shims THE Mac SHALL request the Dock's 1296 px icon for at most four apps at a time, build each bundle off the main thread when its icon answers (or the phone reports none), and SHALL NOT wait for the window to open. | K2 `DockAppsTests.testSaveAllPlanIsOnEveryAppOffOnlyAll` (one step per app); e2e `shortcuts` `[DOCK-6]` (40 `.icns` present while the Deck still answers); review of `dockIconOutstanding`'s limit of four and DockApps' serial build queue |
| DOCK-7 | WHEN an app list arrives THE Mac SHALL reconcile that phone's shims: an app no longer installed SHALL lose `all` and `manual` and keep a shim only while `dock` or `window` holds it; a new app SHALL gain `all` when Save all is on; a renamed app or phone SHALL rebuild its shims; a shim standing for an open window SHALL NOT be removed or rebuilt before its window is gone. | K2 `DockAppsTests.testUninstalledAppsAreRemovedRenamedOnesRebuilt`, `testAnUninstalledAppKeepsOnlyTheDockAndWindowReasons`; e2e `shortcuts` `[DOCK-7]`, `nickname` |
| DOCK-8 | WHEN the person forgets a phone THE Mac SHALL remove every shim of that phone, whatever its origins, and leave another phone's shims untouched. | K2 `DockAppsTests.testForgetRemovesOnlyThatPhonesShims`; e2e `settings` `[SET-DEV-07]`, `shortcuts` `[DOCK-8]` |
| DOCK-9 | WHILE an app has a shim THE Mac SHALL NOT also index it as a CoreSpotlight item: the item SHALL be removed when the shim appears, and the phone's list SHALL be indexed again when the shim goes away. | K2 `SpotlightTests.testAShimmedAppIsNotIndexedTwice`; e2e `shortcuts` `[DOCK-9]` (the index's own count drops by the shimmed apps) |
| DOCK-10 | WHEN a shim is launched, clicked or activated THE shim SHALL post `dev.pocketdeck.dock.open` with its token, and the host SHALL open or raise the one window for that app; when two windows of one app are open the identity SHALL follow the one that is left. | e2e `dock` (open raises one window, `[WIN-2]`); review of `DockApps.openRequested`/`Shim` |
| DOCK-11 | WHEN the app list arrives and "Show phone apps in the Dock" is on THE Mac SHALL create or launch the open app window's identity (adding `window`), waiting for the app's real icon rather than showing a blank tile; turning the setting off SHALL stop the running identities that only a window keeps, leaving their windows and bundles. | K2 `DockAppsTests.testAMissingShimWaitsForTheIcon`, `testAnExistingIdleShimRelaunchesWhenItsIconIsRight`; e2e `dock` (the automatic identity, the setting's off state) |
| DOCK-12 | WHILE a phone is offline its shims SHALL stay in place; launching one SHALL connect to that phone first and open the app when it is ready. | review of `DockApps.openRequested` + `ConnectionController.openFromDock`; e2e `dock` (a shim launch before the session is ready) |
| DOCK-13 | THE shim's icon SHALL be one 1024 px render from the Dock's 1296 px size class (the phone's adaptive layers, or its 864 px flat), written as an `.icns` with every standard size, and a bundle with an older renderer's icon SHALL be rebuilt. | K2 `DockAppsTests.testIcnsHasEveryStandardSizeFromOne1024Render`, `testAFlatOnlyShimsIconComesFromTheRenderer`; e2e `dock` (the icon's pixels, PDIconVersion) |
| DOCK-14 | A shortcut SHALL launch nothing when it is created (Add to Applications and Save all are shortcuts, not windows); only Add to Dock and an open window's automatic identity SHALL launch their shim. | review of `ConnectionController.addToApplications`/`setSaveAllShortcuts`; e2e `shortcuts` `[DOCK-14]` (no `window.open` from Save all) |
| DOCK-15 | THE shim's name and file name SHALL be "App (Phone)" with `/` and `:` dropped and a leading `.` removed, bounded to 200 characters, and SHALL follow a phone rename or an app relabel. | K2 `DockAppsTests.testNameAndFileName`, `PhoneNicknamesTests`; e2e `nickname` |
| DOCK-16 | Test profiles SHALL write only their own folder or `--dock-dir DIR`; no run SHALL create, change or delete anything in `~/Applications` or `/Applications`. | K2 `DockAppsTests.testTestProfilesNeverUseApplicationsFolder`; e2e `dock` and `shortcuts` run against `--dock-dir` |

## States and events

One app's shim, and the origin set it carries. Every event is accepted in every state; `write` means build or rewrite the bundle, `remove` means delete it.

| From (origins) | `add(o)` | `remove(o)` | `reconcile` (installed, Save all on) | `reconcile` (installed, Save all off) | `reconcile` (gone) | `forget` |
|---|---|---|---|---|---|---|
| `{}` | `{o}`, write | `{}`, ignored | `{all}`, write | `{}`, ignored | `{}`, ignored | `{}`, ignored |
| `S` with `o` | `S`, ignored | `S − {o}`; empty → remove, else write | `S ∪ {all}`, write when it changed | `S − {all}`; empty → remove, else write when it changed | `S − {all, manual}`; empty → remove, else write when it changed | `{}`, remove |
| `S` without `o` | `S ∪ {o}`, write | `S`, ignored | `S ∪ {all}`, write when it changed | `S − {all}`; empty → remove, else write when it changed | `S − {all, manual}`; empty → remove, else write when it changed | `{}`, remove |

The full 26-transition table is `DockAppsTests.testEveryOriginTransition`; the reconcile and Save all plans are `DockCleanup.plan` and `DockSaveAll.plan`, both built from the same `DockOrigins.applying`.

## Phone count and connection

0 phones: no shortcut exists and the Deck's menu items are disabled. 1 phone: its shims carry its device id and name. 2+ phones: every bundle id and name includes the phone, and an app list reconciles only that phone's shims. Connecting and reconnecting: the app list rebuilds what changed. Offline: the shims stay and launch (connecting first); the phone page's Save all switch stays editable and its stored value applies at the next app list. A phone that cannot make shims (no shim binary in the build) has the menu items and switch disabled with a reason.

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: the Deck's own search keeps ⌘F; this surface adds no field. |
| CONV-MAC-02 | applies: the menu items are plain buttons; Esc closes an open Deck menu (DOCK-3/4). |
| CONV-MAC-03 | applies: Esc closes the tile's menu without acting. |
| CONV-MAC-04 | n/a: no text field. |
| CONV-MAC-05 | n/a: no zoomable content. |
| CONV-MAC-06 | n/a: these menu items carry no shortcut. |
| CONV-MAC-07 | n/a: reuses no shortcut. |
| CONV-MAC-10 | n/a: no menu-bar interaction. |
| CONV-MAC-11 | applies: DOCK-10 opens or raises the one window per app per phone. |
| CONV-MAC-12 | n/a: no window of ours. |
| CONV-MAC-13 | applies: the tile's menu holds each item once, with no doubled separator (DOCK-4). |
| CONV-MAC-14 | n/a: no layout of ours. |
| CONV-MAC-15 | n/a: the shim is a separate bundle. |
| CONV-MAC-16 | n/a: no drag, drop, copy or Services. |
| CONV-MAC-20 | applies: the phone page follows the system appearance (the screenshots are dark and light). |
| CONV-MAC-21 | applies: every menu item and the Save all switch carry a label and help tag (SET-DEV-19). |
| CONV-MAC-22 | n/a: no animation or glass. |
| CONV-MAC-23 | applies: the Save all switch is a labelled toggle, its state is the switch, not a colour. |
| CONV-MAC-24 | n/a: no permission is asked for. |
| CONV-MAC-25 | applies: menu items and the switch use the system's own states. |
| CONV-MAC-26 | applies: the switch sits in its own section with its explanation. |
| CONV-AND-01 | n/a: no phone-side navigation. |
| CONV-AND-02 | n/a: no phone-side UI. |
| CONV-AND-03 | n/a: the app list needs no runtime permission. |
| CONV-AND-04 | applies: building or removing a shim changes nothing on the phone. |
| CONV-PD-01 | applies: 0, 1 and 2+ phones above; the phone is part of every id and name. |
| CONV-PD-02 | applies: an app list reconciles on connect; offline keeps the shims; no shim binary disables the controls with a reason. |
| CONV-PD-03 | n/a: nothing here waits on the phone. |
| CONV-PD-04 | n/a: no live control. |
| CONV-PD-05 | applies: logs carry paths, counts and states, never app labels or the phone's name. |
| CONV-PD-06 | applies: DOCK-6 keeps the icon fetch and builds off the main thread. |
| CONV-PD-07 | applies: "Add to Applications", "Remove from Applications" and "Save all apps as shortcuts" are the one set of names (docs/UX.md). |
| CONV-PD-08 | applies: the states/events table above and `DockOrigins.applying`. |
| CONV-PD-09 | applies: every item names its result; a disabled item carries the reason. |

## Non-goals

- A second kind of bundle, or a shortcut outside the one folder.
- The phone pushing app installs (`apps.changed`): reconciliation happens on the app lists the Mac gets today (connect, refresh).
- Writing the Mac's Dock preferences.
- Adding shortcuts for apps of a phone this Mac cannot reach (except the stored Save all value, applied at the next app list).

## Open questions

- [NEEDS CLARIFICATION] None.
