# nfr-checks progress

- Worktree `~/dev/pd-wt/nfr-checks` from `main` (2f13fb0), branch `epic/nfr-checks`, profile `nfr1`, port 47980.
- Budget: emulator 0, VM 0.
- Step 1 done: docs/NFR.md + macos/scripts/nfr-limits.json (one loader each side); scattered 10-20 limits now read the file (files fetch, stale picture, contrast, settings/layout). Measured host values: connect 120 ms, first frame 150 ms, app list 25 ms; budgets 1500/1500/1500 ms. K2 909/0.
- Step 2 done: shared tools. HangingPeerTests (each terminal bridge frame decodes on that frame; every bridge request answered while the client holds its socket); NFRSupport (off-screen render, WCAG contrast, reachability walk) with BarContrastTests on it; fake phone `writes`/`input` counters + e2e `fake_counter`. K2 913/0.
