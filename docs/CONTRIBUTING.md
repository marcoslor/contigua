# Contributing: tests, tiers and what "done" covers

The rules every change follows are in [AGENTS.md](../AGENTS.md). This page is the detail behind them.

## Toolchain and dependencies

- Android: `JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=$HOME/Library/Android/sdk` (platform 36, build-tools 36.0.0).
- Mac: Swift 6.4 with the macOS 27 SDK, deployment target macOS 26.
- Allowed dependencies: Android = Shizuku, androidx core/activity/lifecycle, Compose + Material 3 (BOM), `play-services-code-scanner`; macOS = system frameworks only; tools = Python 3.9 standard library plus ffmpeg and dns-sd.

## Test tiers, cheapest first

A check runs in the cheapest tier that can see the defect.

| Tier | What | Command |
| --- | --- | --- |
| 0 | Rules a script can see | `scripts/check-rules.sh --base $(git merge-base HEAD main)` |
| 1 | K1, Android unit tests | `cd android && ./gradlew -q :app:assembleDebug :app:testDebugUnitTest` |
| 1 | K2, Mac unit tests | `cd macos && swift build && swift test` |
| 2 | Mac e2e against the fake phone | `cd macos && PD_E2E_PORT=<port> PD_E2E_PROFILE=<profile> ./scripts/check-e2e.sh <check>` |
| 3 | A macOS VM, for real drawing and system registration | `macos/scripts/vm-e2e.sh <check>` |
| 4 | The emulator | `tools/emulator/` |
| 5 | The real phone and Mac | the reviewer only |

E2E runs one check at a time; `all` is a rare final gate. On a developer's Mac, e2e runs quiet: never `PD_E2E_VISIBLE=1` or the real pointer.

## Test rules

- **A reported bug gets a test first:** a check that fails on the current code and passes with the fix, with both runs in the report.
- **Visual-only fixes** are proved with before and after captures of the real render, in dark and light, not with new UI tests.
- **Drive the real control:** proving a button, menu, shortcut or gesture goes through the person's path (click, menu item, key event). Debug verbs are for setup and reading state.
- **NFRs are tested like features:** limits live only in `docs/NFR.md` and `macos/scripts/nfr-limits.json`. Run `macos/scripts/nfr.sh` on any UI or protocol change. Protocol loops are tested against a peer that keeps the connection open.
- **The reviewer signs off** any change to a product default, an NFR limit or a check's strictness, and any new suppression. A check you believe is wrong changes in its own commit, with the measured reason.
- A test that waits has its own bound (a test timeout or a bounded await).
- The fake phone has no real encoder and skips the shell server, so picture and server-path bugs need the emulator.

## Done means every surface

The commonest defect is a change that works only on the tested path. A report says how each entry was handled; "n/a" counts, silence doesn't.

- **Entry points:** menus and shortcuts, the menu-bar panel, the Deck and its popover, the stream bar, Shortcuts/App Intents, MCP tools, the debug-input route and auto-open at launch, all through one shared function.
- **Apps:** Mac, phone, File Provider and Share extensions. A wire change touches PROTOCOL.md, the phone, the Mac and the fake phone together.
- **Phones and states:** 0, 1 and 2+ phones; connecting, connected, offline, screen off or locked, unsupported (disabled with a reason).
- **Reverse states:** every way in has a visible way out.
- **Docs:** rewrite whatever the change makes inaccurate; don't append.

## Process

- A task is an issue: its goal plus numbered checks. Work in small steps, one commit per finished step, checks green before each commit.
- The same check failing three times for one reason means stop and report the evidence and your hypotheses.
- A report leads with the outcome, then the check output. A "done" claim without check output is rejected.
- The reviewer bumps the Android `versionCode`, ticks ROADMAP boxes and merges. A merge closes its issue with `Fixes #N`.
- Spec changes go through `.agents/skills/spec-review/SKILL.md`.
- A feature that needs something the project doesn't have (a Developer ID, SIP off) lives on `feature/<name>`, off `main`. Today: `feature/camera`, `feature/direct-link`.
