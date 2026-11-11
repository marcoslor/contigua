# PocketDeck

`docs/PROTOCOL.md` (the wire) and `docs/ARCHITECTURE.md` are the contract. If code and doc disagree, the doc wins, or you propose a doc change.

## Never trade away
- The phone stays locked: never unlock it, dismiss the keyguard, or change lock or screen-timeout settings.
- Never remove, disable or clear anything on the phone.
- Anything that reads or sends personal data is off until a person switches it on.
- Logs carry ids, counts, sizes, states, durations and error codes only: never text, names, paths, contents or key material.
- Mutual TLS with pinned keys; nothing leaves the LAN unencrypted.

## Practices
- Behaviour lives in `docs/specs/<surface>.md` rows with stable IDs. A behaviour change updates its row in the same commit, and its test names the ID. A missing requirement is marked `[NEEDS CLARIFICATION]` and asked, not invented.
- Modes, retries, handshakes and lifecycles are one explicit state machine: a pure `(state, event) -> (state, actions)` with exhaustive cases and every transition tested.
- A bug gets a failing test first. Never weaken, skip or rewrite a check to make it pass.
- A change rewrites the docs it makes inaccurate.
- No new dependency without asking. No backward compatibility during the alpha, but every wire change is documented.
- Never name competitor or closed-source products.
- Work found outside your task becomes an issue, not an unasked fix.
- Changes reach `main` through a branch and a review.

## Read before you touch
- Mac code: `macos/AGENTS.md`. Any UI: `docs/UX.md` and `docs/DESIGN.md`.
- Tests, tiers, commands and what "done" covers: `docs/CONTRIBUTING.md`.
