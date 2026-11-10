# Working in this repo

- `docs/PROTOCOL.md` is the contract: if code and doc disagree, the doc wins (or propose a doc change). Architecture rules: `docs/ARCHITECTURE.md`.
- Work on your own branch in a worktree off `main`, inside the directories your task names. **Never push, never merge to `main`** (the reviewer merges). Never `git commit -a`; add paths explicitly. No TEMP/debug leftovers, commented-out code or version tags (`v48q`) in comments.
- **Specs before code.** Behaviour lives in `docs/specs/<surface>.md` as an EARS table with stable IDs, answering every line of `docs/specs/CONVENTIONS.md`. A behaviour change updates its spec in the same commit, and the proving check carries the ID (`ok "[DECK-12] …"`). Unspecified behaviour and unproved requirements both block a merge. Don't invent a missing requirement: mark it `[NEEDS CLARIFICATION]` and ask. Spec review: `.agents/skills/spec-review/SKILL.md`.
- **State machines.** Anything with modes, phases, a hold, a retry, a handshake or a lifecycle is one explicit machine: a closed state set, the accepted events, and one pure `(state, event) -> (state, actions)` with an exhaustive `when`/`switch` (no swallowing `else`/`default`). Effects run from the returned actions. No parallel booleans, no state inferred from timing, timestamps, nullables or another flag. Test every transition, including ignored events, and log each one as `<machine>: <from> --<event>--> <to>`.
- **Every change and review asks:** is there an implicit state machine here (make it explicit, pinning today's behaviour with tests first)? And does the option raise UX, DX and AX together (what the person sees; what a human can read and test; what an agent can find and verify alone)? If one rises only at another's cost, find a better option or ask. A refactor keeps behaviour unless a spec row changes in the same commit.
- Never name competitor or closed-source products anywhere in the repo; describe techniques generically.
- Dependencies: Android = Shizuku, androidx core/activity/lifecycle, Compose + Material 3 (BOM), `play-services-code-scanner`; macOS = system frameworks only; tools = Python 3.9 stdlib + ffmpeg/dns-sd. Ask before adding one.
- UI follows `docs/UX.md` (flows, copy, shortcuts) and `docs/DESIGN.md` (visuals).
- Toolchain: `JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=$HOME/Library/Android/sdk` (platform 36, build-tools 36.0.0). Swift 6.4 / macOS 27 SDK, deployment target macOS 26.
- Don't bump Android `versionCode` on a branch, and don't tick ROADMAP boxes; the reviewer does both.
- **The lead delegates; it does not code.** Whoever briefs, reviews and merges gives every code change to a subagent, small ones included: a one-file fix found in review, a regression the person reports, a copy or constant change. The brief names the bug, the test that must fail first and the files. The lead keeps the review, the merge and the install.
- Bugs and work found outside your task go in `ISSUES.md` (rules at its top), not into an unasked fix.

## Product promises (never trade these away)

- **The phone stays locked.** Never unlock it, dismiss the keyguard, or change lock or screen-timeout settings. Waking the screen is fine.
- **Never remove or disable anything on the phone:** no uninstalling, disabling apps or clearing data.
- **Sharing is opt-in.** Notifications, Now Playing, the camera, Finder files, AI-agent control and any new feature that reads or sends personal data are off until a person switches them on.
- **Privacy:** never log or save notification text, media metadata or artwork, file names, paths or contents, pasteboard contents, key material, nonces, exporters or secrets. Ids, counts, sizes, states, durations, error codes and hash prefixes only.
- **LAN and end to end:** mutual TLS with pinned keys (`docs/design/e2ee.md`); nothing passes a third party unencrypted.
- **No backward compatibility during the alpha:** the phone and Mac ship together, so protocol changes may rename or remove fields freely, with no older-peer modes. Still document every change in PROTOCOL.md and bump the version when it breaks the other side.
- **Blocked features stay off `main`:** a feature needing something we don't have (a Developer ID, SIP off) lives on `feature/<name>`. Today: `feature/camera`, `feature/direct-link` (main keeps only `docs/design/paths.md`).

## Swift and macOS

- Read the matching vendored skill first (`.agents/skills/`: `swiftui-expert-skill`, `swift-concurrency`). Never install skills or packages at run time.
- Tools-version 5.10 (Swift 5 mode) on a 6.x compiler: write code that would pass Swift 6 strict concurrency, but don't switch the mode. `scripts/check-rules.sh` enforces the rest (`@Observable`, no new GCD, no `AnyView`/`GeometryReader`, no force-try).
- **Menus:** only SwiftUI `commands`. Never insert AppKit items into a SwiftUI menu (they get dropped). Key-window checkmarks are edited in `MenuMarks.swift`; system leftovers are removed only in `MenuCleanup.swift`. A disabled menu item eats its key, so phone keys in stream windows (⌘F) are window-scoped.
- **Layout:** size from the proposal at layout time. Never debounce or store a width in state.
- **Status item** panel is AppKit-owned (`NSStatusItem` + panel) because `MenuBarExtra(.window)` didn't toggle (CONV-MAC-10).
- **One window per thing:** open-or-raise through one function (CONV-MAC-11).
- **Stream picture:** the encoder pads sizes; show only the content rect the phone reports. Prove picture bugs on the emulator with decoded frames, not only the fake phone.
- **Instruments:** only against your own `--profile` app through `.agent/heavy.sh`, never `--all-processes`, never the person's installed app.

## Done means every surface

The commonest defect is a change that works only on the tested path. Your report says how each entry was handled ("n/a" counts; silence doesn't):
- **Entry points:** menus and shortcuts, the menu-bar panel, the Deck and its popover, the stream bar, Shortcuts/App Intents, MCP tools, the debug-input route, auto-open at launch, all through one shared function.
- **Apps:** Mac, phone, File Provider and Share extensions. A wire change touches PROTOCOL.md, phone, Mac and the fake phone together.
- **Phones and states:** 0/1/2+ phones; connecting, connected, offline, screen off or locked, unsupported (disabled with a reason).
- **Reverse states:** every way in has a visible way out. A one-way door is a bug.
- **Docs:** rewrite whatever the change makes inaccurate (UX.md, PROTOCOL.md, specs, design docs); don't append.

## Testing rules

- **A reported bug gets a test first:** a check that fails on the current code and passes with the fix, both runs logged, in the cheapest tier that sees it.
- **Visual-only fixes** are proved with `before-*.png` / `after-*.png` captures of the real render in `.agent/<task>/` (plus frames when motion matters), not new UI tests.
- **QA belongs to the reviewer** (or an Opus QA agent at medium effort or higher). Changing a product default, an NFR limit or a check's strictness, or adding a suppression, needs the reviewer's explicit sign-off, named in the report.
- **NFRs are tested like features:** limits live only in `docs/NFR.md` + `macos/scripts/nfr-limits.json`. Run `macos/scripts/nfr.sh` before review on any UI or protocol change. Protocol loops are tested against a peer that keeps the connection open.
- **Drive the real control:** proving a button, menu, shortcut or gesture goes through the person's path (click, menu item, key event). Debug verbs are for setup and reading state.
- Never weaken, skip or rewrite a check to pass; argue it in your report.
- **Tiers, cheapest first:**
  0. `scripts/check-rules.sh` (paste its summary line);
  1. K1 `cd android && ./gradlew -q :app:assembleDebug :app:testDebugUnitTest`, K2 `cd macos && swift build && swift test`;
  2. `cd macos && PD_E2E_PORT=<port> PD_E2E_PROFILE=<profile> ./scripts/check-e2e.sh <check>`, one check at a time (`all` is a rare final gate);
  3. a macOS VM (`macos/scripts/vm-e2e.sh`) for real drawing and system registration;
  4. the emulator (`tools/emulator/`);
  5. the real phone and Mac, by the reviewer only.
- On a developer's Mac, e2e runs quiet: never `PD_E2E_VISIBLE=1` or the real pointer. Never run a PocketDeck Mac binary without `--profile <name>`, which would rewrite the person's profile.

## Goal-loop protocol (every delegated task)

A task is a **GOAL** plus numbered **CHECKS**. Loop: take the smallest increment toward a failing check, then run the checks (all before a commit), then log one entry in `.agent/<task-id>/progress.md` (the change, PASS/FAIL with the key output line, the next step). Commit one finished step at a time.

Exit when all checks pass (then do a cleanup pass and rerun them), when the iteration cap hits, or when the same check fails 3 times for the same reason (stuck: report the evidence and your hypotheses). The final reply is the last progress entry plus a summary. A "done" claim without check output is rejected.

### Ask the architect

Blocked? Ask with your harness's question tool (what you tried, the evidence, 2–3 options and your pick), then continue in the same turn. Don't end the turn to ask, and don't poll files. Ask when:
- a check fails twice for one reason;
- something external blocks a check;
- a fix would break ARCHITECTURE.md or a product promise;
- you need files outside your scope;
- or you've spent 2 iterations on tooling instead of the product.

### Shared machine rules

Other agents run on this machine at the same time.
- Use only the ports, serial, profile and directory your task names (else `mktemp -d` and a port in 47100–47999).
- Never `pkill` by pattern; kill only your own PIDs.
- Never end your turn with your own background job running.
- Log progress at least every 20 minutes.
- On exit, stop everything you started and unregister any extension you registered.
- Edit scripts that may be running atomically (`.new`, `bash -n`, `mv`).
- Machine limits (memory, heavy-step lock, serials, boot budgets) come from your brief, not this file.
