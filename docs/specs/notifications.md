# Notifications

Prefix: `NOTIFY`. Owner docs: [design/notify.md](../design/notify.md) (all parts), [PROTOCOL.md](../PROTOCOL.md) § "Notifications + media", [UX.md](../UX.md) §4 (the per-phone switches), [settings.md](settings.md) (`SET-DEV-09`–`11`). Last reviewed: 2026-10-28, against `68ce259` (v119).

## Purpose

The phone's notifications, on the Mac, without unlocking it. One per-phone switch forwards them (off until the person turns it on), each becomes one banner in Notification Center with the phone's own buttons, a reply field, Copy code and a clear, and a click does what the person chose: open the app on the Mac, open it on the phone, or nothing. A per-app mute drops a noisy app before it is shown, and an Android 16 Live Update is a row in the menu-bar panel that updates in place. Everything sensitive stays on the two devices: the Mac logs ids, packages, lengths and states — never text — and the only file it writes is a banner's temporary picture, deleted with the banner.

This surface owns the gate, the banners and their content, the click target, actions, codes, images, live rows and the mute list. The per-phone switches' *storage* and their place in Settings are settings.md's (`SET-DEV-09`–`11`); Now Playing and media control are the media surface's; the panel's layout is panel.md's (`PANEL-15` is its LIVE row).

## User stories

