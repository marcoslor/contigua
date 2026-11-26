# Phone Mirror

Prefix: `MIRROR`. Owner docs: [design/phone-mirror.md](../design/phone-mirror.md), [design/mac-redesign.md](../design/mac-redesign.md) §3.7 (stream windows), [UX.md](../UX.md) § "Mac windows", [design/controls.md](../design/controls.md) (the volume pattern the panel shares), [NFR.md](../NFR.md). Last reviewed: 2026-10-27, against main `66dd3ea`.

## Purpose

The Phone Mirror shows the phone's own screen — home screen, apps, notification shade, lock screen — in a window on the Mac, 1:1 and live, so the person can use the phone with a mouse and keyboard while it stays in their hand or on the desk. It is one of the app's two stream windows (the other is an app's own window): it is passive — it launches nothing on the phone and changes nothing there unless the person asks for "Turn Off Phone Screen" — and it is the only window where the phone's own screen *is* the content, so the phone's screen power, its secure surfaces and its rotation are first-class states rather than edge cases. Its stream follows WIN-59 and WIN-60: the same codec choice, and the same refusal of a codec the Mac cannot decode.

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
| MIRROR-2 | THE Mirror SHALL wear the L1 cover (WIN-11): the phone's icon on the window's dark ground, the 2 pt accent sweep and "Phone — opening on <phone>"; at 5 s "Taking longer than usual" and Cancel (which closes the window and cancels the open on the phone); at 20 s, or at once when the phone answers the open with `error{mirror_unavailable}`, the icon greys and the cover says "<phone> can't open the phone screen." with the reason line "This phone can't share its screen with Contigua." and Close only, SHALL NOT offer Try Again and SHALL NOT send another `window.open`; the cover SHALL be a frozen mode (no input to the phone, the bar's phone controls dimmed) and the first frame SHALL remove it for good. | K2 `OpeningCoverTests.testTheCoverMovesThroughItsPhasesAtFiveAndTwentySeconds`, `testTheFirstFrameEndsTheCoverForGoodAndIsNotedOnce`, `testCancelClosesTheWindowFromOpeningOrSlowOnly`, `testRefusedCodesMapToTheirReasonLine`, `testTheTitlesAndSentencesAreTheDocumentedOnes`, `testTheFailureAndSlowLayoutsPutTheirButtonsWhereTheDesignDoes`; e2e `mirror` `[MIRROR-2]` (both ends of the cover, the 3 s first frame, and the refused phone: one sentence, Close only, one `window.open` past the 20 s mark) |
| MIRROR-3 | WHEN the window opens, re-opens or its session reconnects THE Mac SHALL send exactly one `phone.wake`, and the phone SHALL wake display 0 without unlocking it or changing a lock or timeout setting. | K2 `PhoneScreenOverlayTests.testOpeningThePhoneWindowWakesOnce`; e2e `mirror` `[MIRROR-3]` |
| MIRROR-4 | THE window SHALL show the stream at display 0's aspect, portrait or landscape, fitted inside the screen's visible frame (75% of its height when it opens), SHALL refuse a size below its bar's width, SHALL keep the phone's aspect on every resize, and SHALL NOT enter native full screen: the green button zooms to the phone's aspect fit instead and View ▸ Enter Full Screen is disabled for it. | K2 `FullScreenMenuTests.testOnlyAWindowThatHasNotOptedOutMayGoFullScreen`, `GeometryTests`, `WindowFrameLimitTests`; e2e `mirror` `[MIRROR-4]` (portrait, both full-screen opt-outs, the aspect) |
| MIRROR-5 | WHEN the phone rotates THE window SHALL turn within one 300 ms poll and keep its top-left corner and picture area, the phone SHALL send a new `VIDEO_CONFIG`, and a rotation reported during a live resize SHALL apply when the drag ends. | review of `PhoneWindow.followRotation` and `PhoneChrome.turnedPhone`; e2e `mirror` `[MIRROR-5]` (the window turns, the landscape config) |
| MIRROR-6 | WHILE the phone reports `screen: off` THE window SHALL draw the shared cover (WIN-65): the held frame blurred hard (radius about 30 pt) and darkened, as one sheet reaching under the titlebar and the bar so no band of another colour sits on top; WHEN no frame is held it SHALL use a gradient of the last frame's average colours, else plain black, and never a flat grey. On it THE window SHALL show "The phone's screen is off" in white 15 pt semibold and a glass capsule Wake Screen button whose white label reads at WCAG AA contrast in light and dark appearance, the words wrapping and never cut, within `stale_picture_ms`; the cover SHALL fade in over 200 ms and out when the screen comes on. It SHALL send no input while the cover is up, and SHALL NOT show the last frame as live; a phone that never reports `screen` SHALL get no cover. | K2 `PhoneScreenOverlayTests.testScreenOffShowsTheCoverAndOnClearsIt`, `testAClickOnTheCoverWakesAndNoInputLeaves`, `testAClickOnADisabledBarButtonNeverReachesThePhone`, `CoverRuleTests.testEveryCoverWrapsItsTextAtTheMinimumWidth`, `testEveryCoverIsTheHeldFrameOrAGradientNeverGrey`, `testEveryCoverKeepsItsTextAtAAContrastInBothAppearances` (the ISS-55 checks, folded into the cover-generic ones: the held frame or a gradient, the sheet under the titlebar, and the Wake Screen label's AA contrast); e2e `mirror` `[MIRROR-6]`; e2e `nfr` (frozen screen off) |
| MIRROR-7 | WHEN Wake Screen is clicked (or the frame is clicked while the cover is up) THE Mac SHALL send one `phone.wake`, and WHEN the phone reports `screen: on` THE cover SHALL clear, the window SHALL leave the frozen mode and frames SHALL resume with a new `VIDEO_CONFIG`. | K2 `PhoneScreenOverlayTests.testAnOpenAsksForOneWakeAndEveryClickWhileCoveredOneMore`; e2e `mirror` `[MIRROR-7]` |
| MIRROR-8 | WHILE the phone reports a secure surface (`state.secure`, or half a second of near-black frames while the screen is on as the fallback) THE window SHALL draw the shared cover (WIN-65) over the held frame and show "Android doesn't let Contigua show this screen." in white 15 pt semibold, wrapping and never cut, with no button, SHALL send no input, and SHALL clear the cover when the phone reports the surface gone or a frame with content arrives. | K2 `PhoneScreenOverlayTests.testASecureSurfaceCoversWithNoWakeAndClearsOnTheReport`, `testBlackFramesForHalfASecondCoverAndContentClears`, `BlackFrameTests.testThePixelTestOnlyCoversAGridOfBlack`, `CoverRuleTests.testEveryCoverWrapsItsTextAtTheMinimumWidth`, `testEveryCoverIsTheHeldFrameOrAGradientNeverGrey`, `testEveryCoverKeepsItsTextAtAAContrastInBothAppearances`; e2e `mirror` `[MIRROR-8]` |
| MIRROR-9 | WHEN the person turns on Turn Off Phone Screen (the bar control or Phone ▸ Turn Off Phone Screen) THE Mac SHALL ask the phone to hold its own panel off (`phone.panel`, carrying the per-phone `ignorePower` value), the phone SHALL keep rendering while the mirror stays open, the mirror SHALL keep sending frames, and the choice SHALL be remembered per phone, off by default; a phone that does not report `state.panel` SHALL leave the control alone. | K1 `PanelHoldTest`; K2 `PhoneScreenOverlayTests.testKeepItOffIsRememberedPerPhone`, `testTurnOffPhoneScreenIsRememberedPerPhone`, `testAPhoneThatDoesNotReportThePanelLeavesTheOptionAlone`; e2e `mirror` `[MIRROR-9]` (off by default, the request, the frames, `ignorePower:false`) |
| MIRROR-10 | THE bar's glyph and check SHALL follow the phone's `state.panel` only — never the click: WHILE the phone reports the panel off they SHALL show off, and a report that arrives late SHALL redraw within `panel_glyph_ms` of the report, not of the click. | K2 `PhoneScreenOverlayTests.testPanelStateNeedsItsFirstReportThenOnlySpeaksOnATransition`, `testThePanelOffStateReachesTheMenuTheBarAndTheChromeState`; e2e `mirror` `[MIRROR-10]` (both ways, the late report) |
| MIRROR-11 | IF the phone answers `phone.panel` with an error, or `state.panel` has not changed within 2 s of the request THEN THE window SHALL leave the control unchecked and show "The phone didn't turn its screen off" for 2 s, rather than claim the screen went off. | K2 `PhoneScreenOverlayTests.testAPanelErrorSaysSoAndLeavesTheButtonUnchecked`, `testAPanelRequestThatGoesUnansweredSaysSoAfterTwoSeconds`, `testThePanelPillComesDownOnItsOwn`; e2e `mirror` `[MIRROR-11]` |
| MIRROR-12 | WHEN the person presses the phone's power button WHILE the mirror holds the panel off THE hold SHALL end, the phone SHALL restore its panel and the Mac SHALL follow the report; with "Keep the phone screen off until I turn it on from the Mac" on, the screen SHALL light only until the next keep-alive step and the hold SHALL stand; closing the window, ending the session, a disconnect and crash recovery SHALL each restore the panel, and the phone SHALL stay locked either way. | K1 `PanelHoldTest` (every way in and out); e2e `mirror` `[MIRROR-12]` (the power press ends it) |
| MIRROR-13 | THE bar SHALL carry one capsule of Back, Home and Recents and one control for Turn Off Phone Screen, as glass buttons at the right end, each 32×28 pt with a 14 pt symbol and a help tag ("Back", "Home", "Recents", "Turn Off Phone Screen"/"Phone Screen Off"), and a click on each SHALL send that `nav` action to the phone; WHEN ⌃Tab is pressed WHILE the window is key THE Mac SHALL move the keyboard into the bar (its first enabled button, with a focus ring), ←/→ and Tab/⇧Tab SHALL move between its buttons, Return or Space SHALL press the focused one, and Esc or ⌃Tab SHALL give the keyboard back to the picture without sending anything; the bar's keys SHALL NOT reach the phone, and every button SHALL have a help tag and an AX label naming its action; WHILE the picture is frozen (Live Text or a cover) every bar button except Live Text SHALL be disabled and dimmed, and a disabled button SHALL never take the focus. | K2 `HeaderBarClickTests.testTheHitTestAtEachButtonsCentreReturnsThatButton`, `testAMouseDownAndUpOnAButtonRunsItsActionOnce`, `LiveTextInputGateTests`, `BarFocusTests` (every transition, the keys the picture keeps, the frozen bar, the labels and the ring), `BarKeyRoutingTests` (Tab is Android's, ⌃Tab is the bar's, the bar's keys stop at the bar); e2e `mirror` `[MIRROR-13]` (a real click each, a nav each, and the keyboard: ⌃Tab → Back, Return → nav back, → → Home, Esc → the picture with no Back) |
| MIRROR-14 | WHILE the window is the key window its keys and pointer SHALL act on the phone: ⌘F SHALL be meta+F in the app, ⌘[ Back, ⇧⌘H Home and ⌘↑ Recents (phone mode only), Esc SHALL send Back when no sheet is open, a side or swipe Back SHALL send exactly one Back per gesture, a two-finger scroll SHALL be a finger drag, a pinch or rotate SHALL be two fingers at the pointer, hover SHALL be a mouse over Android, and an ordinary click SHALL be a touch at display 0's real coordinates. | K2 `NavShortcutTests`, `ScrollMappingTests`, `TrackpadGestureTests`, `HoverInputTests`, `SecondaryClickTests`, `HeaderBarClickTests`; K1 `AndroidInjectorTest.testAKeyFramesCtrlReachesTheApp` `[MCP-110]` `[MIRROR-14]` (a ⌘ key frame keeps its meta and reaches the app as a shortcut); review of `InputMapper`'s phone mode coordinates |
| MIRROR-15 | WHILE the link is down THE window SHALL stay open on its last frame, show a "Reconnecting…" pill after 1 s and "Phone offline" after 15 s, drop input rather than queue it, and reopen the window on reconnect; nothing SHALL close the window on a drop. | review of `StreamWindow`'s link pill and `WindowManager.reopenAll`; K2 `StreamWindowWatchdogTests` (no frames are invented while covered); untested end to end (no check drops the link with a mirror open) |
| MIRROR-16 | WHEN a file is dropped on the window THE Mirror SHALL accept it as a transfer at display 0 (an `.apk`/`.apks`/`.xapk` installs instead), show the sending progress and then the outcome for 5 s, and SHALL refuse a second drop while one is running with a reason. | K2 `FileDropTests` (start, chunks, refusal codes), `ApkBundleTests`; e2e `drop` |
| MIRROR-17 | THE window SHALL restore the frame it had last time, SHALL open inside the screen it opens on, SHALL never be larger than that screen's visible frame, and SHALL keep its top-left position and picture area when it resizes. | K2 `WindowFrameLimitTests`; review of `PhoneWindow.frameKey`/`windowWillResize` |
| MIRROR-18 | THE window's title SHALL be the phone's display name — its nickname first — and SHALL retitle at once when the nickname changes; the mirror SHALL add no Dock icon and no ⌘-Tab entry of its own. | K2 `PhoneNicknamesTests`; review of `PhoneWindow.retitle`; e2e `nickname` |
| MIRROR-19 | WHILE Live Text is on THE window SHALL freeze the bar and the phone navigation shortcuts (they act on a paused phone behind a frozen frame) and SHALL leave the Live Text button itself usable; leaving the mode SHALL restore them. | K2 `LiveTextModeTests`, `LiveTextInputGateTests`, `HeaderActionPolicy` tests; e2e `livetext` |
| MIRROR-20 | THE first frame SHALL arrive within `first_frame_phone_ms`; opening and closing the window SHALL send no write to the phone; and WHEN frames stop without a state change THE window SHALL say so within `stale_picture_ms` (NFR.md). | e2e `nfr` (first frame, read-only open/close, stale picture); K2 `FrameWatchdogTests`, `StreamWindowWatchdogTests` |
| MIRROR-21 | THE window SHALL log its picture state (screen on/off, secure, cover, panel) and nothing about the picture's content: no app name, notification text, media title or pixel data. | e2e `mirror` `[MIRROR-21]` (the state lines); review of `Log.video` calls |
| MIRROR-22 | EVERY bar control SHALL have a VoiceOver label and role and a help tag; the cover's sentence and its button SHALL be readable, in reading order; and a bar control SHALL keep at least 3:1 contrast over white, black and busy frames, in light and dark. | K2 `BarChromeTests.testSymbolsKeepThreeToOneOverWhiteBlackAndBusyFrames`, `WindowChromeTests.testThePhoneBarFitsBesideTheLightsAtItsMinimumWidth`, `PhonePanelP3Tests.testTheWindowButtonIsNamedPhoneMirror` (the shared name); e2e `chrome` (the bar's geometry) |
| MIRROR-26 | WHILE the Mirror wears Compact its title SHALL be the window's own title (MIRROR-18: the phone's display name, the nickname first), drawn in its band in the band's tone as WIN-68 and WIN-69 require, and SHALL NOT gain a second " (<phone>)" suffix (it already names the phone); in Framed the same name is drawn on the frame's bar in the system label colour and fitted as WIN-68 requires (WIN-71); in Immersive the pill shows no title (WIN-74); it SHALL NOT show the mirrored app's title or a task label, and the title SHALL never be logged. | K2 `BarTitleLayoutTests.testTheNamesAreOnlyNames` (the phone's own name is not doubled), `FramedTitleViewTests.testTheTitleDrawsThePhoneSuffixAndDropsItFirst`, `PhoneNicknamesTests`; e2e `bar-title` `[MIRROR-26]` (the Compact Mirror wears the band, in light and dark) |
| MIRROR-23 | THE mirror SHALL use the stream windows' one picture feed, so the reference-chain rule (WIN-62) holds for it too: after any break no delta reaches its decoder until a keyframe, the keyframe is asked for once and again after 500 ms, the lines are `chain broken reason=…` and `chain restored after <ms>`, and a 5 s line's `chain_fed` stays 0. | K2 `ChainGuardTests`; e2e `chain` (the storm runs on the Phone Mirror; `chain_fed=0` and every restore ≤ 600 ms) |
| MIRROR-24 | THE mirror SHALL open a remembered frame in the phone's shape: the remembered height SHALL lead, the top-left SHALL stay, and the opening screen's visible frame SHALL scale the stream as one (never width and height apart); WHEN a stream's first `VIDEO_CONFIG` reports a picture whose shape differs from the window's video area by more than 1% THE window SHALL refit to the picture's shape, keeping the top-left and the height, unless a drag is in progress, in which case the refit SHALL happen at the drag's end. | K2 `PhoneChromeTests.testAWrongShapedSavedFrameOpensInThePhonesShape`, `testASavedLandscapeFrameForAPortraitPhoneOpensPortrait`, `testASavedFrameTallerThanTheScreenKeepsTheAspect`, `testTheFirstPictureOfADifferentShapeRefitsTheWindow`, `testAPictureArrivingDuringADragRefitsAtTheDragsEnd`; e2e `mirror` `[MIRROR-24]` (a wrong-shaped saved frame, before and after the first frame) |
| MIRROR-25 | THE mirror's picture SHALL cover the window's video area with no uncovered row or column of a whole pixel at 2× backing: when the phone-mode fit misses by under 1 pt (a whole-point window size against the phone's aspect), or the picture is within 2 % of the area's shape (the whole-point window size and the encoder's own rounding), THE placement SHALL fill, cropping the rounding rather than leaving it as backing; a picture of a clearly different shape SHALL still be fitted, never cropped. | K2 `VideoFillTests.testThePhoneMirrorsPictureCoversEveryWidthAtTwoX` (every 0.5 pt from 240 to 600, framed and glass, no side over 0.5 px uncovered at 2×), `testThePhoneWindowNeverFills` (a clearly different picture still fits), `testTheReportedMirrorPictureMeetsTheBarsBottomEdge` (the reported 592×1280 picture in a 301×653 pt stream fills) |
| MIRROR-27 | THE mirror's drawn picture SHALL meet its video area's four edges on whole device pixels at 1× and 2× backing, in the framed and compact styles: every edge SHALL be placed by flooring its origin and ceiling its far edge on the backing grid, a fit SHALL stay inside the area, and the uncovered area SHALL be 0 device pixels at every width from 280 to 900 pt with a portrait or landscape screen — no backing row between the bar or Compact's band and the picture (ISS-87) and no half-covered (blended) picture row. The app windows use the same drawn rect (WIN-70). | K2 `VideoFillTests.testTheReportedMirrorPictureMeetsTheBarsBottomEdge`, `testTheMirrorPictureMeetsTheContentEdgesAtEveryWidth`; e2e `bar-title` `[MIRROR-27]` (the Compact phone capture: the three device pixels under the band carry no darker-than-both-neighbours row in light and dark) |

Priority note: MIRROR-1, 2, 3, 6, 7, 13, 15, 17 and 20 are P1 — the window is unusable or dishonest without them. The panel hold, the secure cover and drops are P2.

## States and events

The picture is one state machine (`PhoneScreenOverlay`, `macOS/Sources/Contigua/PhoneScreenOverlay.swift`, with `OpeningCover` before the first frame). The panel hold is the phone's machine (`PanelHold.kt`: `Off`, `Applying`, `Held`, `Suspended`, `Restoring`); the Mac only reads `state.panel` and says what it reads.

| State | Event | Result |
|---|---|---|
| Opening (no frame) | `first frame` | Live; the cover is gone for good |
| Opening | `5 s` / `20 s` | "Still opening…" / "Couldn't open your phone." + Try Again + Close (frozen) |
| Opening | `Try Again` | the same open again; the clock restarts |
| Opening | `error{mirror_unavailable}` | Failed: the greys, one sentence and its reason line, Close only; no clock, no Try Again, no new `window.open` |
| Refused | `20 s`, `Try Again`, any key or click but Close | ignored: the phone said it cannot, so asking again cannot help |
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
| Live, request sent | `error` (`unavailable` or `bad_request`) | the same failure pill at once; the check stays off |
| Live | `rotation` | the window turns, keeping its top-left and area; the phone sends a new `VIDEO_CONFIG` |
| any | `rotation reported during a live resize` | applied when the drag ends |

The bar's keyboard focus is one machine (`BarFocus`, `macOS/Sources/Contigua/BarFocus.swift`): picture ↔ bar(index), where `index` is an enabled button in reading order.

| State | Event | Result |
|---|---|---|
| Picture | `⌃Tab` | Bar(first enabled): the ring is drawn, the keys are the bar's |
| Picture | `Tab`, `⇧Tab`, `←`, `→`, `Return`, `Space`, `Esc` | the phone's key, as before (⌃Tab is the only way in) |
| Bar(i) | `→` / `Tab` | Bar(next), wrapping at the last button |
| Bar(i) | `←` / `⇧Tab` | Bar(previous), wrapping at the first |
| Bar(i) | `Return` / `Space` | the focused button runs (a click's action); the ring stays |
| Bar(i) | `Esc` / `⌃Tab` | Picture: no input reaches the phone |
| Bar(i) | any other key | dropped: a focused bar never types on the phone |
| Bar(i) | the button vanishes or is disabled (a cover, Live Text) | Picture, or the ring on the next enabled button; a frozen bar has none |
| Bar(any) | a click on the picture, or the window loses the keyboard | Picture |

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
| Phone that can't mirror | One sentence, once: "This phone can't share its screen with Contigua." with Close only. No Try Again, no 20 s wait and no retry (MIRROR-2). |
| Screen off / locked | The blurred, dimmed frame with "The phone's screen is off" and Wake Screen; a lock screen itself is shown as the phone draws it (the mirror never unlocks). |
| Secure surface | The blurred, dimmed frame with "Android doesn't let Contigua show this screen." and no button. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: MIRROR-14 (⌘F is meta+F in the app; the window has no search field) |
| CONV-MAC-02 | applies: File ▸ Close ⌘W closes the window, ⌘M/⌘Q/⌘,/⌘H are the standard ones and the window takes none; ⌃⌘F does nothing here because the window opts out of full screen (MIRROR-4) |
| CONV-MAC-03 | applies: Tab/⇧Tab and Return are sent to the phone as keys while the picture has the keyboard, because the window's keys belong to the phone; ⌃Tab is the Mac-owned way into the bar, where ←/→, Tab/⇧Tab, Return/Space and Esc act on its buttons and Esc goes back to the picture (MIRROR-13) |
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
| CONV-MAC-22 | applies: Reduce Motion removes the reconnecting pulse and the pill's fade (WIN-77); Reduce Transparency is the system glass's own: the capsules (`NSGlassEffectView`) go solid by themselves; the screen-off cover fades in over 200 ms and out when the screen comes on (MIRROR-6, WIN-65) |
| CONV-MAC-23 | applies: MIRROR-6/MIRROR-8 (the cover is words, not a colour), MIRROR-22 (text size follows the system) |
| CONV-MAC-24 | applies: the window asks for no permission; waking the panel needs none |
| CONV-MAC-25 | applies: every bar button and capsule has a hover and pressed state, and a frozen button is dimmed neutral (MIRROR-13) |
| CONV-MAC-26 | applies: one right inset for the bar and one 6 pt rhythm between capsules; the cover's text sits on one inset |
| CONV-AND-01 | applies: MIRROR-13 (Back/Home/Recents are the phone's own key events on display 0, under either navigation mode) |
| CONV-AND-02 | n/a: no phone-side UI is drawn by this window |
| CONV-AND-03 | n/a: no Android permission is asked from this window |
| CONV-AND-04 | applies: MIRROR-9 and MIRROR-12 (the hold is the only phone change, asked for, and every way out restores the panel; the phone stays locked) |
| CONV-PD-01 | applies: MIRROR-1 and the table above (0, 1, 2+; one window per phone) |
| CONV-PD-02 | applies: MIRROR-15 and MIRROR-2 for connecting, connected, offline and pair again; a phone that **can't** mirror gets one sentence and Close only, never a hidden window and never a retry loop (MIRROR-2) |
| CONV-PD-03 | applies: MIRROR-10 and MIRROR-11 (the check and glyph follow the phone's report, never the click; a refusal is a pill with the reason) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value in this window |
| CONV-PD-05 | applies: MIRROR-21 |
| CONV-PD-06 | applies: MIRROR-20 (`first_frame_phone_ms`, `stale_picture_ms`, `panel_glyph_ms`, zero writes) |
| CONV-PD-07 | applies: "Phone Mirror" everywhere — the menu item, the panel's "Mirror" with VoiceOver "Phone Mirror", the Deck's Phone button help "Open Phone Mirror" (MIRROR-1, MIRROR-4) |
| CONV-PD-08 | applies: the picture model, the phone's panel-hold machine, the shared cover's fade (`CoverFade`, WIN-65) and the shared picture feed's reference chain (MIRROR-23) are the tables above |
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

- [NEEDS CLARIFICATION] "Turn Off Phone Screen" and the phone's own power button fight while `ignorePower` is on (the phone relights for up to 2 s every keep-alive step). Recommended: keep it; the setting's sentence already says it, but the person should confirm it is not spooky in use.
