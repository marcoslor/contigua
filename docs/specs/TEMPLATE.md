# <Surface name>

Prefix: `<PREFIX>`. Owner docs: <links to docs/design/*.md and docs/UX.md sections>. Last reviewed: <date>, against build <version>.

## Purpose

One paragraph: who uses this surface, for what, and where it sits among the other surfaces.

## User stories

| ID | Priority | Story |
|---|---|---|
| <PREFIX>-S1 | P1 | As a person with <context>, I want <goal> so that <benefit>. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| <PREFIX>-1 | WHEN the person presses ⌘F WHILE the <surface> is key, THE <surface> SHALL focus its search field and select its text. | e2e `deck` `[PREFIX-1]` |
| <PREFIX>-2 | IF the phone omits `<field>`, THEN THE <surface> SHALL disable <control> and show "<reason>". | K2 `…Tests.testOldPhone` |

## States and events

The state machine's table: states, events, and the transition for each pair, with ignored events marked as ignored.

## Phone count and connection

The surface with 0, 1 and 2+ phones, and while connecting, connected, offline and with an old phone (CONV-PD-01/02).

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: <PREFIX>-1 |
| CONV-MAC-02 | n/a: <reason> |
| … | (every line of CONVENTIONS.md) |

## Non-goals

What this surface deliberately does not do, so nobody builds it.

## Open questions

- [NEEDS CLARIFICATION] <question for the person>