| ID | Priority | Story |
|---|---|---|
| NOTIFY-S1 | P1 | As a person, I want my phone's notifications on the Mac only when I say so, so that nothing personal is forwarded by accident. |
| NOTIFY-S2 | P1 | As a person, I want a banner to say which phone and which app it came from, and to carry the phone's own buttons, so that I can answer it without picking the phone up. |
| NOTIFY-S3 | P1 | As a person, I want a click to open the app where I expect — on the Mac or on the phone — so that I am never sent to the wrong screen. |
| NOTIFY-S4 | P1 | As a person, I want clearing a banner to clear the phone's notification too, so that the two do not disagree. |
| NOTIFY-S5 | P2 | As a person, I want a verification code copied in one click, so that I do not retype six digits from a banner. |
| NOTIFY-S6 | P2 | As a person, I want the picture a notification carries and to see which app sent it, so that a message is as readable on the Mac as on the phone. |
| NOTIFY-S7 | P2 | As a person watching a ride or a timer, I want its Live Update as a row I can check, so that progress is glanceable. |
| NOTIFY-S8 | P2 | As a person with one noisy app, I want to mute that app per phone, so that the rest still arrives. |
| NOTIFY-S9 | P1 | As a person without notification access on the phone, I want both ends to say so and to offer the one fix, so that "no notifications" is never a mystery. |
| NOTIFY-S10 | P1 | As a person, I want nothing forwarded while the switch is off, and no text in any log, so that the promise holds even when something breaks. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| NOTIFY-1 | THE forwarding switch SHALL be per phone, Mac-side, off by default and the only person-facing switch; WHEN it is on THE Mac SHALL send one `notify.enable {on:true}` when the session becomes ready, again after every reconnect, and again after a same-session rejoin once the session was orphaned (PATH-6), and SHALL store the choice; WHILE forwarding THE phone SHALL answer every `on:true` with its active set (one quiet `notify.post` per notification it still holds, then `notify.snapshot {ids}`); WHILE it is off THE Mac SHALL send nothing, SHALL ask the phone for nothing and SHALL show no banner from that phone; turning it off WHILE the session is live SHALL stop forwarding at once and clear that phone's forwarded state. | e2e `notify` `[NOTIFY-1]` (the Mac asked; off: no `notify.enable`, no post, no click); e2e `pathgrace` `[NOTIFY-1]` (after the outage the Mac asks again and the active set restores the rows in place, no second banner); K2 `NotifyMacTests`, `SessionOrphanTests` (the rejoin repeats the opt-in), `SessionRebalanceTests` (a planned switch does not), `NotifySnapshotMacTests` (the snapshot reconciles); K1 `NotifyGateTest` (the truth table), `NotifySessionTest` (a repeated enable reaches the listener), `NotifySnapshotTest` (one active-set answer per enable) |
| NOTIFY-2 | WHEN the Mac's switch is on and the phone's notification-listener grant is missing THE phone SHALL make one shell-UID grant attempt, then answer `notify.state {on:false, reason:"no_access"}`; its home SHALL show a "Notification access is off" attention item whose button opens the system's notification-access screen, the Mac's phone page SHALL say "Allow notification access on the phone." under the switch, and a later grant SHALL start forwarding with no further Mac toggle; turning sharing off SHALL clear the reason on both sides. | K1 `NotifySessionTest` (the attempt, `no_access`, the later grant, the revoked grant), `UiStateTest` (the attention item), `NotifyGateTest` (the reply); K2 `DevicesTabTests.testTheNotificationAccessHint`; e2e `settings` `[SET-DEV-09]` |
| NOTIFY-3 | THE phone SHALL forward only a notification a person sees: it SHALL skip its own package (the debug poster excepted in a debug build), an ongoing notification the system did not promote, one with no title and no text, a malformed id, and a text over the wire's cap (dropped whole, never truncated); its body SHALL be the first non-empty of `EXTRA_TEXT` and `EXTRA_BIG_TEXT` (the sub text and summary text are header lines, never the body); it SHALL take a MessagingStyle post's text from the last `EXTRA_MESSAGES` entry when those are empty, with its title from `EXTRA_CONVERSATION_TITLE`, else that message's sender, when `EXTRA_TITLE` is empty, so a conversation is not dropped as contentless (the same per-string cap applies, and an over-cap string is dropped whole); it SHALL NOT forward a notification that carries `EXTRA_MEDIA_SESSION` — Now Playing owns that session, and a paused player is no longer ongoing; its removal is not announced like a skipped summary's; it SHALL advertise at most three actions, each with a title ≤ 64 characters, an index into the notification's own actions and a PendingIntent, marking a reply action; it SHALL skip unusable and system-generated smart actions. | e2e `notify` `[NOTIFY-3]` (a post per package recorded), `notify-actions` `[NOTIFY-3]` (the reply shape's action counts); K1 `NotifyEventsTest` (the fields, the caps, the skips, the actions), `NotifyLiveTest` (`only a promoted ongoing notification is live`), `NotifyConversationTest` (the last message, the sender, the plain fields winning, an empty conversation), `NotifyStyledTextTest` (`a styled sub text arrives as plain text`, `a styled summary text arrives as plain text`), `NotifyMediaSkipTest` (a media session's notification never banners and its removal is silent); design/notify.md § "Actions on the wire" |
| NOTIFY-4 | THE banner's title SHALL be "‹the notification's title, else the app's label› (‹phone name›)" — just the phone name when the title is empty — its body the notification's own text (or the package when the app has no label), its thread the phone's id, or `<phone id>.<group>` when the post carries a group (NOTIFY-20), and it SHALL be silent on the Mac; the Mac SHALL ask for notification permission the first time it posts one, in context. | e2e `notify` `[NOTIFY-4]` (the posts grouped under the phone's id), `notify-actions` `[NOTIFY-20]` (the group's thread); K2 `NotifyMacTests.testTitleBuilderSuffixesThePhoneName`, `testTitleFallsBackToTheAppLabel`, `testTitleOnlyFromAnUnlabeledPackageKeepsTheNameAsBody`, `testATitlelessUnlabeledNotificationIsJustThePhoneName`, `testEmptyContentBecomesTheAppLabelWithThePhoneName`, `testAThreadedPostUsesThePhoneAndTheGroup`; review of `NotifyCenter.deliver` (`sound = nil`, `requestAuthorization`) |
| NOTIFY-5 | WHEN a post arrives with an id already posted THE Mac SHALL replace that banner (not add a second) and SHALL present the replacement again only when the post is alerting (NOTIFY-19); an update that carries a picture SHALL carry it again so the replaced banner keeps it. | K2 `NotifyLiveMacTests.testFirstLivePostBannersAndLaterOnesUpdateInPlace`; review of `NotifyCenter.post` |
| NOTIFY-6 | WHEN the phone takes a notification away (`notify.remove`) THE Mac SHALL remove that banner and its attachment; WHEN the person clears a banner THE Mac SHALL send `notify.dismiss {id}` for it, EXCEPT for a notification the wire marked ongoing, which the Mac SHALL refuse to dismiss and record as refused; a disconnect SHALL clear every banner and every attachment of that phone. | e2e `notify-actions` `[NOTIFY-6]` (the dismiss sent, the ongoing refused and not sent, the phone's remove reaching the Mac), `notify` `[NOTIFY-6]` (a removal recorded); K2 `NotifyMacTests` (the dismiss rule); K1 `NotifyEventsTest` (ongoing and no-clear are not dismissed) |
| NOTIFY-7 | THE click target SHALL be per phone, SHALL default to Open on this Mac, and SHALL be disabled with a sentence while sharing is off; the choices SHALL be Open on this Mac, Open on the phone and Do nothing. | K2 `NotifyMacTests.testClickSettingDefaultsToOpenOnMacAndIsStoredPerPhone`, `testClickSettingMapsToItsAction`; e2e `settings` `[SET-DEV-10]` |
| NOTIFY-8 | WHEN a banner is clicked THE Mac SHALL do exactly one plan: Open on this Mac SHALL open or raise the app's window and then send `notify.open {id, target:"window", stream}` (the window first, so a phone that does not know the message still opens the app); Open on the phone SHALL send `notify.open {id, target:"phone"}` and open no window; Do nothing SHALL send nothing and open nothing; the notification's own action SHALL never cross the wire. | e2e `notify` `[NOTIFY-8]` (the click's window and `window.open`, all three targets); K2 `NotifyMacTests.testDoNothingOpensNothingAndSendsNothing`, `testOpenOnMacOpensTheWindowBeforeSendingSoAnOldPhoneStillOpensIt`, `testNotifyOpenMessageCarriesOnlyTheIdTargetAndWindowStream`; K1 `NotifyOpenTest`, `NotifySessionTest` (`notify open` target validation) |
| NOTIFY-9 | WHEN a banner's button or its reply is used THE Mac SHALL send `notify.action {id, i, text?}`; the phone SHALL validate `i` against the actions it advertised, SHALL fill the RemoteInput with `text` (≤ 4 KiB, reply actions only), SHALL refuse a text on a non-reply action or over the cap, SHALL log an unknown id or index and send nothing, and SHALL NOT answer — its own update or removal flows back as `notify.post`/`notify.remove`; the banner's category SHALL be a hash of its shape (button titles, a reply, a code) with at most 64 registered, never a hash of any text. | e2e `notify-actions` `[NOTIFY-9]` (the category is a shape hash, the reply's index and length, the button's index); K1 `NotifyEventsTest` (`an index that was never advertised is unknown`, `reply text is refused on a non-reply action and over the cap`), `NotifySessionTest` (a malformed id dropped); K2 `NotifyMacTests.testCategoryRegistryReusesShapesAndStaysBounded`, `testCategoryIdIsStablePerShapeAndCarriesNoText` |
| NOTIFY-10 | WHEN a banner's Copy code is used THE Mac SHALL copy the code the notification carries (4–8 digits, or 6–8 alphanumerics with at least two digits, within 32 characters of a code keyword in English, Portuguese or Spanish, rejecting a date, time, amount or phone number), SHALL mark the pasteboard item concealed and transient, and SHALL clear it after 90 s if the pasteboard still holds it; Copy code SHALL exist only while a code was found. | K2 `NotifyCodeTests` (every rule, the 90 s clear, the concealed/transient types); e2e `notify-actions` `[NOTIFY-10]` (a 6-character code copied, the pasteboard's types, then cleared) |
| NOTIFY-11 | WHEN a notification carries a picture THE phone SHALL send at most one, its long side at most 512 px (never upscaled), JPEG or PNG, at most 200 KiB after halving to 512/256/128/64/32, and no picture at all if it cannot fit; the Mac SHALL refuse one that breaks its own caps or names an id it never posted, SHALL keep the banner without a picture, SHALL hold a post at most 300 ms for its picture, SHALL drop a picture that arrives after the hold as late, and SHALL delete the temporary file when the banner goes, on disconnect and on quit. | K2 `NotifyLiveMacTests.testImageCapsAcceptOnlyThePhonePromisedShape`, `testPostLineSaysItIsLiveAndCarriesTheImageFacts`; K1 `NotifyImageTest` (the caps, the halving, the skip), `NotifyWireParityTest` (the shell server forwards every picture field); VM e2e `notify-vm` (a picture on a real banner) |
| NOTIFY-12 | WHEN the phone reports a promoted ongoing notification THE Mac SHALL add it as a live row: the first post banners, later posts update that row in place at most once a second per id (the newest wins), showing the progress as a bar, the chip and the chronometer; the row SHALL appear in the menu-bar panel's LIVE section with the app and its progress or clock; when the phone ends it the row SHALL leave. | K2 `NotifyLiveMacTests` (`testUpdatesInsideOneSecondAreCoalescedAndTheNewestWins`, `testEndRemovesTheRowAndAPendingUpdate`, `testLiveRowCarriesTheChipAndATextProgressBar`, `testAChronometerRunsInItsOwnDirection`); K1 `NotifyLiveTest` (the fields, the one-per-second rule); VM e2e `notify-vm` (the LIVE section and its row) |
| NOTIFY-13 | THE muted-apps list SHALL be per phone: it SHALL offer every app this Mac has cached for that phone plus every package seen this session or already muted, each with its icon and name, searchable by name or package, muted apps first and then by name, one trailing "Muted" checkbox column under a "Muted" header, a system package under a friendly name with its package name beneath, an unknown app by its package name, and a mark on an app that has sent a notification this session; the row SHALL show the count ("2", "None"); a muted package's post SHALL be dropped before it is shown, SHALL stay listed, and SHALL apply to the next notification. | e2e `notify-actions` `[NOTIFY-13]` (the muted package dropped, no banner); K2 `DevicesTabTests` (the count, the rows, the order, the search, the labels, the seen mark), `NotifyMacTests.testMutedSetIsPerPhoneAndSorted`; e2e `settings` `[SET-DEV-11]` |
| NOTIFY-14 | THE phone's and the Mac's logs, the e2e share log and any crash report SHALL carry ids, package names, action indexes, field lengths, counts and closed states only — never a notification's title, text, code, reply or a media title; the only copy of a banner's picture on disk SHALL be its attachment under the profile's caches, `0600` in a `0700` folder, deleted with the banner. | e2e `notify` `[NOTIFY-14]` (no notification text in any log), `notify-actions` `[NOTIFY-14]` (no notification or reply text in any log); K2 `NotifyMacTests.testRecordsCarrySizesAndPackagesNotText`, `NotifyLiveMacTests.testImageAndLiveLinesCarryOnlyFacts`; review of `NotifyCenter.writeAttachment` |
| NOTIFY-15 | A banner's click, dismiss, button, reply and Copy code SHALL run the same handlers the panel's LIVE row and the e2e's debug actions run, so that one notification behaves the same whichever way it is answered. | review of `NotificationRouter`/`NotifyCenter.install` (one router for real and debug responses); e2e `notify` and `notify-actions` (the debug actions reach the same routing) |
| NOTIFY-16 | WHILE sharing is off THE app SHALL send no notification message to the phone and SHALL show no banner from it; reading the Deck, the panel or a phone's settings page SHALL send no notification write; only the person's own control SHALL change the gate. | e2e `notify` `[NOTIFY-1]` (off: nothing in the share log); e2e `nfr` (the read-only Deck and window flows send zero writes; the panel has no read-only phase — PANEL-24); review |
| NOTIFY-17 | A phone that cannot forward SHALL NOT be hidden: the missing listener grant SHALL be a sentence on both ends with the one fix (NOTIFY-2); while macOS has PocketDeck's notifications denied THE phone page SHALL show one line, "Notifications are turned off for PocketDeck in System Settings.", with Open System Settings and Check Again, and SHALL show nothing while the permission is granted or not yet asked; a phone that reports nothing simply sends nothing and the panel's LIVE section stays absent rather than empty. | K1 `UiStateTest` (`no attention for notification access once the Mac is not asking`); K2 `DevicesTabTests.testTheNotificationAccessHint`, `testTheDeniedNotificationPermissionHasOneLine`; e2e `notify` `[NOTIFY-4]` `[NOTIFY-17]` (a denied permission injected: the line and its state on the phone page); review of `PhonePanel`'s `live.isEmpty` section |
| NOTIFY-18 | Banners SHALL be the system's: the person's Focus and Do Not Disturb SHALL silence them as they silence any notification, and the app SHALL NOT override that; a phone's own Do Not Disturb is the phone's business and SHALL NOT be changed by forwarding. The app SHALL set no interruption level above `.active`, and `.passive` only for a quiet update (NOTIFY-19). | review of `NotifyCenter` (the level is set only for a quiet replacement; `sound` is nil); AGENTS.md product promises |
| NOTIFY-19 | WHEN the phone forwards the first post of a key THE phone SHALL mark it `alert:true`; WHEN it forwards an update THE phone SHALL mark it `alert:false` while the notification carries `FLAG_ONLY_ALERT_ONCE` or its title and text hash equals the last forwarded post of that key, or its only change is a progress bar (both posts carry one and the title hash is unchanged), and `alert:true` otherwise (hashes only, never the text; the post that drops the bar is judged by its content as usual); WHEN the Mac receives a post with `alert:false` THE Mac SHALL never present it — it SHALL add it to the list with `interruptionLevel = .passive` when no banner exists and replace a delivered banner the same way — and SHALL keep exactly one banner for the id and record the running presented/quiet counts; a post with `alert:true` SHALL present (a first banner, or the replacement of a delivered one); and WHEN a post arrives while an earlier post of that id is still inside its hold THE Mac SHALL supersede the waiting post, inherit its delivery state and alert if either post is alerting, so a quiet re-post never hides the first banner. | e2e `notify-actions` `[NOTIFY-19]` (10 posts of one key: 1 presented, 9 quiet replacements, 1 delivered banner; a 100 ms re-post that still presents; a first post with `alert:false` listed quietly); K1 `NotifyEventsTest` (the rule, the hash, the wire), `NotifyWireParityTest` (alert reaches the Mac); K2 `NotifyMacTests.testThePostPlanIsTheAndroidAlertRule`, `testTenPostsOfOneKeyPresentOnceAndReplaceQuietly`, `testAnUpdateInsideTheHoldStillPresentsTheFirstBanner`, `testAFirstPostThatDoesNotAlertIsAddedQuietly`, `testTheRecordCarriesTheAlertAndTheBannerCounts` |
| NOTIFY-20 | WHILE a forwarded child of a package+group is still active THE phone SHALL NOT forward that group's summary; WHEN a child of a group arrives after the group's summary was forwarded THE phone SHALL send `notify.remove` for that summary before forwarding the child; THE group's state SHALL hold the set of forwarded child ids, so an update of a known child changes nothing, a child's removal drops only its own id, and a group whose set empties SHALL be forgotten; WHEN the phone forwards a grouped notification THE post SHALL carry `group`, 64 bits of SHA-256 over the package and the Android group key (never the key), and THE Mac SHALL thread the banner under `<phone id>.<group>`; a group that loses its last forwarded child SHALL forget it, and a summary SHALL be forwarded only while its group has no forwarded child; a removal SHALL be announced for every id the phone forwarded, even one its forwarded-id map has since forgotten, and SHALL be silent only for an id the phone deliberately kept on the phone (a skipped summary); WHEN a summary is forwarded while its group has no forwarded child and the notification asks for `GROUP_ALERT_CHILDREN` THE phone SHALL mark it `alert:false`, and a child that supersedes a summary SHALL keep its own alert decision. | e2e `notify-actions` `[NOTIFY-20]` (child, skipped summary, lone summary, summary removed before its child; the group thread; no key in a log); K1 `NotifyGroupMachineTest` (every transition), `NotifyWireParityTest` (the group hash reaches the Mac), `NotifyEventsTest` (`group hashes are 64 bits over the package and the key`, `every post carries alert and only a grouped one carries group`); K2 `NotifyMacTests.testAThreadedPostUsesThePhoneAndTheGroup`, `testAGroupedPostIsThreadedUnderItsGroup` |
| NOTIFY-21 | WHEN a post's channel is ranked LOW or MIN THE phone SHALL mark every post of it `alert:false` and SHALL still forward it, because Android lists it in the shade's silent section; DEFAULT and above SHALL keep the rules of NOTIFY-19, and WHEN the ranking cannot be read THE phone SHALL keep those rules and log `importance=unknown`; the log SHALL carry the importance as a number or `unknown`, never a channel name. | K1 `NotifyImportanceTest` (LOW, MIN, DEFAULT, HIGH, an unreadable ranking), `NotifyEventsTest` (`importance can only make a post quieter`); review of `PdNotificationListener.importanceOf` |
| NOTIFY-22 | WHEN the Mac attaches a forwarded notification it SHALL compose one PNG with alpha: with a picture, the picture SHALL be scaled to fill a square and clipped to a circle, with the sending app's icon as a circular badge at the bottom-right, 40 % of the side, inset 4.5 % from the right and bottom edges and with no ring behind it; without a picture, the app's icon alone SHALL be the attachment, filling the square and clipped to a rounded square with a corner of 22 % of the side, never a circle; the icon SHALL be the same rendering the Deck and Dock use — the cached adaptive layers, else the flat icon, through `PhoneAppIcon` — SHALL never be enlarged past the 1.3× upscale bound, and the cache size class whose source avoids that SHALL be chosen; the side SHALL be min(512 px, the picture's long side) with a picture and 256 px for the icon alone; WHEN no icon is cached, or its source is too small, THE picture SHALL stay a circle without a badge and, with no picture, there SHALL be no attachment; WHEN the composed PNG would exceed 200 KiB or the Mac's image caps, or the picture cannot be decoded, THE Mac SHALL attach the phone's picture uncomposed, as today, and record the fallback; a muted package SHALL stay dropped before any of this; the banner's own icon SHALL stay PocketDeck's; and the record line SHALL carry only the shape, the side, the badge's yes/no, the size class and a closed-set fallback reason. | K2 `NotifyComposerTests` (`testACirclePictureHasTransparentCorners`, `testTheBadgeCentreCarriesTheIconsCentreColour`, `testThereIsNoRingAroundTheBadge`, `testTheIconAloneFillsTheSquareInsideItsCorners`, `testThePictureCoversTheSquareWithoutLetterboxing`, `testTheSideFollowsThePictureOrTheIconAlone`, `testANoisyPictureOverTheCapFallsBack`, `testNoCachedIconKeepsTheCircleWithoutABadge`, `testNoIconAndNoPictureAttachNothing`, `testAnIconBelowTheUpscaleBoundIsNotUsed`, `testAPostWithAPictureAndACachedIconRecordsTheComposition`, `testAPostWithNoPictureAndACachedIconHasAnAttachment`); e2e `notify` `[NOTIFY-22]` (a picture post composes a circle with a badge; an icon-only post is the icon alone) |
| NOTIFY-23 | WHEN a notification's text extra is a styled CharSequence (a `Spanned`: bold, a link, a colour) THE phone SHALL read the title, big title, text, big text and conversation title, and a MessagingStyle message's text and sender, with `getCharSequence(…)?.toString()` and forward the plain characters — never a null from `Bundle.getString` and never the spans. | K1 `NotifyStyledTextTest` (`a styled title and text arrive as plain text`, `a styled big title and big text arrive as plain text`, `a sub text or summary text is not the body`, `a styled conversation title arrives as plain text`); review of `PdNotificationListener.textExtra` |

Priority note: NOTIFY-1, 2, 3, 4, 6, 7, 8, 9 and 14 are P1 — the gate, an honest banner, a click that goes where it says, and no text in a log. Codes, pictures, live rows and the mute list are P2.

## Case matrix

Every Android notification shape the listener can meet, what Android does with it, what the
Mac does today (the code that decides it), what it should do, and the check that proves the
row. **Status is the current state**: `OK` matches Android and is proved, `GAP` is missing
behaviour, `BUG` is behaviour that is demonstrably wrong. A row fixed after `68ce259` is `OK`
and names the requirement and the check that prove it.

Plain posts and updates:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 1 | A plain post (new key, alerting) | One banner, one alert | `NotifyCenter.post` → `deliver` adds a request (`NotifyCenter.swift` `post`, `deliver`); thread = the phone's id | The same | OK | e2e `notify` `[NOTIFY-4]`, `[NOTIFY-5]` |
| 2 | An update in place (same key) with changed content, alerting | Replaces the notification; alerts again (the app can silence it) | Every post is delivered; re-adding a delivered identifier alerts again (`UNUserNotificationCenter.h`, `addNotificationRequest`: "will alert for the new notification request") | Present an alerting update as Android would; a quiet one must not present (rows 3–4) | OK | e2e `notify-actions` `[NOTIFY-19]` (the alerting first post), K2 `NotifyMacTests` |
| 3 | An update with `FLAG_ONLY_ALERT_ONCE` | Replaces silently | The Mac cannot tell; the post carries no alert decision, so it banners again (`PdNotificationListener.kt` `onNotificationPosted`; `NotifyCenter.swift` `deliver`) | The phone marks it `alert:false`; the Mac replaces the delivered banner without presenting it (`.passive`) | OK | e2e `notify-actions` `[NOTIFY-19]`; K1 `NotifyEventsTest` (the decision); K2 `NotifyMacTests` |
| 4 | An update whose title and text did not change | As the app says; a repeated identical notification is another post | Banners again (same path) | The phone marks it `alert:false` (hashes kept in memory, never the text); the Mac replaces it quietly | OK | e2e `notify-actions` `[NOTIFY-19]`; K1 `NotifyEventsTest` (hash and decision) |
| 5 | A silent or low-importance channel (MIN, LOW) | No sound; MIN sits in the shade's silent section | The channel's importance is read from the system's ranking (`PdNotificationListener.importanceOf`) and both are listed quietly | The same: listed, never presented | OK | K1 `NotifyImportanceTest`, `NotifyEventsTest` (`importance can only make a post quieter`) |
| 6 | A determinate progress update whose text changes each tick, from an app that did not set `FLAG_ONLY_ALERT_ONCE` | Alerts each time the app says so; progress apps normally set the flag | The bar is read (`EXTRA_PROGRESS_MAX`/`EXTRA_PROGRESS_INDETERMINATE`): a tick that only moves it while the title stays is `alert:false`, and the post that drops the bar alerts | Quiet once the bar only moves | OK | K1 `NotifyProgressTickTest`, `NotifyEventsTest` (`a bar that only moves is not news`); e2e `notify-actions` `[NOTIFY-19]` (2 presented, 4 quiet) |
| 7 | An indeterminate progress update whose text did not change | One notification, no fraction | Banners each tick | Quiet: the content did not change (row 4's rule) | OK | e2e `notify-actions` `[NOTIFY-19]` (a five-tick bar: 2 presented, 4 quiet); K1 `NotifyProgressTickTest` (the tick and the drop), `NotifyEventsTest` (`a bar that only moves is not news`) |

Ongoing:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 8 | An ongoing notification the system did not promote | Persistent, not dismissable, service chrome | Skipped (`PdNotificationListener.kt` `onNotificationPosted`, `NotifyEvents.promoted`) | Keep skipping (the spec's open question names why) | OK | K1 `NotifyLiveTest` ("only a promoted ongoing notification is live") |
| 9 | A foreground-service notification | Persistent chrome | Skipped with row 8 | Keep skipping | OK | K1 `NotifyLiveTest` |

Groups:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 10 | A group child (no summary seen) | One notification in the group | Each child is its own banner; thread = the phone's id, so every notification of the phone shares one thread (`NotifyCenter.swift` `deliver`) | Thread per group (`<phoneId>.<group hash>`) | OK | e2e `notify-actions` `[NOTIFY-20]`; K2 `NotifyMacTests` (the thread) |
| 11 | A group summary while its children are forwarded | Replaces the group's children in the shade with one summary | The summary is forwarded as its own post: a second banner on top of the children (`PdNotificationListener.kt` `onNotificationPosted` has no group rule; the wire had no group) | The phone does not forward a summary while a forwarded child of that group is active; when a child arrives after a forwarded summary it sends `notify.remove` for the summary first | OK | e2e `notify-actions` `[NOTIFY-20]`; K1 `NotifyGroupMachineTest` (every transition) |
| 12 | A group summary with no forwarded children | One summary | Banners as a plain post | Banner it, threaded under its group | OK | e2e `notify-actions` `[NOTIFY-20]`; K1 `NotifyGroupMachineTest` |
| 13 | `GROUP_ALERT_SUMMARY` / `GROUP_ALERT_CHILDREN` | Chooses which of the summary and the children alert | Read: a lone summary under `GROUP_ALERT_CHILDREN` is `alert:false` (`NotifyEvents.summaryAlerts`), children keep their own decision | One alerting post per parent group, as the app asked | OK | K1 `NotifyGroupAlertTest` (children-only, summary-only, the child that supersedes it), `NotifyEventsTest` |

Conversations, media, calls:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 14 | A conversation (MessagingStyle) with a new message on the same key | Replaces the conversation notification, one alert | Reads the last `EXTRA_MESSAGES` text and `EXTRA_CONVERSATION_TITLE`/sender when the plain fields are empty (`PdNotificationListener.lastMessage`); nothing is dropped as contentless | The same, with the same caps | OK | K1 `NotifyConversationTest` (the last message, the sender, plain fields winning, an empty conversation) |
| 15 | A conversation with an inline reply | A RemoteInput in the shade | The reply action is advertised and `notify.action` fills the RemoteInput (`NotifyEvents.selectActions`; `PdNotificationListener.kt` `deliverAction`) | The same | OK | e2e `notify-actions` `[NOTIFY-9]`; K1 `NotifyEventsTest` |
| 16 | Media (MediaStyle) | A media notification with artwork and transport buttons | Skipped: a post carrying `EXTRA_MEDIA_SESSION` logs `notify skip media id=…` (`PdNotificationListener`), and its removal is not announced | The media surface owns the session; no banner | OK | K1 `NotifyMediaSkipTest`; e2e `notify-media` (Now Playing still works with no banner) |
| 17 | Call style, incoming | Full-screen intent, ringing, ongoing | Skipped: ongoing and not promoted (`PdNotificationListener.kt` `onNotificationPosted`) | A call reaches the Mac, or the person is told calls are not forwarded | GAP | MISSING |
| 18 | Call style, ongoing | Persistent call chrome | Skipped (row 8) | Row 17's decision covers it | GAP | MISSING |

Actions, priority, silence:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 19 | A notification with actions | Up to three buttons, a reply field | Up to three advertised; the phone's own index (`NotifyEvents.selectActions`) | The same | OK | e2e `notify-actions` `[NOTIFY-9]`; K1 `NotifyEventsTest` |
| 20 | Heads-up vs low priority | Importance decides the heads-up | Read now: LOW and MIN are `alert:false`, DEFAULT/HIGH follow NOTIFY-19 | LOW never presents; DEFAULT/HIGH present as today | OK | K1 `NotifyImportanceTest` (LOW, DEFAULT, HIGH) |
| 21 | The Mac's Do Not Disturb / Focus | — | The banners are the system's; `sound = nil` and nothing sets a level above `.active` (`NotifyCenter.swift` `deliver`) | Focus silences them as it silences any notification | OK | NOTIFY-18; review |
| 22 | The phone's own Do Not Disturb | The notification is posted or suppressed on the phone | Forwarding neither reads nor changes it | Leave it alone | OK | review (NOTIFY-18) |

Removal:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 23 | The app removes its own notification | Gone from the shade | `notify.remove` drops the banner and its attachment (`PdNotificationListener.kt` `onNotificationRemoved`; `NotifyCenter.swift` `remove`) | The same | OK | e2e `notify` `[NOTIFY-6]`, `notify-media` |
| 24 | The person removes it on the phone | Gone | Same path (the listener reports every removal) | The same | OK | e2e `notify-actions` `[NOTIFY-6]` |
| 25 | It times out | Gone | Same path | The same | OK | e2e `notify` `[NOTIFY-6]` |
| 26 | The person clears the Mac banner | — | `notify.dismiss`; refused for ongoing and no-clear (`NotifyCenter.swift` `performDismiss`; `PdNotificationListener.kt` `deliverDismiss`) | The same | OK | e2e `notify-actions` `[NOTIFY-6]`; K1 `NotifyEventsTest` |

Android 16 Live Updates (promoted ongoing) — **audit only this round: no change to live rows or their surface**:

| # | Shape | Android | Mac today | Mac should | Status | Proof |
|---|---|---|---|---|---|---|
| 27 | A Live Update with progress (download, navigation, delivery) | Promoted; a live chip with a bar | First post banners; later posts update the in-panel row at most once a second (`NotifyLiveStore`; `NotifyCenter.swift` `post`) | The same | OK | e2e `notify-media`; K2 `NotifyLiveMacTests` |
| 28 | A Live Update timer or stopwatch | Promoted; a running clock | A live row with a chronometer (`NotifyLiveItem.chrono`, `countDown`) | The same | OK | e2e `notify-media`; K2 `NotifyLiveMacTests` |
| 29 | A Live Update for a match (chip and progress) | Promoted; a chip | The chip and the bar (`NotifyLive.chip`) | The same | OK | e2e `notify-media`; K2 `NotifyLiveMacTests` |
| 30 | A Live Update with neither progress, chip nor chronometer (a flashlight) | Promoted; the row is the control | A row whose label is only the app (`NotifyEvents.liveWire` returns an empty object; the menu row shows the app) | Say the activity is live and what it is | GAP | MISSING |
| 31 | A Live Update ends | Promoted flag cleared, or removed | `notify.remove` ends the row (`NotifyLiveStore.end`) | The same | OK | e2e `notify-media` |
| 32 | A Live Update updates faster than once a second | The system draws each change | Coalesced to one per second, newest wins (`NotifyLiveThrottle`; `NotifyLiveStore`) | The same | OK | e2e `notify-media` (measured gaps); K1 `NotifyLiveTest` |
| 33 | An ongoing notification while the system did not promote it | Service chrome | Skipped (row 8) | Keep skipping | OK | K1 `NotifyLiveTest` |

### Still open

Rows 17, 18 and 30 are the only `GAP` rows left, and all three are out of scope for this round:

- **Rows 17 and 18 — a call reaches the Mac.** The treatment of an incoming `CallStyle` notification
  (a banner with the call's actions, or a sentence that calls are not forwarded) is a product
  decision; it moves to the product vision's Calls item.
- **Row 30 — a Live Update with no progress, chip or clock says what it is.** Live Update surface
  work sits at the bottom of the backlog.

## States and events

The gate is one machine on each side (`NotifyGate` on the phone: `OFF`, `FORWARDING`, `NO_ACCESS`; the Mac's stored switch is the input). A banner's life is the system's, with the Mac's own additions (the 300 ms hold, the live store, the copy's 90 s clock). Nothing here is inferred from timing except those two clocks.

| State (phone gate) | Event | Result |
|---|---|---|
| OFF | `notify.enable on` with the listener granted | FORWARDING; `notify.state {on:true}` |
| OFF | `notify.enable on` without the grant | one shell-UID grant attempt; granted → FORWARDING; else NO_ACCESS with `reason:"no_access"` |
| NO_ACCESS | the person grants in the system screen | FORWARDING; `notify.state {on:true}`; posts resume |
| FORWARDING | `notify.enable off` | OFF; no reason; nothing forwarded |
| FORWARDING | the person revokes the grant | NO_ACCESS on the next gate read; nothing forwarded |
| any | `the session closes` | OFF locally (the Mac's stored switch is unchanged) |

| State (banner) | Event | Result |
|---|---|---|
| Held (≤ 300 ms) | `notify.image` for the id | the picture rides on the same banner |
| Held | the hold ends | delivered to Notification Center |
| Held | `notify.post` with the same id | the new post takes the wait, keeps the earlier post's delivery state and alerts if either did (NOTIFY-19) |
| Delivered | `notify.image` for the id | dropped as late; the banner stays |
| Delivered | `notify.post` with the same id | the banner is replaced; a quiet update (`alert:false`, NOTIFY-19) is replaced without being presented |
| (no banner) | `notify.post` with a new id | a banner is presented; `alert:false` never hides a notification the Mac has not shown |
| Delivered | `notify.remove` / a disconnect | the banner and its attachment go |
| Delivered | the person clears it | `notify.dismiss` (refused for an ongoing one) |
| Delivered | a click | the click target's one plan (NOTIFY-8) |
| Delivered | a button, a reply or Copy code | `notify.action`, or the code on the pasteboard |
| Delivered | a live update for its id | the in-place update (≤ 1 a second) |

The phone's group machine (NOTIFY-20) is one state per package+group key; a notification
without a group never enters it:

| State (group) | Event | Result |
|---|---|---|
| EMPTY | a child is posted | CHILDREN {the child's id}; the child is forwarded |
| EMPTY | the summary is posted | SUMMARY; the summary is forwarded |
| CHILDREN | a child is posted | CHILDREN plus its id (an update of a known child adds nothing); the post is forwarded |
| CHILDREN | the summary is posted | CHILDREN; the summary stays on the phone |
| CHILDREN | a forwarded child leaves | CHILDREN minus its id, or EMPTY when no child is left (the group is forgotten) |
| SUMMARY | a child is posted | CHILDREN; `notify.remove` for the summary first, then the child |
| SUMMARY | a new summary is posted | SUMMARY (the newest id); forwarded |
| SUMMARY | the summary leaves | EMPTY |
| EMPTY or SUMMARY | a child leaves | ignored (that id is not in the set) |
| CHILDREN or EMPTY | the summary leaves | ignored (it was never forwarded) |

Ignored events, stated so nobody builds them: a post while sharing is off, a muted package's post, a group summary while its children are forwarded, an action on an unknown id, a reply text on a non-reply action, a dismiss for an ongoing notification, a picture for an id the Mac never posted, a live end for an id it does not hold. A second `notify.enable on` is not ignored: while forwarding it asks the phone for its active set again (NOTIFY-1).

## Phone count and connection

| Situation | Notifications shows |
|---|---|
| 0 phones | No switch to turn on and no banner: the phone page does not exist. Forwarding is a per-phone store, so it starts off when the first phone is paired. |
| 1 phone | That phone's banners, titled with its name (its nickname first), its mute list and its click target. |
| 2+ phones | Each phone has its own switch, click target and mute set; only the phone **in use** has a live session, so only its notifications arrive. Banners are grouped by the phone's id — by `<phone id>.<group>` for a notification with a group — and titled with its name, and a phone's state is cleared when its session ends. |
| Connecting / offline | Nothing is forwarded (there is no session); the panel keeps no stale rows and no banner claims to be live. |
| Connected | Forwarding as the switch says; every state shown comes from the phone's own `notify.state`, `notify.post`, `notify.remove` and `notify.snapshot`. |
| Key rejected (Pair again) | No session: nothing is forwarded; the Deck's banner carries Pair again. |
| Missing listener grant | "Allow notification access on the phone." under the Mac's switch; "Notification access is off" with Allow on the phone; a later grant starts forwarding (NOTIFY-2). |
| Phone that can't do the feature | A phone that never reports notifications simply sends none; the LIVE section is absent, and nothing is disabled that could work. |
| macOS notifications denied | One line under the phone's Notifications, "Notifications are turned off for PocketDeck in System Settings.", with Open System Settings and Check Again (NOTIFY-17). |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no search field of its own (the muted-apps list's search is SET-DEV-20's) |
| CONV-MAC-02 | applies: the banners are the system's; no key of ⌘W/⌘M/⌘Q/⌘,/⌘H is taken for forwarding |
| CONV-MAC-03 | applies: a banner is dismissed by the system's own gesture and Esc; Return runs the default response; the muted list's Esc is SET-DEV-21's |
| CONV-MAC-04 | applies: the reply field a banner carries is the system's own text input; the mute search is a standard field |
| CONV-MAC-05 | n/a: nothing zoomable |
| CONV-MAC-06 | applies: no shortcut is added; the switches are in Settings' page and the only other entry is the app's own banner response |
| CONV-MAC-07 | n/a: no shortcut is reused |
| CONV-MAC-10 | n/a: not the status item's panel (the LIVE row is drawn inside it — panel.md) |
| CONV-MAC-11 | applies: one banner per notification id and one live row per id (NOTIFY-5, NOTIFY-12); a replaced post never doubles |
| CONV-MAC-12 | n/a: banners are the system's windows and are placed by it |
| CONV-MAC-13 | n/a: no menu item and no full-screen command |
| CONV-MAC-14 | n/a: no app-drawn content to resize |
| CONV-MAC-15 | n/a: a banner is not a window a person closes to quit |
| CONV-MAC-16 | applies: the reply field's copy and paste are the system's own; no drop target is added by this surface |
| CONV-MAC-20 | applies: the phone page's rows and the panel's LIVE row render in light and dark with the accent and Increase Contrast; the banner is the system's; the composed attachment reads no appearance, so it is one image in both (NOTIFY-22) |
| CONV-MAC-21 | applies: every switch, the click target's picker and the mute rows carry labels (SET-DEV-19); a LIVE row reads its app, progress and clock as one element |
| CONV-MAC-22 | applies: the LIVE row's bar and clock are the only motion and are information, not decoration; Reduce Motion does not stop a countdown |
| CONV-MAC-23 | applies: NOTIFY-17 (a missing grant is a sentence on both ends), NOTIFY-12 (the progress is a bar *and* text) |
| CONV-MAC-24 | applies: the Mac asks for notification permission the first time it posts (NOTIFY-4) and the phone's listener is asked for when the Mac's switch turns on (NOTIFY-2); the person's Focus silences banners (NOTIFY-18). applies: a denied macOS permission puts the one line and its two controls under the phone's Notifications (NOTIFY-17) |
| CONV-MAC-25 | applies: the settings rows use the native hover/pressed states and a disabled picker is dimmed neutral (SET-DEV-10) |
| CONV-MAC-26 | applies: the page's one inset and rhythm are settings.md's; a helper sentence ("Allow notification access on the phone.") sits under its switch |
| CONV-AND-01 | n/a: forwarding carries no phone navigation |
| CONV-AND-02 | applies: the phone's attention item and its own connection notification follow the system theme; the connection notification is dismissable and names what it does (the phone app's surface) |
| CONV-AND-03 | applies: NOTIFY-2 — the listener grant is asked for in context (the Mac's switch), one attempt, and its denial disables only forwarding with the sentence on both ends |
| CONV-AND-04 | applies: forwarding reads notifications and changes no phone setting; the phone's Do Not Disturb is never altered by this surface (NOTIFY-18), and the phone stays locked |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+; per phone switch, target and mute set) |
| CONV-PD-02 | applies: the table above (connecting, connected, offline, key rejected, the missing grant, the denied macOS permission) |
| CONV-PD-03 | applies: NOTIFY-6 and NOTIFY-12 (a banner's state follows `notify.post`/`notify.remove`/the live update, never a local guess), NOTIFY-9 (no answer is invented) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value |
| CONV-PD-05 | applies: NOTIFY-14, NOTIFY-22 |
| CONV-PD-06 | applies: a banner is posted within the hold (≤ 300 ms) and a live row updates at most once a second; forwarding does no polling of its own |
| CONV-PD-07 | applies: "Share notifications and Now Playing", "When I click a notification", "Open on this Mac"/"Open on the phone"/"Do nothing", "Muted apps", "Copy code", "LIVE" are one name each across the page, the panel and the docs (SET-DEV-09–11, PANEL-15) |
| CONV-PD-08 | applies: the gate's truth table, the banner's life and the live store are the tables above |
| CONV-PD-09 | applies: NOTIFY-2 ("Allow notification access on the phone."), NOTIFY-7 (the picker's values are its labels), NOTIFY-13 (the count in the row) |

## Assumptions

- The phone runs API 34+ and Android 16's promotion rules apply only there; a `NotificationListenerService` in PocketDeck is granted at shell UID when the Mac's switch turns on (design/notify.md).
- The Mac's banners are `UNUserNotificationCenter` notifications: the system draws them, owns their Focus behaviour, and puts the action titles in a category keyed by the notification's shape.
- A notification's buttons are the phone's own; an advertised action always has a PendingIntent, and the phone can run it after the Mac asks.
- The phone's ids are the listener's own and are not reused across sessions; the Mac's request id is derived from the phone id and the notification id.
- The phone's Do Not Disturb and ringer are the phone's; forwarding neither reads nor changes them.

## Non-goals

- Now Playing, media control, artwork and the media volume: the media surface and panel.md (`PANEL-14`).
- A notification history, a notification centre of the app's own, or a banner that stays after the phone's notification is gone.
- Replying with anything but the system's own text field, or attaching something to a reply.
- Forwarding a notification while the phone's screen is off/locked *as a condition*: the listener reports what the system posts, whatever the screen is doing.
- A per-app sound, importance or channel setting on the Mac (only the mute).
- Any third-party service: nothing leaves the two devices.

## Open questions

- [NEEDS CLARIFICATION] The phone's `notify.state {on:false, reason:"no_access"}` is also what a phone answers while its own master switch is off; the Mac shows the same sentence for both. Recommended: leave one sentence ("Allow notification access on the phone.") — the phone's own home names the real cause, and the Mac must not guess.
- [NEEDS CLARIFICATION] A banner for an ongoing notification the system did not promote is never forwarded (service chrome is skipped). Recommended: keep it, and name it in the doc: a phone that has not promoted a notification cannot be represented in a banner that the person can clear.
- [NEEDS CLARIFICATION] The Mac's banner is silent (`sound = nil`) while the phone's notification probably made a sound. Recommended: keep it silent (a second sound for one message is worse), and say so in UX.md's copy rules if the person agrees.
- [NEEDS CLARIFICATION] With two phones, two banners of the same id cannot collide in practice (the id map is per phone) but the Mac's `requestIds` is keyed by the phone's id and the notification's id together. Recommended: keep the composed key and add a K2 test for two phones posting the same notification id.
