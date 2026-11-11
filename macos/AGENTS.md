# Mac code

- Read the matching vendored skill first (`.agents/skills/`: `swiftui-expert-skill`, `swift-concurrency`). Never install skills or packages at run time.
- Tools-version 5.10 (Swift 5 mode) on a 6.x compiler: write code that would pass Swift 6 strict concurrency, but don't switch the mode. `scripts/check-rules.sh` enforces the rest (`@Observable`, no new GCD, no `AnyView`/`GeometryReader`, no force-try).
- **Menus:** only SwiftUI `commands`. Never insert AppKit items into a SwiftUI menu (they get dropped). Key-window checkmarks are edited in `MenuMarks.swift`; system leftovers are removed only in `MenuCleanup.swift`. A disabled menu item eats its key, so phone keys in stream windows (⌘F) are window-scoped.
- **Layout:** size from the proposal at layout time. Never debounce or store a width in state.
- **Status item** panel is AppKit-owned (`NSStatusItem` + panel) because `MenuBarExtra(.window)` didn't toggle (CONV-MAC-10).
- **One window per thing:** open-or-raise through one function (CONV-MAC-11).
- **Stream picture:** the encoder pads sizes; show only the content rect the phone reports. Prove picture bugs on the emulator with decoded frames, not only the fake phone.
- **Callbacks from `Session.onVideoEvent`** run on the session queue. Hop to main before touching window or controller state.
- Never run a Contigua Mac binary without `--profile <name>`: it would rewrite the person's profile.
