# App windows

Prefix: `WIN`. Owner docs: [design/mac-redesign.md](../design/mac-redesign.md) §3.7 and §3.9, [UX.md](../UX.md) § "macOS app" 2 and § "Opening a window", [DESIGN.md](../DESIGN.md) "App windows", [design/dragdrop.md](../design/dragdrop.md) (the drop pill), [NFR.md](../NFR.md). Last reviewed: 2026-10-27, against main `6073e3c`.

## Purpose

One Mac window per app running on the phone: the phone launches that app on a virtual display whose size the window asks for, and the window draws its stream. It is how a person uses a phone app with a mouse and keyboard, alongside the Phone Mirror (the phone's own screen, MIRROR) and the Deck (the launcher, DECK). A window is a view of one app on the phone **in use**: it starts nothing else, changes no phone setting, and outlives nothing — closing it closes that app's stream, not the app's data and not the session.

The same AppKit window kind carries three subjects: an app (`AppWindowController`, the one this spec is about), a link (`LinkWindowController`, `design/links.md`) and a handoff window (`HandoffWindowController`, `design/handoff.md`). They share the chrome, the input mapper, the opening cover, the resize rules and the picture watchdog; they differ in what they show and in how their style and frame are remembered (a link or handoff window has one frame, an app window one per package).

## User stories

| ID | Priority | Story |
|---|---|---|
| WIN-S1 | P1 | As a person with a phone, I want an app in its own window so that I can use it with the Mac's keyboard and pointer while the phone stays where it is. |
| WIN-S2 | P1 | As a person opening one, I want to see that it is opening and, if it will not, why and what to try, so that a black window is never the answer. |
| WIN-S3 | P1 | As a person with two phones, I want the window's title to name the app and the phone so that I know which phone it acts on. |
| WIN-S4 | P2 | As a person, I want the window's chrome out of the way (immersive) or always there (framed), remembered per app, so that I do not choose again each time. |
| WIN-S5 | P2 | As a person, I want an app too small or too large for the Mac's screen to keep its layout by changing its density, so that the app is readable. |
| WIN-S6 | P1 | As a person resizing the window, I want the picture to stay correct on every frame so that a drag never shows black bands or a clipped app. |
| WIN-S7 | P1 | As a person, I want the window back where and how big I left it so that reopening is not a new setup. |
| WIN-S8 | P1 | As a person, I want closing the window to end only that window so that my other work and the connection survive. |
| WIN-S9 | P2 | As a person whose phone went away, I want the window to say so and come back on its own so that I know whether the picture is live. |
| WIN-S10 | P2 | As a person with a large screen, I want an app window full screen so that the app uses the space. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| WIN-1 | WHEN the person opens an app (a Deck cell, a Dock shim, Spotlight, Shortcuts, MCP, a notification click) THE Mac SHALL open one AppKit stream window for that app on the phone in use and send one `window.open` for it, carrying the stream's pixel size and dpi; the phone SHALL launch the app on a virtual display of that size. | e2e `chrome` `[WIN-1]` (one `window.open` per stream); e2e `pair` (three `window.open` for three subjects); review of `WindowManager.open`/`AppWindowController.sendOpen` |
| WIN-2 | WHEN an app's window is opening and the person asks for that app again THE Mac SHALL raise the window already opening and SHALL NOT send a second `window.open`; WHEN the window is no longer opening THE Mac SHALL open a new window with its own stream (two windows of one app are two streams). | K2 `OpeningDedupeTests.testASecondOpenWhileTheAppIsOpeningRaisesTheSameWindow`, `testAFinishedWindowDoesNotSwallowANewOpen` |
| WIN-3 | THE window's title SHALL be "<app label> (<phone name>)" — the phone's nickname first, its own name otherwise, and just the label while no name is known — and SHALL retitle at once when the app list arrives late or the nickname changes; the title SHALL be hidden outside full screen and SHALL still name the window in the Window menu and Mission Control. | e2e `nickname` `[WIN-3]` (the app window retitled); K2 `PhoneNicknamesTests`; review of `WindowManager.titled`/`setPhoneName` |
| WIN-4 | THE window SHALL be the 900×600 pt stream plus the style's 28 pt bar above it and nothing on the other three sides, SHALL never be smaller than a 320×240 pt stream, and SHALL NOT clip the picture at any size it is drawn at (1280×800 is the smallest supported screen). | e2e `chrome` `[WIN-4]` (900×628, the stream's own edges and bottom); K2 `WindowStyleTests.testFramedIsTheStreamPlusTheBar`, `testImmersiveIsTheStreamExactly`, `testTheBarNeverChangesTheStreamsWidthOrFullScreenSize` |
| WIN-5 | THE stream SHALL be asked for at the window's points × the display's backing scale, floored to a multiple of 16 px, clamped to 320–2560 px with the aspect kept, and the dpi SHALL be `160 × pixels / points × density`; a 2560 px cap SHALL lower the dpi rather than crop. | e2e `resize` `[WIN-5]` (1600×1200, a tall shape, the 2560 cap and its dpi); e2e `chrome` `[WIN-5]` (the one size through three launches); K2 `GeometryTests` (the floor, the clamp, the aspect, the dpi) |
| WIN-6 | WHEN the window's shape changes THE Mac SHALL send one `window.resize` after 300 ms of quiet, and at once when a drag ends; WHILE the answer is pending THE last frame SHALL fill the window (a centred crop, no black bands), for at most 2 s, and the answer's own frame SHALL be the normal rule again; the window's top-left SHALL stay put. | e2e `resize` `[WIN-6]` (the held answer, the fill, the settled picture, ten fast steps with no gap); K2 `VideoFillTests` (the fill, the timeout, the crop's input mapping) |
| WIN-7 | THE window SHALL wear one of two styles — Framed (the default) or Immersive — remembered per app package and re-applied when the app is known; switching SHALL grow or shrink the window by the 28 pt bar so the stream keeps its place, SHALL move it down only as far as the bar would poke above the visible frame, and SHALL change nothing while full screen; ⌥⌘F SHALL toggle and View ▸ Framed / Immersive SHALL set the same choice (menus.md MENU-4). | e2e `chrome` `[WIN-7]` (both styles, the stored key, the down-move, the toggle near the top); K2 `WindowStyleTests` (every switch), `WindowChromeTests.testSwitchingStylesKeepsTheStreamAndIsRemembered`, `StyleShortcutTests.testOptionCommandFTogglesTheStyleAndNeverReachesThePhone` |
| WIN-8 | WHILE the window is immersive and not full screen THE chrome SHALL be out of sight until the pointer rests still in a 72×32 pt hot zone at the stream's top-left for the reveal delay (Instantly 0, Short 350 ms by default, Long 700 ms), then a clear-glass pill SHALL fade in over 0.12 s and fade out 0.6 s after the pointer leaves the pill and the zone; a click in the zone before the pill shows SHALL be the app's ordinary touch and SHALL restart the rest; a click on the pill's background SHALL drag the window and its traffic lights SHALL minimise and close it. | e2e `chrome` `[WIN-8]` (immersive at rest, the rest, the click-through touch, the minimise light, no touch from the chrome); K2 `WindowStyleTests` (`testNothingShowsBeforeTheDwell` … `testTheHotZoneAndPillAreTheOnesTheDesignAsksFor`), `WindowChromeTests.testCloseAndMinimiseWorkWithTheBar` |
| WIN-9 | WHEN the person picks View ▸ Hide Controls ▸ Always Visible THE immersive window SHALL keep its lights and capsules up with no hot zone and no dwell, past the hide delay, and SHALL store the choice as the profile's one reveal setting (Settings ▸ General "Reveal controls after"); picking Instantly, Short or Long SHALL restore the dwell and hide the chrome again. | e2e `chrome` `[WIN-9]` (up past the delay, the stored value, Short hides it); K2 `ImmersiveMenuTests` (the submenu, the check, the stored value) |
| WIN-10 | WHEN ⌘+ / ⌘− / ⌘0 or a View ▸ Density item is used WHILE an app window is key THE Mac SHALL change that app's density in one 0.25 step inside 0.75–1.5 (⌘0 clears the override) and re-send the resize so the phone's layout follows, SHALL store it per package, and SHALL leave every other app's windows and the Phone Mirror alone; an app with no override SHALL follow Settings ▸ General's default and SHALL follow a change to it at once. | e2e `density` `[WIN-10]` (the app's dpi, the other window untouched, the stored key, Default clears it); K2 `WindowDensityTests` (every rule), `MenuModelTests`/`MenuMarksTests` (the Density items) |
| WIN-11 | WHILE the stream has no first frame THE window SHALL cover the picture with the app's icon and label, a spinner and "Opening on your phone…", then "Still opening…" after 5 s and "Couldn't open <app>." with Try Again and Close after 20 s; the cover SHALL be a frozen mode (no input to the phone); Try Again SHALL send the same open again and restart the clock; the first frame SHALL remove the cover for good. | K2 `OpeningCoverTests` (the phases, the first frame, Try Again, the sentences), `WindowChromeTests.testAWindowIsFrozenUntilItsFirstFrame` |
| WIN-12 | WHEN the person presses ⌘W or clicks the close light THE Mac SHALL close that window, send one `window.close` for its stream, and SHALL NOT quit the app, close another window or touch the session; closing the last window SHALL leave the app and its session running, and only ⌘Q SHALL quit. | K2 `WindowChromeTests.testCloseAndMinimiseWorkWithTheBar` (⌘W closes, minimise round-trips); review of `StreamWindowController.windowWillClose`/`sendClose` and `App.swift`'s `applicationShouldTerminateAfterLastWindowClosed`; menus.md MENU-2 (File ▸ Close ⌘W) |
| WIN-13 | WHEN an app's window opens THE Mac SHALL use the frame remembered for that package (when it is at least 240×160 pt and still on a screen, pushed inside it when only partly off), else cascade a new window 28 pt from the previous one starting at the main screen's top-left, and SHALL NOT open it centred over the Deck; moving or finishing a drag SHALL remember the frame for the next open and for a relaunch; the window SHALL NOT be moved again while it is up. | untested — the check to write: move a window, close it, reopen it (and relaunch) and assert the frame per package; a saved frame on a display that went away opens centred. Today only `WindowManager.savedFrame`/`nextCascadeOrigin`/`clampedToScreen` are reviewed |
| WIN-14 | WHEN the Window menu's Enter Full Screen (⌃⌘F) or the green light is used THE window SHALL fill its screen, drop the bar in either style and hand the title and the traffic lights to the system's revealed bar; leaving full screen SHALL restore the windowed frame and the style's chrome; the one Enter / Exit Full Screen item SHALL read what it will do and SHALL NOT be disabled for an app window. | e2e `chrome` `[WIN-14]` (an app window keeps the item; the full-screen runs are visible-only); K2 `WindowChromeTests.testFullScreenShowsTheTitleAndHandsTheLightsBackOnExit`, `FullScreenMenuTests.testOnlyAWindowThatHasNotOptedOutMayGoFullScreen` |
| WIN-15 | WHILE the window is key its keys and pointer SHALL belong to the phone: ⌘F, ⌘A, ⌘C, ⌘X and ⌘Z SHALL reach the app as meta keys, ⌘V SHALL send the pasteboard's text, Tab, Return, the arrows, Home/End and Page Up/Down SHALL be the phone's keys, Esc and ⌘[ SHALL be one Back, a click SHALL be a touch at the stream's real coordinates and a scroll or pinch SHALL be the phone's gesture; ⌘+ / ⌘− / ⌘0 and ⌥⌘F SHALL stay the window's, and ⌘W, ⌘M, ⌘Q, ⌘, and ⌘H SHALL stay the app's. | K2 `NavShortcutTests`, `ScrollMappingTests`, `TrackpadGestureTests`, `HoverInputTests`, `SecondaryClickTests`, `HeaderBarClickTests`, `StyleShortcutTests.testCommandFStillReachesThePhone`; e2e `deck` `[DECK-9]` (a stream window's ⌘F as meta+F); e2e `nav` (⌘[ and Esc each send one `nav back` in an app window) |
| WIN-16 | WHEN the link drops THE window SHALL stay open on its last frame, show a "Reconnecting…" pill after 1 s and "Phone offline" after 15 s, drop input rather than queue it, and re-open its stream when the link returns; nothing SHALL close the window. | untested — the check to write: drop the link with an app window open, assert the pill at 1 s and 15 s, zero input after the drop, and a new `window.open` on reconnect. Today `StreamWindowController.setLinkDown`/`WindowManager.linkRestored` are reviewed |
| WIN-17 | WHEN frames stop without a state change for 1.5 s (four missed 500 ms heartbeats) THE window SHALL show a "Not responding" pill, freeze the phone-side controls, and resume when a frame arrives; a paused, covered, occluded or covered-by-a-cover window SHALL NOT be called stalled, and the phone's own power press SHALL get 1.7 s of grace before the rule applies (NFR: no stale picture, `stale_picture_ms`). | K2 `StreamWindowWatchdogTests.testAPowerPressHoldsTheLastFrameAndARealStallStillShows`, `FrameWatchdogTests`; e2e `mirror` `[MIRROR-6]` proves the rule for the phone window (an app window has no stale-picture check of its own) |
| WIN-18 | WHEN the window is minimised or fully occluded THE Mac SHALL send `window.pause`, and `window.resume` when it is visible again; a key or main window SHALL never be paused by a stale occlusion report, and a window being closed SHALL send neither. | untested — e2e `pause` exercises the pair for a scripted minimise but its two lines carry no WIN ID; review of `StreamWindowController.shouldPause`/`setPaused` |
| WIN-19 | A size set from outside (an Accessibility resize, a tiler, a script) SHALL be fitted inside the screen's visible frame without moving the window, so a window a person cannot reach is never produced; the app's own picture-sized frames SHALL be exempt. | e2e `chrome` `[WIN-19]` (an AX resize to 4000 pt leaves every window inside the visible frame); K2 `WindowFrameLimitTests` (the fitted size, the minimum, the aspect) |
| WIN-20 | THE window SHALL change nothing on the phone beyond opening and sizing the stream it shows: no phone setting, no other app, no notification permission, and the phone SHALL stay locked. | review of `AppWindowController.sendOpen`/`sendResize`; AGENTS.md product promises |
| WIN-21 | THE window SHALL write no app name, window title, file name or picture content to a log or a crash report: stream ids, sizes, states and reason codes only. | review of the stream window's `Log.video` calls; e2e `chrome`, `resize` and `drop` (their log lines carry ids, sizes and states only) |
| WIN-22 | EVERY bar control SHALL have a VoiceOver label, a role and a help tag, SHALL keep at least 3:1 contrast over white, black and busy frames, and SHALL have a hover and a pressed state; a frozen control SHALL be dimmed neutral and read as dimmed, and the window's minimum width SHALL fit the bar beside the traffic lights. | K2 `BarChromeTests.testSymbolsKeepThreeToOneOverWhiteBlackAndBusyFrames`, `LiveTextFreezesEveryKindButItsOwn`, `WindowChromeTests.testThePhoneBarFitsBesideTheLightsAtItsMinimumWidth`; e2e `chrome` (the bar's geometry) |
| WIN-23 | THE first frame of an app window SHALL arrive within `first_frame_ms` (NFR.md) of the open, and WHILE the window is resized its drawn frames SHALL keep the picture inside the window with no gap (`video_gap` ≤ 1 px). | e2e `nfr` (the first-frame limit); e2e `resize` `[WIN-6]` (no gap at any step) |
| WIN-24 | THE Mac SHALL keep at most one `window.resize` in flight per stream and at most one value waiting behind it (the newest); a request equal to the one in flight, or to the last one the phone applied, SHALL NOT be sent; at the density clamp a ⌘+/⌘− press SHALL be a no-op (nothing sent); and the waiting value SHALL go out when the phone answers (`window.resize.ack`) or the resize's `VIDEO_CONFIG` arrives — never on a timer. THE phone SHALL answer every `window.resize` (resized, density, same, kept), SHALL treat an identical one as a no-op, and SHALL change only the display density for a same-size dpi change, rebuilding no encoder. | K2 `ResizeCoalescerTests` (every transition, the clamp, a burst of ten); K1 `ResizeLedgerTest`, `ResizePlanTest` (density only), the session's ack test; e2e `density` (ten ⌘+ presses reach the phone as two requests, never a repeat); the emulator burst (`deckctl density-burst`, real encoder: one attach, no frame gap, `density_burst_first_frame_ms`/`density_burst_stall_ms`) |

Priority note: WIN-1, 2, 3, 4, 6, 11, 12, 13, 15, 20 and 22 are P1 — a window that opens, says what it is, obeys the keyboard, keeps its picture and closes cleanly is the surface. Style, density, Always Visible, the reconnect pill and full screen are P2.

## States and events

The window has one lifecycle (`Opening` → `Live` → closed) whose picture states are `PhoneScreenOverlay`-like covers of its own (`OpeningCover`, the link pill, the stall pill), one style value, one density value and one placement. The style and density are stored values, not modes: each window reads them at open.

| State | Event | Result |
|---|---|---|
| Opening (no frame) | `first frame` | Live; the cover is gone for good |
| Opening | `5 s` / `20 s` | "Still opening…" / "Couldn't open <app>." + Try Again + Close; frozen |
| Opening | `Try Again` | the same `window.open` again; the clock restarts |
| Live | `window.resize` sent | the last frame fills the window until the answer (≤ 2 s); a request equal to the one in flight or the last one sent is not sent at all |
| Live | `⌘+ / ⌘−` at the clamp | nothing: the press cannot change the density, so no request is made |
| Live | `answer frame` | the picture is the answer's; normal aspect rule |
| Live | `frames stop 1.5 s` | Stalled: "Not responding" pill, phone-side controls frozen |
| Stalled | `a frame` | Live |
| Live / Stalled | `link lost` | "Reconnecting…" after 1 s, "Phone offline" after 15 s; input dropped |
| any | `link returns` | the window re-sends its `window.open` |
| Live | `minimised / occluded` | `window.pause`; the watchdog's clock idles |
| Paused | `visible again` | `window.resume`; the clock restarts from now |
| Live | `style switch (⌥⌘F, menu)` | the window grows or shrinks by the bar; the choice is stored |
| Live | `⌘+ / ⌘− / ⌘0` | the app's density steps or clears; one `window.resize` |
| any | `⌘W / close light` | `window.close`; the window leaves the manager |
| any | `phone closed the stream` (`window.closed`) | the window closes without sending `window.close` |
| Live | `⌘Q` | every window closes; the app quits |

Ignored events, stated so nobody builds them: a second open of an app that is still opening, a resize request that arrives during the live drag (it waits for the drag's end), a style or density switch while full screen (only the memory moves, the layout applies on exit), a ⌘+/⌘− on a window with no app package, and any input while the cover, the stall or the link down is up.

## Phone count and connection

| Situation | The window shows |
|---|---|
| 0 phones | No app window can open: the Deck is in Welcome/Nearby and every entry point needs an online phone. |
| 1 phone | One window per open app; its title names the app and that phone. |
| 2+ phones | The window belongs to the phone **in use** and keeps its stream; its title names that phone. Switching phones (Settings ▸ Use This Phone) closes every window of the previous phone (settings.md SET-DEV-03) and the next app opens on the new one. |
| Connecting | No window opens; the Deck's chip carries the state (DECK-14). |
| Connected | The stream, the bar as the style says, the picture live. |
| Offline / reconnecting | The last frame, "Reconnecting…" then "Phone offline"; input dropped, no queueing; the window re-opens its stream on reconnect and closes only when the person closes it. |
| Key rejected (Pair again) | The link cannot return until the person pairs again; the window keeps its last frame and its pill, and the Deck's banner carries Pair again. |
| Phone that can't show the app | Today: the cover fails after 20 s with "Couldn't open <app>." and Try Again, which fails again — the phone's `error` reason is not mapped to a sentence (misses.md, CONV-PD-02). |
| Frozen picture | Cover (opening), stall ("Not responding"), link down or Live Text: the phone-side controls are disabled and no input is sent. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: WIN-15 (⌘F is meta+F in the app — the window is a stream window, whose keys belong to the phone; it has no search field) |
| CONV-MAC-02 | applies: File ▸ Close ⌘W closes the key window (WIN-12), ⌥⌘W closes all, ⌘M minimises (WIN-18), ⌘Q quits, ⌘, opens Settings, ⌘H hides; the window takes none of them for another meaning |
| CONV-MAC-03 | deviates, unapproved: Tab, ⇧Tab and Return are sent to the phone as keys rather than moving Mac focus, and Esc sends Back rather than closing anything (WIN-15), because the window's keys are the phone's — [NEEDS CLARIFICATION] whether the bar needs a keyboard route of its own (misses.md) |
| CONV-MAC-04 | applies: the editing keys are forwarded to Android's focused field as meta keys (WIN-15) |
| CONV-MAC-05 | applies: WIN-10 (⌘+/⌘−/⌘0 set the app's density; View ▸ Density names the same keys, MENU-4) |
| CONV-MAC-06 | applies: every shortcut the window offers is in a menu (⌥⌘F, ⌘+/⌘−/⌘0, ⌘[, ⇧⌘H, ⌘↑, ⇧⌘T, ⌃⌘F — MENU-8) or a help tag; the phone's own keys are not the app's shortcuts |
| CONV-MAC-07 | n/a: the app's one re-used key is ⌘P = Phone Mirror, not this window's |
| CONV-MAC-10 | n/a: the window is not the status item's panel |
| CONV-MAC-11 | deviates, unapproved: an app window opens **once while it is opening** (WIN-2) but a second open after the first frame makes a second window of the same app on the same phone — two streams of one app (misses.md) |
| CONV-MAC-12 | applies: WIN-13 (the frame per package is restored, clamped inside the screen) and WIN-19 (never larger than the screen); the restore itself is untested |
| CONV-MAC-13 | applies: WIN-14 (the one Enter / Exit Full Screen item, disabled only for the Phone Mirror; the menus are menus.md MENU-7) |
| CONV-MAC-14 | applies: WIN-4 and WIN-6 (laid out per frame, the fill covers a drag, nothing clipped at the minimum) |
| CONV-MAC-15 | applies: WIN-12 (closing a window never quits; ⌘Q alone quits) |
| CONV-MAC-16 | applies: a drop on the window is accepted, refused with a reason, or refused while the phone is away (files.md FILES-13/14); copy and paste are WIN-15's keys |
| CONV-MAC-20 | applies: the stream, the bar's mirror and the pills render in light and dark, with the accent and Increase Contrast; the bar shows the stream's own colours |
| CONV-MAC-21 | applies: WIN-22 |
| CONV-MAC-22 | applies: the pills fade over 0.12 s / 0.3 s and Reduce Motion removes the pulse and the fades; Reduce Transparency replaces the glass pill with a solid fill |
| CONV-MAC-23 | applies: WIN-17 and WIN-16 (a pill says what happened in words as well as a dot); text follows the system's size where the cover and the pills allow |
| CONV-MAC-24 | applies: the window asks for no permission and overrides no Focus; a banner is the system's, so the person's Do Not Disturb silences it |
| CONV-MAC-25 | applies: WIN-22 (hover and pressed on every bar control; a frozen control is dimmed neutral) |
| CONV-MAC-26 | applies: one 7 pt inset for the bar's lights and capsules and one 6 pt rhythm between capsules; the cover's text sits on one inset |
| CONV-AND-01 | applies: WIN-15 (Back/Home/Recents are the phone's own key events under either navigation mode; Home and Recents act only in a phone-mode window — an app window's ⇧⌘H and ⌘↑ are consumed and do nothing) |
| CONV-AND-02 | n/a: the window draws no phone-side UI |
| CONV-AND-03 | n/a: no Android permission is asked from this window |
| CONV-AND-04 | applies: WIN-20 (opening an app changes no phone setting; the phone stays locked and its own timeout applies) |
| CONV-PD-01 | applies: the table above (0, 1, 2+ phones; the window follows the phone in use and Settings switches) |
| CONV-PD-02 | applies: WIN-11, WIN-16 and the table above; a phone that cannot show an app gets the generic 20 s failure instead of a sentence (misses.md) |
| CONV-PD-03 | n/a: the window starts nothing the phone must confirm; opening is a request whose failure is the cover, and every state shown comes from the phone's frames or reports |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value in this window |
| CONV-PD-05 | applies: WIN-21 |
| CONV-PD-06 | applies: WIN-23 (`first_frame_ms`), WIN-6 (no gap while resizing) and WIN-17 (`stale_picture_ms`); the window runs no work of its own beyond its 0.25 s watchdog tick |
| CONV-PD-07 | applies: "Phone Mirror", "Framed", "Immersive", "Density", "Hide Controls", "Always Visible", "Live Text" carry one meaning across the window, the menu and Settings (MENU-13) |
| CONV-PD-08 | applies: the lifecycle and its covers are the table above; the style and density are stored values, not states |
| CONV-PD-09 | applies: WIN-11 ("Couldn't open <app>." names the app and the next step), WIN-16 ("Reconnecting…", "Phone offline"), WIN-17 ("Not responding"), WIN-22 (a help tag on every bar control) |

## Assumptions

- The phone runs API 34+ and can create a virtual display at the shell UID (`docs/design/phone-mirror.md`); an app window is that display's stream.
- The app's label comes from the cached app list; before it arrives the window is titled with the package's last part, and the phone's `window.title` corrects it.
- 1280×800 is the smallest supported screen; the window's own minimum is a 320×240 pt stream plus the bar.
- The window's style and density are stored in the active profile's defaults (`chrome.style.<pkg>`, `chrome.density.<pkg>`), never in the person's default domain.
- A link window and a handoff window share this window kind but are remembered under one frame each (`link`, `handoff`), and their subjects are `design/links.md`'s and `design/handoff.md`'s.

## Non-goals

- The Phone Mirror: the phone's own screen is MIRROR's window, not an app window.
- Launching an app from a window, a second launcher, or several windows of one app by design (see CONV-MAC-11's miss — two windows are two streams, not two views of one).
- A Dock icon or ⌘-Tab entry of its own: the Dock identity is `design/dock.md`'s surface (`DOCK`).
- Live Text, Show Touches, the style/density menus and the Shortcuts/App Intents entries: their own surfaces (MENU, `LIVETEXT`, `INTENTS`).
- A window picker, tabs, several apps in one window, or picture-in-picture.
- Remembering the scroll position, the app's own state, or reopening an app at launch: the phone owns the app.
- Keeping the phone awake, unlocking it, or changing a lock or screen-timeout setting (product promise).

## Open questions

- [NEEDS CLARIFICATION] Is two windows of the same app on the same phone intended (CONV-MAC-11 says one per thing)? Recommended: no — raise the existing window on a Deck cell click the way the Dock shim and a notification click already do; two streams of one app cost two virtual displays and confuse which window the phone's app is in.
- [NEEDS CLARIFICATION] Should an app window remember its size and position per package (CONV-MAC-12) or per app **and** phone? Today the key is `app.<pkg>`, so two phones share one frame. Recommended: keep one frame per package until several phones can be connected at once.
- [NEEDS CLARIFICATION] A phone that refuses to show an app (`error{...}`, a pre-14 build) gets "Couldn't open <app>." after 20 s and a Try Again that cannot work. Recommended: map the phone's error to one sentence with Close only (CONV-PD-02), proved by a fake-phone flag.
- [NEEDS CLARIFICATION] "Opening on your phone…" (UX.md and the cover) versus "Opening your phone…" (the Phone Mirror): is the app window's line the documented one? Recommended: keep "Opening on your phone…" for an app window and MIRROR's own line for the mirror.
- [NEEDS CLARIFICATION] DESIGN.md still describes a 52 pt hidden header band and a `.unified` toolbar, and `setFrameAutosaveName`; the code has a 28 pt bar, no toolbar and its own `streamFrames` store. Recommended: code wins; the design doc is corrected (the spec records the code).
