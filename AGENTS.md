# Working in this repo

- Read `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md` before changing anything. The protocol doc is the contract; if code and doc disagree, the doc wins (or propose a doc change in your report).
- Stay inside the directories your task names. Other agents work in parallel in sibling directories.
- Work on your own branch (a git worktree off `main`) and commit one finished step at a time, with a normal English message. **Never push and never merge to `main`**: the reviewer merges after review. Never `git commit -a`; add paths explicitly.
- No debug/TEMP leftovers, no commented-out code, no "v48q"-style version tags in comments. Comments explain *why*, briefly.
- **State machines for stateful behaviour.** Whenever a feature has modes, phases, a hold, a retry, a handshake or a lifecycle, model it as one explicit state machine: a closed set of states (enum/sealed type), the events it accepts, and one pure transition function `(state, event) -> (new state, actions)` with an exhaustive `when`/`switch` (no `else`/`default` that swallows new cases). Side effects run from the returned actions, never inside the transition. No parallel booleans that together mean a state, and no state inferred from timing or another flag. Unit-test every transition, including the events that must be ignored in a state, and log each transition (`<machine>: <from> --<event>--> <to>`) so a field log shows the path.
- Never name competitor or closed-source products in code, comments, docs or commit messages; describe techniques generically.
- Keep dependencies minimal: Android = Shizuku, androidx core/activity/lifecycle, Jetpack Compose + Material 3 (via the Compose BOM), Google code scanner (`play-services-code-scanner`) for QR; macOS = system frameworks only; tools = Python 3.9 stdlib + ffmpeg/dns-sd CLIs.
- UI: follow docs/UX.md (flows/copy) and docs/DESIGN.md (visual system). macOS UI is SwiftUI + Liquid Glass; Android UI is Compose + Material 3.
- Toolchain: `JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=$HOME/Library/Android/sdk` (platform 36, build-tools 36.0.0). Swift 6.4 / macOS 27 SDK, deployment target macOS 26 (Liquid Glass).
- Don't change Android `versionCode` on a feature branch; it is bumped when a build is installed on a device.
- Don't tick ROADMAP boxes; the reviewer does, once a feature is verified.

## Product promises (never trade these away)

- **The phone stays locked.** Never unlock it, dismiss the keyguard, or change lock or screen-timeout settings. Waking the screen is allowed; the lock screen stays.
- **Never remove or disable things on the phone:** don't uninstall PocketDeck or any other app, don't disable apps, don't clear data.
- **Sharing is opt-in.** Notifications, Now Playing, the camera, Finder files and AI-agent control are off by default and need a person's switch. A new feature that reads or sends personal data follows the same rule.
- **Privacy in logs, tests and commits:** never log or save notification text, media titles/artists/albums/artwork, file names, paths or file contents, pasteboard contents, key material, nonces, exporters or secrets. Log ids, counts, sizes, states, durations, error codes and hash prefixes only.
- **LAN and end to end:** the session is mutual TLS with pinned keys (docs/design/e2ee.md); nothing goes through a third party unencrypted.
- **No backward compatibility during the alpha:** nothing is released and the phone and Mac apps ship together, so a protocol change may rename, remove or require fields freely — no "older peer" modes, fallbacks or tests. Every change is still documented in docs/PROTOCOL.md (and the protocol version bumped when a change breaks the other side). This rule ends when there are real users and the project leaves alpha.
- **A feature blocked on something we don't have** (a paid Apple Developer ID, an account, special hardware) does not land on `main`. It lives on its own branch (`feature/<name>`), rebased now and then, and becomes a GitHub issue plus a PR when the repo is published. Today: camera sharing (`feature/camera`, needs a Developer ID for the camera extension).

## Testing rules

**A reported bug gets a test first.** Before fixing anything a person reported (or a reviewer found), add the check that reproduces it: it must fail on the current code and pass with the fix, and both runs go in your progress log. Put it in the cheapest tier that can see the bug. No fix merges without its check.

