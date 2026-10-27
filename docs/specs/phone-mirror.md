# Phone Mirror

Prefix: `MIRROR`. Owner docs: [design/phone-mirror.md](../design/phone-mirror.md), [design/mac-redesign.md](../design/mac-redesign.md) §3.7 (stream windows), [UX.md](../UX.md) § "Mac windows", [design/controls.md](../design/controls.md) (the volume pattern the panel shares), [NFR.md](../NFR.md). Last reviewed: 2026-10-27, against main `66dd3ea`.

## Purpose

The Phone Mirror shows the phone's own screen — home screen, apps, notification shade, lock screen — in a window on the Mac, 1:1 and live, so the person can use the phone with a mouse and keyboard while it stays in their hand or on the desk. It is one of the app's two stream windows (the other is an app's own window): it is passive — it launches nothing on the phone and changes nothing there unless the person asks for "Turn Off Phone Screen" — and it is the only window where the phone's own screen *is* the content, so the phone's screen power, its secure surfaces and its rotation are first-class states rather than edge cases.

## User stories

| ID | Priority | Story |
|---|---|---|
| MIRROR-S1 | P1 | As a person, I want the phone's screen on my Mac, so that I can use an app the Mac cannot launch by itself. |
| MIRROR-S2 | P1 | As a person opening it, I want to see that it is opening and, if it cannot, why, so that a blank window is never the answer. |
| MIRROR-S3 | P1 | As a person whose phone screen slept, I want the mirror to say so and offer one way to wake it, so that a dark picture is not mistaken for a broken app. |
| MIRROR-S4 | P2 | As a person, I want to keep the phone's screen dark while I mirror it, so that the phone on my desk does not light up. |
| MIRROR-S5 | P1 | As a person, I want Back, Home and Recents on the window's bar, so that I can navigate without the phone in my hand. |
| MIRROR-S6 | P2 | As a person, I want the window to follow the phone's rotation and never look stretched, so that a turned phone is still usable. |
| MIRROR-S7 | P1 | As a person, I want the window to keep my place and my size, so that reopening it is not a new setup. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| MIRROR-1 | WHEN the person asks for the Phone Mirror from the Deck's Phone button, ⌘P, Phone ▸ Phone Mirror, the menu-bar panel's Mirror or an MCP tool WHILE that phone's mirror is already open THE Mac SHALL raise that window (unminimising it) and SHALL NOT open a second; asking again after it was closed SHALL open a fresh one; the Phone menu's item SHALL be enabled only while the phone is online. | K2 `PhoneWindowSingleTests.testOpeningTwiceReturnsTheOneMirror`, `testReopeningAfterCloseMakesAFreshMirror`, `testASecondOpenUnminimisesTheMirror`, `MenuMarksTests.testPhoneMirrorIsEnabledOnlyWhileThePhoneIsOnline`; e2e `mirror` `[MIRROR-1]` (three asks, one `window.open` and one stream; one window on screen; the menu item enabled) |
| MIRROR-2 | WHEN the window opens THE Mirror SHALL cover the picture with the phone's icon and name, a spinner and "Opening your phone…", then "Still opening…" after 5 s and "Couldn't open your phone." with Try Again and Close after 20 s without a frame; the cover SHALL be a frozen mode (no input to the phone) and the first frame SHALL remove it for good. | K2 `OpeningCoverTests.testTheCoverMovesThroughItsPhasesAtFiveAndTwentySeconds`, `testTheFirstFrameEndsTheCoverForGood`, `testTryAgainRestartsTheClock`, `testTheSentencesAreTheDocumentedOnes`; e2e `mirror` `[MIRROR-2]` (both ends of the cover, and the 3 s first frame) |
| MIRROR-3 | WHEN the window opens, re-opens or its session reconnects THE Mac SHALL send exactly one `phone.wake`, and the phone SHALL wake display 0 without unlocking it or changing a lock or timeout setting. | K2 `PhoneScreenOverlayTests.testOpeningThePhoneWindowWakesOnce`; e2e `mirror` `[MIRROR-3]` |
| MIRROR-4 | THE window SHALL show the stream at display 0's aspect, portrait or landscape, fitted inside the screen's visible frame (75% of its height when it opens), SHALL refuse a size below its bar's width, SHALL keep the phone's aspect on every resize, and SHALL NOT enter native full screen: the green button zooms to the phone's aspect fit instead and Window ▸ Enter Full Screen is disabled for it. | K2 `FullScreenMenuTests.testOnlyAWindowThatHasNotOptedOutMayGoFullScreen`, `GeometryTests`, `WindowFrameLimitTests`; e2e `mirror` `[MIRROR-4]` (portrait, both full-screen opt-outs, the aspect) |
| MIRROR-5 | WHEN the phone rotates THE window SHALL turn within one 300 ms poll and keep its top-left corner and picture area, the phone SHALL send a new `VIDEO_CONFIG`, and a rotation reported during a live resize SHALL apply when the drag ends. | review of `PhoneWindow.followRotation` and `PhoneChrome.turnedPhone`; e2e `mirror` `[MIRROR-5]` (the window turns, the landscape config) |
| MIRROR-6 | WHILE the phone reports `screen: off` THE window SHALL blur and dim the held frame and show "The phone's screen is off" with a Wake Screen button within `stale_picture_ms`, SHALL send no input while the cover is up, and SHALL NOT show the last frame as live; a phone that never reports `screen` SHALL get no cover. | K2 `PhoneScreenOverlayTests.testScreenOffShowsTheCoverAndOnClearsIt`, `testAClickOnTheCoverWakesAndNoInputLeaves`, `testAClickOnADisabledBarButtonNeverReachesThePhone`; e2e `mirror` `[MIRROR-6]`; e2e `nfr` (frozen screen off) |
| MIRROR-7 | WHEN Wake Screen is clicked (or the frame is clicked while the cover is up) THE Mac SHALL send one `phone.wake`, and WHEN the phone reports `screen: on` THE cover SHALL clear, the window SHALL leave the frozen mode and frames SHALL resume with a new `VIDEO_CONFIG`. | K2 `PhoneScreenOverlayTests.testAnOpenAsksForOneWakeAndEveryClickWhileCoveredOneMore`; e2e `mirror` `[MIRROR-7]` |
| MIRROR-8 | WHILE the phone reports a secure surface (`state.secure`, or half a second of near-black frames while the screen is on as the fallback) THE window SHALL blur and dim the frame and show "Android doesn't let PocketDeck show this screen." with no button, SHALL send no input, and SHALL clear the cover when the phone reports the surface gone or a frame with content arrives. | K2 `PhoneScreenOverlayTests.testASecureSurfaceCoversWithNoWakeAndClearsOnTheReport`, `testBlackFramesForHalfASecondCoverAndContentClears`, `BlackFrameTests.testThePixelTestOnlyCoversAGridOfBlack`; e2e `mirror` `[MIRROR-8]` |
| MIRROR-9 | WHEN the person turns on Turn Off Phone Screen (the bar control or Phone ▸ Turn Off Phone Screen) THE Mac SHALL ask the phone to hold its own panel off (`phone.panel`, carrying the per-phone `ignorePower` value), the phone SHALL keep rendering while the mirror stays open, the mirror SHALL keep sending frames, and the choice SHALL be remembered per phone, off by default; a phone that does not report `state.panel` SHALL leave the control alone. | K1 `PanelHoldTest`; K2 `PhoneScreenOverlayTests.testKeepItOffIsRememberedPerPhone`, `testTurnOffPhoneScreenIsRememberedPerPhone`, `testAPhoneThatDoesNotReportThePanelLeavesTheOptionAlone`; e2e `mirror` `[MIRROR-9]` (off by default, the request, the frames, `ignorePower:false`) |
| MIRROR-10 | THE bar's glyph and check SHALL follow the phone's `state.panel` only — never the click: WHILE the phone reports the panel off they SHALL show off, and a report that arrives late SHALL redraw within `panel_glyph_ms` of the report, not of the click. | K2 `PhoneScreenOverlayTests.testPanelStateNeedsItsFirstReportThenOnlySpeaksOnATransition`, `testThePanelOffStateReachesTheMenuTheBarAndTheChromeState`; e2e `mirror` `[MIRROR-10]` (both ways, the late report) |
| MIRROR-11 | IF the phone answers `phone.panel` with an error, or `state.panel` has not changed within 2 s of the request THEN THE window SHALL leave the control unchecked and show "The phone didn't turn its screen off" for 2 s, rather than claim the screen went off. | K2 `PhoneScreenOverlayTests.testAPanelErrorSaysSoAndLeavesTheButtonUnchecked`, `testAPanelRequestThatGoesUnansweredSaysSoAfterTwoSeconds`, `testThePanelPillComesDownOnItsOwn`; e2e `mirror` `[MIRROR-11]` |
| MIRROR-12 | WHEN the person presses the phone's power button WHILE the mirror holds the panel off THE hold SHALL end, the phone SHALL restore its panel and the Mac SHALL follow the report; with "Keep the phone screen off until I turn it on from the Mac" on, the screen SHALL light only until the next keep-alive step and the hold SHALL stand; closing the window, ending the session, a disconnect and crash recovery SHALL each restore the panel, and the phone SHALL stay locked either way. | K1 `PanelHoldTest` (every way in and out); e2e `mirror` `[MIRROR-12]` (the power press ends it) |
| MIRROR-13 | THE bar SHALL carry one capsule of Back, Home and Recents and one control for Turn Off Phone Screen, as glass buttons at the right end, each 32×28 pt with a 14 pt symbol and a help tag ("Back", "Home", "Recents", "Turn Off Phone Screen"/"Phone Screen Off"); a click on each SHALL send that `nav` action to the phone, and WHILE the picture is frozen (Live Text or a cover) every bar button except Live Text SHALL be disabled and dimmed. | K2 `HeaderBarClickTests.testTheHitTestAtEachButtonsCentreReturnsThatButton`, `testAMouseDownAndUpOnAButtonRunsItsActionOnce`, `LiveTextInputGateTests`; e2e `mirror` `[MIRROR-13]` (a real click each, a nav each) |
| MIRROR-14 | WHILE the window is the key window its keys and pointer SHALL act on the phone: ⌘F SHALL be meta+F in the app, ⌘[ Back, ⇧⌘H Home and ⌘↑ Recents (phone mode only), Esc SHALL send Back when no sheet is open, a side or swipe Back SHALL send exactly one Back per gesture, a two-finger scroll SHALL be a finger drag, a pinch or rotate SHALL be two fingers at the pointer, hover SHALL be a mouse over Android, and an ordinary click SHALL be a touch at display 0's real coordinates. | K2 `NavShortcutTests`, `ScrollMappingTests`, `TrackpadGestureTests`, `HoverInputTests`, `SecondaryClickTests`, `HeaderBarClickTests`; review of `InputMapper`'s phone mode coordinates |
| MIRROR-15 | WHILE the link is down THE window SHALL stay open on its last frame, show a "Reconnecting…" pill after 1 s and "Phone offline" after 15 s, drop input rather than queue it, and reopen the window on reconnect; nothing SHALL close the window on a drop. | K2 `StreamWindowWatchdogTests`, `WindowChromeTests` (the pill's texts); review of `WindowManager.reopenAll`; e2e `mirror` (its reconnect step is not part of this check today) |
| MIRROR-16 | WHEN a file is dropped on the window THE Mirror SHALL accept it as a transfer at display 0 (an `.apk`/`.apks`/`.xapk` installs instead), show the sending progress and then the outcome for 5 s, and SHALL refuse a second drop while one is running with a reason. | K2 `FileDropTests` (start, chunks, refusal codes), `ApkBundleTests`; e2e `drop` |
| MIRROR-17 | THE window SHALL restore the frame it had last time, SHALL open inside the screen it opens on, SHALL never be larger than that screen's visible frame, and SHALL keep its top-left position and picture area when it resizes. | K2 `WindowFrameLimitTests`; review of `PhoneWindow.frameKey`/`windowWillResize` |
| MIRROR-18 | THE window's title SHALL be the phone's display name — its nickname first — and SHALL retitle at once when the nickname changes; the mirror SHALL add no Dock icon and no ⌘-Tab entry of its own. | K2 `PhoneNicknamesTests`; review of `PhoneWindow.retitle`; e2e `nickname` |
| MIRROR-19 | WHILE Live Text is on THE window SHALL freeze the bar and the phone navigation shortcuts (they act on a paused phone behind a frozen frame) and SHALL leave the Live Text button itself usable; leaving the mode SHALL restore them. | K2 `LiveTextModeTests`, `LiveTextInputGateTests`, `HeaderActionPolicy` tests; e2e `livetext` |
| MIRROR-20 | THE first frame SHALL arrive within `first_frame_phone_ms`; opening and closing the window SHALL send no write to the phone; and WHEN frames stop without a state change THE window SHALL say so within `stale_picture_ms` (NFR.md). | e2e `nfr` (first frame, read-only open/close, stale picture); K2 `FrameWatchdogTests`, `StreamWindowWatchdogTests` |
| MIRROR-21 | THE window SHALL log its picture state (screen on/off, secure, cover, panel) and nothing about the picture's content: no app name, notification text, media title or pixel data. | e2e `mirror` `[MIRROR-21]` (the state lines); review of `Log.video` calls |
| MIRROR-22 | EVERY bar control SHALL have a VoiceOver label and role and a help tag; the cover's sentence and its button SHALL be readable, in reading order; and a bar control SHALL keep at least 3:1 contrast over white, black and busy frames, in light and dark. | K2 `BarContrastTests`, `PhonePanelP3Tests.testTheWindowButtonIsNamedPhoneMirror` (the shared name); e2e `chrome` (the bar's geometry) |

Priority note: MIRROR-1, 2, 3, 6, 7, 13, 15, 17 and 20 are P1 — the window is unusable or dishonest without them. The panel hold, the secure cover and drops are P2.

## States and events

The picture is one state machine (`PhoneScreenOverlay`, `macOS/Sources/PocketDeck/PhoneScreenOverlay.swift`, with `OpeningCover` before the first frame). The panel hold is the phone's machine (`PanelHold.kt`: `Off`, `Applying`, `Held`, `Suspended`, `Restoring`); the Mac only reads `state.panel` and says what it reads.

| State | Event | Result |
|---|---|---|
| Opening (no frame) | `first frame` | Live; the cover is gone for good |
| Opening | `5 s` / `20 s` | "Still opening…" / "Couldn't open your phone." + Try Again + Close (frozen) |
| Opening | `Try Again` | the same open again; the clock restarts |
| Live | `screen: off` | Covered (screen off): blurred, dimmed, Wake Screen; input frozen |
| Covered (screen off) | `screen: on` | Live; frames resume, new `VIDEO_CONFIG` |
| Covered (screen off) | `click` / `Wake Screen` | one `phone.wake`; the cover stays until the phone reports the screen on |
| Live | `secure: true`, or 0.5 s of black frames | Covered (secure): blurred, dimmed, one sentence, no button; input frozen |
| Covered (secure) | `secure: false`, or a frame with content | Live |
| Live | `black frames` WHILE `screen: off` or `secure: true` | ignored (the report already covers it) |
| any covered | any bar button, shortcut, click or key | ignored: nothing reaches the phone |
| Live | `Live Text on` | Frozen (Live Text); the bar but its own button disabled, shortcuts off |
| Live / Covered | `link lost` | the frame stays; "Reconnecting…" after 1 s, "Phone offline" after 15 s; input dropped |
| Live / Covered | `frames stop, no state change` | Stalled after the watchdog's grace: the window says so (never the old frame as live) |
| any | `window close` / `session end` | the hold ends and the panel is restored (panel off) |
| Live, panel off | `state.panel off` | the bar glyph and the check go off; a 2 s "Phone screen off" pill |
| Live, panel off | `state.panel on` (the phone's own power press, or the hold ended) | the bar glyph and the check go on; a 2 s "Phone screen on" pill |
| Live, request sent | `2 s without a state.panel change` | "The phone didn't turn its screen off" for 2 s; the check stays off |
| Live, request sent | `error{unavailable\|bad_request}` | the same failure pill at once; the check stays off |
| Live | `rotation` | the window turns, keeping its top-left and area; the phone sends a new `VIDEO_CONFIG` |
| any | `rotation reported during a live resize` | applied when the drag ends |

Ignored events, stated so nobody builds them: a `screen`/`secure`/panel report while the window is closing, a second `phone.wake` while one is in flight, a click on the cover with Wake Screen already asked (one per click is the rule), a rotation while a drag owns the frame, and any input while the cover or Live Text is up.

## Phone count and connection

| Situation | The Mirror shows |
|---|---|
| 0 phones | No mirror can open: the Deck is in Welcome/Nearby and every entry point is disabled (Phone button) or absent (no phone menu item that can act). |
| 1 phone | The one mirror. |
| 2+ phones | The mirror of the phone **in use**; one window per phone, so switching phones and opening again gives the other phone's mirror, and each stays one window. There is no picker in the window: Settings ▸ Use This Phone decides. |
| Connecting | The opening cover until the first frame; the window opens from the Deck only while the link is online, and a reconnect after a drop keeps the window up with its pill. |
| Connected | The live picture; the bar follows the phone's reports. |
| Offline / reconnecting | The last frame, "Reconnecting…" then "Phone offline"; input dropped, no queueing; the window closes only when the person closes it. |
| Key rejected (Pair again) | Same as offline (the link cannot come back until the person pairs again); the Deck's banner carries Pair again. |
| Phone that can't mirror | Today: nothing honest. The phone's `error{mirror_unavailable}` (pre-14 builds) is not mapped, so the window sits on the opening cover and fails after 20 s with "Couldn't open your phone." and Try Again, which fails again. See CONV-PD-02 and misses.md. |
| Screen off / locked | The blurred, dimmed frame with "The phone's screen is off" and Wake Screen; a lock screen itself is shown as the phone draws it (the mirror never unlocks). |
| Secure surface | The blurred, dimmed frame with "Android doesn't let PocketDeck show this screen." and no button. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: MIRROR-14 (⌘F is meta+F in the app; the window has no search field) |
| CONV-MAC-02 | applies: File ▸ Close ⌘W closes the window, ⌘M/⌘Q/⌘,/⌘H are the standard ones and the window takes none; ⌃⌘F does nothing here because the window opts out of full screen (MIRROR-4) |
| CONV-MAC-03 | deviates, unapproved: Tab/⇧Tab and Return are sent to the phone as keys (the window's keys belong to the phone) rather than moving Mac focus, and Esc sends Back instead of closing anything; [NEEDS CLARIFICATION] whether the bar's buttons need a keyboard route of their own (misses.md) |
| CONV-MAC-04 | applies: the editing keys are forwarded to Android's focused field as meta keys; review of `InputMapper` |
| CONV-MAC-05 | n/a: the mirror keeps the phone's own dp width — Density is disabled for it (`usesDensity` false) |
| CONV-MAC-06 | applies: ⌘P, ⇧⌘C, ⌘[, ⇧⌘H, ⌘↑ are in menus; every bar button has a help tag (MIRROR-13) and the menu items carry the keys |
| CONV-MAC-07 | applies: ⌘P is the app's one re-used shortcut and it opens this window (MIRROR-1) |
| CONV-MAC-10 | n/a: the window is not the status item's panel |
| CONV-MAC-11 | applies: MIRROR-1 (one window per phone; every entry point raises it) |
| CONV-MAC-12 | applies: MIRROR-17 (frame remembered, opens on screen, never larger than the screen) |
| CONV-MAC-13 | applies: the Window menu carries the one Enter/Exit Full Screen item and it is disabled for this window (menus.md) |
| CONV-MAC-14 | applies: MIRROR-4 and MIRROR-5 (the aspect on every resize; the bar's minimum width keeps the buttons off the traffic lights) |
| CONV-MAC-15 | n/a: closing the mirror does not quit the app, and the Deck stays where it was |
| CONV-MAC-16 | applies: MIRROR-16 (a drop is accepted with progress or refused with a reason) |
| CONV-MAC-20 | applies: the window, its cover and its bar render in light and dark, with the accent and Increase Contrast |
| CONV-MAC-21 | applies: MIRROR-22 |
| CONV-MAC-22 | applies: Reduce Motion removes the reconnecting pulse and the pill's fade; Reduce Transparency replaces the glass capsules with a solid fill |
| CONV-MAC-23 | applies: MIRROR-6/MIRROR-8 (the cover is words, not a colour), MIRROR-22 (text size follows the system) |
| CONV-MAC-24 | applies: the window asks for no permission; waking the panel needs none |
| CONV-MAC-25 | applies: every bar button and capsule has a hover and pressed state, and a frozen button is dimmed neutral (MIRROR-13) |
| CONV-MAC-26 | applies: one right inset for the bar and one 6 pt rhythm between capsules; the cover's text sits on one inset |
| CONV-AND-01 | applies: MIRROR-13 (Back/Home/Recents are the phone's own key events on display 0, under either navigation mode) |
| CONV-AND-02 | n/a: no phone-side UI is drawn by this window |
| CONV-AND-03 | n/a: no Android permission is asked from this window |
| CONV-AND-04 | applies: MIRROR-9 and MIRROR-12 (the hold is the only phone change, asked for, and every way out restores the panel; the phone stays locked) |
| CONV-PD-01 | applies: MIRROR-1 and the table above (0, 1, 2+; one window per phone) |
| CONV-PD-02 | [NEEDS CLARIFICATION] connecting, connected, offline and pair-again are MIRROR-15 and MIRROR-2; a phone that **can't** mirror gets no reason at all (the generic 20 s failure) — a break of "disabled with a reason, never hidden" (misses.md) |
| CONV-PD-03 | applies: MIRROR-10 and MIRROR-11 (the check and glyph follow the phone's report, never the click; a refusal is a pill with the reason) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value in this window |
| CONV-PD-05 | applies: MIRROR-21 |
| CONV-PD-06 | applies: MIRROR-20 (`first_frame_phone_ms`, `stale_picture_ms`, `panel_glyph_ms`, zero writes) |
| CONV-PD-07 | applies: "Phone Mirror" everywhere — the menu item, the panel's "Mirror" with VoiceOver "Phone Mirror", the Deck's Phone button help "Open Phone Mirror" (MIRROR-1, MIRROR-4) |
| CONV-PD-08 | applies: the picture model and the phone's panel-hold machine are the tables above |
| CONV-PD-09 | applies: MIRROR-11 (the pill says what happened: "The phone didn't turn its screen off"), MIRROR-2 ("Couldn't open your phone."), MIRROR-13 (every bar button's help tag) |

## Assumptions

- The phone runs API 34+ and exposes `DisplayManager.createVirtualDisplay` at the shell UID (docs/design/phone-mirror.md): the mirror is a passive capture of display 0.
- `state.screen` and `state.secure` are reported by a phone that supports them; a phone that does not report them reads as "screen on" and is covered by its frames alone (the black-frame fallback after 0.5 s).
- The Mac can always wake display 0 at the shell UID (`wakeUpWithDisplayId(0)`, else `input keyevent KEYCODE_WAKEUP`); a wake never unlocks.
- The window shares the stream layer with app windows, so resize debounce, the watchdog, the link pill, Live Text and the bar geometry are the same code.
- "Turn Off Phone Screen" is a request with an answer; the phone owns the panel and its restore.

## Non-goals

- Full screen for the mirror (a phone aspect across a whole display is letterboxed or stretched).
- Launching apps or changing the phone's home screen from the mirror: the mirror is passive.
- Keeping the phone awake, unlocking it, dismissing the keyguard or changing a lock or screen-timeout setting (product promise).
- A phone picker, several mirrors side by side, or a mirror of a virtual display: one window, one phone.
- Scrolling the phone's screen as a page (the stream is a touch surface, not a document).
- Recording, screenshotting or OCR-ing the stream beyond Live Text's own feature.

## Open questions

- [NEEDS CLARIFICATION] A phone that cannot mirror (pre-14, `mirror_unavailable`) deserves one sentence and no Try Again loop. Recommended: map the error to "This phone can't share its screen with PocketDeck." with Close only, and prove it with a fake-phone flag.
- [NEEDS CLARIFICATION] Should the mirror's bar be reachable from the keyboard (Tab to Back/Home/Recents/Turn Off Screen) even though Tab otherwise types on the phone? Recommended: yes, with ⌃Tab as the Mac's own key, because a person who cannot use a pointer cannot reach those buttons today (CONV-MAC-03/CONV-MAC-21).
- [NEEDS CLARIFICATION] "Turn Off Phone Screen" and the phone's own power button fight while `ignorePower` is on (the phone relights for up to 2 s every keep-alive step). Recommended: keep it; the setting's sentence already says it, but the person should confirm it is not spooky in use.
