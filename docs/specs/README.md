# Specs

Contigua keeps one living spec per surface. A spec says what the surface must do, so code, checks and reviews can be measured against it. It is updated in the same change as the behaviour it describes.

Keep specs lean: a requirements table, the state/event table and the conventions answers. No prose that narrates the code, no field lists, no plans. Types, tests and code already record the implementation; a spec records intent and its proof. "Done means every surface" in AGENTS.md is the companion checklist for every change.

- `CONVENTIONS.md` is the baseline every spec answers: the platform and product conventions no feature request will mention.
- `TEMPLATE.md` is the shape of a surface spec.
- `<surface>.md` holds one surface each: `deck.md`, `phone-mirror.md`, `app-windows.md`, `panel.md`, `menus.md`, `files.md`, `notifications.md`, `media.md`, `share-clipboard.md`, `pairing.md`, `settings.md`, `phone-app.md` and so on.

## Requirement IDs and traceability

Every requirement has a stable ID, `<SURFACE>-<n>` (for example `DECK-12`). IDs are never reused; a removed requirement keeps its ID, struck through, along with the reason.

Each requirement lists the checks that prove it:
- K1/K2 test names;
- e2e check names, whose `ok`/`bad` lines carry the ID in brackets, e.g. `ok "[DECK-12] ⌘F focuses the search field"`;
- emulator or VM proofs.

A requirement with no proof is marked **untested**, and that is a visible gap, not a silent one.

## The loop

1. **Specify.** Write the change into the surface spec as user stories with priorities (P1–P3) and EARS acceptance criteria:
   - `WHEN <event> [WHILE <state>] THE <surface> SHALL <response>`
   - `WHILE <state> …`
   - `IF <unwanted condition> THEN …`
   - plain `THE … SHALL …`

   Add the states and events, non-goals, and open questions. Answer every line of CONVENTIONS.md.
2. **Clarify.** Run the spec-review skill (`.agents/skills/spec-review/SKILL.md`). It marks every gap `[NEEDS CLARIFICATION]`. Only real product questions go to the person. Visual changes go through two to four real-render prototypes first.
3. **Plan.** The brief (`.agent/<task>/brief.md`) cites the requirement IDs it implements and the checks that will prove each one.
4. **Implement, test first.** A requirement is done when its check FAILs before the change and PASSes after.
5. **Converge.** Review compares the diff with the spec. Behaviour without a requirement, and a requirement without a proof, both block the merge.
