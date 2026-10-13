# Working in this repo

- Read `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md` before changing anything. The protocol doc is the contract; if code and doc disagree, the doc wins (or propose a doc change in your report).
- Stay inside the directories your task names. Other agents work in parallel in sibling directories.
- **Do not `git commit`, `git add`, branch, or push.** The reviewer commits after review.
- No debug/TEMP leftovers, no commented-out code, no "v48q"-style version tags in comments. Comments explain *why*, briefly.
- Never name competitor or closed-source products in code, comments, docs or commit messages; describe techniques generically.
- Keep dependencies minimal: Android = Shizuku, androidx core/activity/lifecycle, Jetpack Compose + Material 3 (via the Compose BOM), Google code scanner (`play-services-code-scanner`) for QR; macOS = system frameworks only; tools = Python 3.9 stdlib + ffmpeg/dns-sd CLIs.
- UI: follow docs/UX.md (flows/copy) and docs/DESIGN.md (visual system). macOS UI is SwiftUI + Liquid Glass; Android UI is Compose + Material 3.
- Toolchain: `JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=$HOME/Library/Android/sdk` (platform 36, build-tools 36.0.0). Swift 6.4 / macOS 27 SDK, deployment target macOS 26 (Liquid Glass).
- Phone rig (only when `timeout 20 adb devices` lists it): Samsung SM-S936B, Android 16, Shizuku running. Always prefix adb with `timeout 20`.

## Goal-loop protocol (every delegated task follows this)

Tasks are written as a **GOAL** plus a numbered list of **CHECKS** (commands with an
expected result). Work in loops until every check passes:

1. **Plan** the smallest next increment toward a failing check.
2. **Build** it.
3. **Verify**: run *all* checks (not just the one you worked on). Read the real output — never assume.
4. **Log** one entry in `.agent/<task-id>/progress.md`: iteration number, what changed, each check PASS/FAIL with the key output line, and the next step.
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
- The fix would break a rule in `docs/ARCHITECTURE.md` or a product promise (locked phone,
  battery, no competitor names, LAN/E2E security), or would change docs to justify a trade-off.
- You need to edit files outside your assigned scope.
- You have spent 2 iterations on test tooling instead of the product.

### Shared machine rules

Other devs run on the same Mac at the same time.
- Use only the ports, emulator serial and work directory your task names. Without one, use
  `mktemp -d` and a random port in 47100–47999.
- Never `pkill` by a generic pattern. Kill only the PIDs you started.
- The physical phone is shared. Hold `.agent/device.lock` while installing or streaming
  (`mkdir .agent/device.lock`, remove it when done; if it exists, ask).
- Never end your turn while your own background job is still running. Wait for it, or stop
  it and report.
- Append to your progress log at least every 20 minutes of work, even mid-iteration.
- On exit, stop every process you started (emulators, fakephone, the app, watchers).
