# panelcc progress

- Step 1: panel spec rewritten for P2 Control Center modules + `task.front` pull machine. Commit: spec only.
- Step 2: `task.front` pull (PROTOCOL + phone Session + fake phone + Mac FrontAppMachine/controller) with stale-reply handling. K1 SessionTest 95 tests 0 failures; K2 FrontAppTests 6 + HandoffFlowTests 5 pass.
- Step 3: panel model/view/hosts rebuilt as P2 modules; header picker, Sound, 2×2 modules, live dismiss, handoff row, window buttons; Install APK leaves card; panel follows its content height; front watch begins/ends with card and Deck popover. K2 filtered `Panel|MenuBar|MenuModel|MenuDump` 93/0; panel suite 67/0. check-rules PASS.
- Step 4: Phone menu + handoff rename to "Open <App> on Mac" (fallback "Open Current App on Mac"; fresh None disabled with its sentence via MenuMarks' ⇧⌘C correction); panel-card.py and e2e controls/menus/media/deck order updated; PANEL-28 row asserted in menubar-shots. K2 menu+panel 71/0. e2e controls 33/1 (known PANEL-7 AX flake), menus 82/0, menubar-shots 14/0, mirror 67/0.
