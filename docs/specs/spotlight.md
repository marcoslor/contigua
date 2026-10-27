# Spotlight

Prefix: `SPOT`. Owner docs: docs/UX.md (Deck search), docs/design/intents.md (continuations). Last reviewed: 2026-10-27, against build 0.1.0.

## Purpose

A person searches Spotlight for an app that lives on their phone: the Mac keeps one CoreSpotlight entry per app per phone, titled "App (Phone)", and choosing it opens that app's window (connecting first if needed). The index is a system service the app does not own, so this surface also says what the app does when the daemon refuses it.

## User stories

| ID | Priority | Story |
|---|---|---|
| SPOT-S1 | P1 | As a person with a paired phone, I want to find its apps from Spotlight so that I can open one without opening the Deck first. |
| SPOT-S2 | P2 | As a person whose Spotlight stays empty, I want one sentence naming what to fix so that I am not left with a silent feature. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| SPOT-1 | WHEN the phone's app list arrives (first load, reconnect, rename) THE Mac SHALL index that phone's apps into CoreSpotlight under the phone's domain, and SHALL then confirm with a CSSearchQuery that this batch's own items are findable, within 30 s. | K2 `SpotlightTests.testAVerifiedIndexIsAnnouncedWithTheCounts`; e2e `spotlight` `[SPOT-1]` |
| SPOT-2 | IF the index call fails OR the confirming query finds none of the batch THEN the Mac SHALL log one error line per launch naming the step that can fix it, and SHALL NOT repeat that line for later attempts in the same launch. | K2 `SpotlightIndexStateTests.testRefusalSpeaksOncePerLaunch`, `SpotlightIndexStateTests.testAnEmptyAnswerIsTheFailure`, `SpotlightTests.testARefusedIndexCallAsksNothingAndIsUnavailable`; e2e `spotlight` `[SPOT-2]` |
| SPOT-3 | WHEN the person chooses a Spotlight result for a phone app THE Mac SHALL treat it as that phone's app and open its window, ignoring identifiers of another profile. | K2 `SpotlightTests.testContinuationRequestFromUserActivity`, `testParseIdentifier`; e2e `intents` (open-app runs the Spotlight open path) |
| SPOT-4 | WHEN the phone is renamed or its app list changes THE Mac SHALL replace that phone's whole domain, so no old title survives; WHEN the phone is forgotten THE Mac SHALL delete its domain. | K2 `SpotlightTests.testRenamingThePhoneReplacesItsItemsWithTheNewTitles`, `testForgetRemovesTheDomain`, `testIndexesOncePerAppList` |

## States and events

| State | `submitted(n)` | `refused` | `queried(found)` |
|---|---|---|---|
| `idle` | → `verifying`, verify | → `unavailable(announced)`, one hint | ignored |
| `verifying` | → `verifying` (new batch), verify | → `unavailable(announced)`, one hint | matching batch, found > 0 → `verified`; found = 0 → `unavailable(announced)`; other batch → ignored |
| `verified` | → `verifying`, verify | → `unavailable(announced)`, one hint | ignored |
| `unavailable(announced)` | → `verifying`, verify | ignored | ignored |

`submitted(0)` asks nothing back: an app list with no apps has nothing to prove.

## Phone count and connection

0 phones: nothing is indexed, so nothing is verified. 1 phone: its domain is indexed and verified. 2+ phones: one domain and one verification per device id, so a second phone's list cannot settle the first's. Offline: the cached app list of a remembered phone is indexed on rename; a forgotten phone's domain is deleted at once.

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no search field of ours; Spotlight's field is the system's. |
| CONV-MAC-02 | n/a: no window or menu of its own. |
| CONV-MAC-03 | n/a: Esc and Return belong to Spotlight's own UI. |
| CONV-MAC-04 | n/a: no text field. |
| CONV-MAC-05 | n/a: no zoomable content. |
| CONV-MAC-06 | n/a: no shortcut; nothing to show in a menu. |
| CONV-MAC-07 | n/a: reuses no shortcut. |
| CONV-MAC-10 | n/a: no menu-bar interaction. |
| CONV-MAC-11 | applies: SPOT-3 opens the one window per app per phone instead of a second one. |
| CONV-MAC-12 | n/a: no window of its own. |
| CONV-MAC-13 | n/a: no menus. |
| CONV-MAC-14 | n/a: no layout of ours. |
| CONV-MAC-15 | n/a: no window lifecycle. |
| CONV-MAC-16 | n/a: no drag, drop, copy or Services. |
| CONV-MAC-20 | n/a: the result row is drawn by Spotlight, not by this app. |
| CONV-MAC-21 | n/a: no control of ours. |
| CONV-MAC-22 | n/a: no animation or glass. |
| CONV-MAC-23 | n/a: our only text is the entry's title, drawn by the system. |
| CONV-MAC-24 | n/a: indexing asks for no permission and does not touch Focus or notifications. |
| CONV-MAC-25 | n/a: no custom control. |
| CONV-MAC-26 | n/a: no surface of ours to lay out. |
| CONV-AND-01 | n/a: no phone-side UI for this surface. |
| CONV-AND-02 | n/a: the phone posts nothing for this surface. |
| CONV-AND-03 | n/a: the app list arrives with the session; no runtime permission is asked for it. |
| CONV-AND-04 | applies: the phone only sends its app list; indexing changes no setting on it. |
| CONV-PD-01 | applies: SPOT-1, one domain and one verification per phone (0, 1 and 2+). |
| CONV-PD-02 | applies: SPOT-1 runs on every connect and on a rename, so a reconnect re-verifies; a phone that reports no apps indexes none and is not an error. |
| CONV-PD-03 | n/a: nothing here waits on the phone's answer. |
| CONV-PD-04 | n/a: no live control. |
| CONV-PD-05 | applies: SPOT-2 and the item builder log counts, states, the device id and the package name — never an app label, the phone's name or an item's title. |
| CONV-PD-06 | n/a: no interactive surface; the one system call is bounded (30 s query, off the main actor). |
| CONV-PD-07 | applies: the entry reads "App (Phone)", the one name used elsewhere (SET-DEV-06). |
| CONV-PD-08 | applies: the states/events table above, SPOT-1 and SPOT-2. |
| CONV-PD-09 | applies: SPOT-2's line names the step that fixes it, and an entry's title says which app on which phone. |

## Non-goals

- Indexing anything but the phone's app list (no notifications, media, files).
- Querying the index for the person; Spotlight's UI does that.
- Working around a system refusal (removing other copies of the app, resetting the index): the app says what to do and stops at one line per launch.

## Open questions

- [NEEDS CLARIFICATION] Should a test build carry its own bundle id so the release id's LaunchServices claimant list stays short? See `.agent/spotlight-fix/ask.md`; today every checkout registers a copy under `dev.pocketdeck.mac`, and macOS 27 refuses CoreSpotlight for an ad-hoc build once that list is long.
