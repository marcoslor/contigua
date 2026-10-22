---
name: spec-review
description: Review a PocketDeck surface spec (docs/specs/<surface>.md), or a change to one, before any brief or code. It checks the spec's completeness, clarity, testability and conventions coverage, and marks every gap [NEEDS CLARIFICATION]. Use when a spec is written or changed, before dispatching implementation, or when asked to "review the spec" or "clarify requirements".
---

# Spec review: unit tests for English

This review tests the written requirements, not the code. A checked item means the spec is good enough to build and test from. It does not mean the feature works.

## Inputs (read all of them)

- The spec under review, and its diff if it is a change.
- `docs/specs/CONVENTIONS.md`, `docs/specs/README.md`, `AGENTS.md`, `docs/NFR.md`.
- The surface's design docs that the spec links to, and docs/UX.md.
- The current behaviour, where it exists: the code paths the spec names, plus the e2e checks that carry its IDs (`grep -n "\[<PREFIX>-" macos/scripts/check-e2e.sh`).

## Checks

For each item, record pass, or a gap with the exact line and what is missing.

1. **Conventions.** Every line of CONVENTIONS.md has an answer: applies (with an ID), n/a (with a reason), deviates (with an approved reason), or `[NEEDS CLARIFICATION]`. A missing line is a gap. Pay attention to keys (⌘F, ⌘W, Esc, Return, Tab), toggle and single-instance behaviour, live resize, phone count (0/1/2+), connection states, old phones, and accessibility.
2. **Testable.** Every requirement is EARS-shaped and names an observable result a check could assert. Words like "works", "fast", "nice", "properly", "should handle" and "as expected" are gaps, unless a number or an observable outcome follows them.
3. **Proof.** Every requirement names its proof (a K1/K2 test, an e2e check with the ID, an emulator or VM proof), or is marked untested.
4. **Complete.** Every user story has at least one requirement. Every control in the surface has a requirement for each of its states: enabled, disabled with a reason, pending, refused, offline. Error, empty and first-run states are covered.
5. **Consistent.** There are no contradictions within the spec, with another surface's spec, with PROTOCOL.md or with AGENTS.md. Names follow CONV-PD-07.
6. **Stateful.** If the surface has modes, the spec has the state/event table, with ignored events named.
7. **Non-functional.** Performance, privacy, power and memory limits are stated, with numbers that link to NFR.md where they apply.
8. **Scope.** Non-goals are listed, and nothing in the requirements exceeds the stories.
9. **Assumptions.** Every assumption about the phone, Android version, macOS version or hardware is written down.

## Output

Edit the spec in place:
- Insert `[NEEDS CLARIFICATION] <question>` at each gap the spec's own sources can't settle.
- Fix any gap the sources do settle, and cite the source.

Then report in this order:
1. Questions for the person: only product decisions, at most five, each with a recommended answer.
2. The fixes you made.
3. The gaps that remain.
4. Pass or fail per check.

A spec with an open P1 gap is not ready for a brief.
