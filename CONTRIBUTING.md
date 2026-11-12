# Contributing to Contigua

Contigua has one maintainer. Small, focused changes get reviewed fastest.

## How to propose a change

1. Open an issue, or pick an open one (`good first issue` and `help wanted` are good starts). Say what you plan to do before you write much code.
2. Branch from `main`, keep the branch short, and open a pull request into `main`.
3. The pull request template asks for the linked issue (`Fixes #N`), the spec rows touched, the tests, and the "every surface" checklist. A claim of "done" without check output is not reviewed.
4. The maintainer reviews and merges. Contributors do not merge.

Found something unrelated while working? Open an issue instead of folding the fix in.

## House rules

- **Behaviour lives in spec rows.** Each behaviour has a row with a stable ID in `docs/specs/`, and its test names the ID. Why: a reviewer can check the test against a written requirement. If a requirement is missing, ask; do not invent one.
- **A bug gets a failing test first.** Show it failing, then passing with the fix. Why: it proves the test sees the bug. Never weaken or skip a check to get green.
- **A change rewrites the docs it makes inaccurate.** Rewrite, do not append. Why: `docs/PROTOCOL.md` and `docs/ARCHITECTURE.md` are the contract, and stale docs mislead.
- **Lifecycles are explicit state machines.** Modes, retries and handshakes are a pure `(state, event) -> (state, actions)` with every transition tested. Why: implicit states hide bugs.
- **Never trade away** (full list in [AGENTS.md](AGENTS.md)): the phone stays locked; nothing on the phone is removed or disabled; personal data is off until a person turns it on; logs carry no text, names, paths or keys; connections use mutual TLS with pinned keys. Why: these are the promises users rely on.
- **No new dependency without asking.** Open an issue first. Why: the allowed list is short on purpose.
- **Never name competitor or closed-source products** in code, docs or issues. Why: it keeps the project neutral.

## AI-assisted contributions

Welcome, under the same rules. You are the author and responsible for every line: you must understand it, have run the checks, and be able to answer review questions. Unreviewed generated output will be closed.

## License and sign-off

Contigua is under FSL-1.1-ALv2 (see [LICENSE](LICENSE)). Contributions are accepted under the same license.

Every commit needs a Developer Certificate of Origin sign-off (<https://developercertificate.org>), which says you wrote it or have the right to submit it under this license. Add it with:

```
git commit -s
```

That appends `Signed-off-by: Your Name <you@example.com>`. Pull requests with unsigned commits are not merged.

## Where the detail is

Test tiers, commands, toolchain, and the "done means every surface" checklist are in [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). Security problems go through the private report page, not a public issue: <https://github.com/marcoslor/contigua/security/advisories/new>.