**Non-functional requirements are tested like features.** "Works" is not enough; the checks also pin how fast, how it looks and what it must not do:
- **Time limits** for every step a person waits on (open a file, first video frame, connect, a preview). A protocol loop must return as soon as its terminal reply arrives: test it against a fake peer that keeps the connection open.
- **No side effects in read-only flows:** browsing, previewing, opening and listing send zero writes to the phone (the fake phone counts them).
- **Modes block what they freeze:** while a mode shows a frozen or non-live picture (Live Text, screen off, disconnected, camera taken over), controls and shortcuts send zero input to the phone.
- **No stale picture:** when frames stop, the window shows a state ("screen off", "disconnected") within `docs/NFR.md`'s `stale_picture_ms` instead of the last frame as if it were live.
- **Honest settings:** a setting the build or the phone can't support is disabled with a sentence saying why; an error message only suggests a step that can actually fix it.
- **Layout fits** the smallest supported screen (1280×800): every control is visible or inside something that scrolls.
- **Contrast:** controls drawn over video stay readable over white, black and busy frames (at least 3:1 against what's behind them).
- **Icons and images** are never upscaled from a smaller source; visual output is compared to reference images with a tolerance.
- Limits live in one place (`docs/NFR.md` and `macos/scripts/nfr-limits.json`), not as numbers scattered through scripts.
- Run `macos/scripts/nfr.sh` before asking for review on any UI or protocol change: it runs the NFR K2 tests and the host e2e check `nfr` (time limits, zero writes in read-only flows, zero input in frozen modes, no stale picture, honest settings, layout, contrast, icons, and the real-control family).

**Test tiers, cheapest first:**
1. Unit tests: K1 (`cd android && ./gradlew -q :app:assembleDebug :app:testDebugUnitTest`) and K2 (`cd macos && swift build && swift test`). Pure logic goes behind a seam so it is testable here.
2. Mac e2e against fakephone: `cd macos && PD_E2E_PORT=<port> PD_E2E_PROFILE=<profile> ./scripts/check-e2e.sh <check>`, one check at a time. The full `all` suite is a rare final gate, not a habit.
3. A macOS VM (`macos/scripts/vm-e2e.sh <check>`) for anything that needs real macOS drawing or system registration: visible runs, Dock and Finder, File Provider, widgets, Control Center, system extensions, the camera. These never run on a developer's own Mac: registrations stick there and visible runs take the person's screen.
4. The Android emulator (`tools/emulator/`) for phone-side behaviour the JVM can't show.
5. A person's real phone and Mac: the last pass, done by the reviewer, never by an agent.

**Drive the real control.** An e2e step that proves a button, menu item, shortcut or gesture works must go through the same path a person uses (a click at the control's location through the window's event handling, the menu item, the key event) — a debug verb that calls the action directly proves the action, not the control. Debug verbs are fine for setup and for reading state.

**Check hygiene:** never weaken, skip or rewrite a check to make it pass; if you think a check is wrong, say why in your report. Mac e2e on a developer's machine runs quiet: never `PD_E2E_VISIBLE=1` and never the real pointer outside a VM. Never run a PocketDeck Mac binary without `--profile <name>` (it would rewrite the person's own profile).

## Goal-loop protocol (every delegated task follows this)

Tasks are written as a **GOAL** plus a numbered list of **CHECKS** (commands with an
expected result). Work in loops until every check passes:

1. **Plan** the smallest next increment toward a failing check.
2. **Build** it.
3. **Verify**: run the checks you touched, and all of them before a commit. Read the real output — never assume.
4. **Log** one entry in `.agent/<task-id>/progress.md`: what changed, each check PASS/FAIL with the key output line, and the next step.
5. If a check failed, diagnose the root cause from the output and loop. Do not weaken, skip or rewrite a check to make it pass. If you think a check is wrong, log why and report it instead.

Exit when all checks pass (then do one cleanup pass: remove leftovers, re-run all checks), or when the iteration cap is hit, or when the same check fails 3 iterations in a row for the same reason (**stuck**: stop and report the evidence and your hypotheses). The final reply must be the last progress entry plus a short summary. "Done" claims without check output are rejected in review.

### Ask the architect (direct line)

When you are blocked, don't loop and don't guess. Write the question to
`.agent/<task-id>/ask.md` (what you tried, the evidence, 2–3 options and the one you
recommend), then wait for the answer with a single blocking command:

```sh
until [ -f .agent/<task-id>/answer.md ]; do sleep 5; done; cat .agent/<task-id>/answer.md
```

Re-run that command if it times out. When the answer arrives, delete both files and continue.
Ask when any of these happens:
- A check fails **twice** for the same reason.
- An external dependency (device offline, network, another dev's broken build) blocks a check.
- The fix would break a rule in `docs/ARCHITECTURE.md` or a product promise above, or would change docs to justify a trade-off.
- You need to edit files outside your assigned scope.
- You have spent 2 iterations on test tooling instead of the product.

### Shared machine rules

Other agents may run on the same machine at the same time.
- Use only the ports, emulator serial, profile and work directory your task names. Without one, use
  `mktemp -d` and a random port in 47100–47999.
- Never `pkill` by a generic pattern. Kill only the PIDs you started.
- Never end your turn while your own background job is still running. Wait for it, or stop
  it and report.
- Append to your progress log at least every 20 minutes of work, even mid-iteration.
- On exit, stop every process you started (emulators, VMs, fakephone, the app, watchers) and
  unregister any extension your build registered.
- Edit a shell script another process may be running atomically: write `<script>.new`,
  `bash -n` it, then `mv` it over the original.
- Machine-specific limits (memory, a shared heavy-step lock, device serials, boot budgets)
  come from your brief and the machine's own notes, not from this file.
