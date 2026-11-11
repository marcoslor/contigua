# Vendored skills

These are copied unmodified from their upstream repositories, at fixed commits, after review. Agents read them from here and never install skills at run time. To update one, re-clone it into a scratch directory, read the diff (especially any scripts), then copy it over and update this table.

| Skill | Upstream | Commit | License | Reviewed |
|---|---|---|---|---|
| swiftui-expert-skill | https://github.com/AvdLee/SwiftUI-Agent-Skill (skills/swiftui-expert-skill) | 204dba7 | MIT | 10-22: the scripts only run `xctrace` locally; there are no network calls |
| swift-concurrency | https://github.com/AvdLee/Swift-Concurrency-Agent-Skill (skills/swift-concurrency) | d577081 | MIT | 10-22: docs only; its course links are adverts and can be ignored |

`spec-review` is Contigua's own.
