# App Intents, Siri and Spotlight actions (ROADMAP v0.2 #2)

What Siri, Shortcuts and the macOS 26 Spotlight actions list can run on the Deck, and
how a SwiftPM-built bundle gets the metadata they need.

## The intent surface

Five intents, all optional-phone (default: the connected phone, else the only paired one):

| intent | does |
|---|---|
| `OpenPhoneAppIntent` | opens one phone app in a window, connecting first if needed — the Spotlight click path |
| `OpenPhoneScreenIntent` | opens the whole phone window |
| `SendLinkToPhoneIntent` | sends a URL through the Mac → phone link path |
| `SendFileToPhoneIntent` | drops files into `Download/PocketDeck` |
| `PhoneBatteryIntent` | answers from the last `state`, never wakes the phone |

`PhoneApp` is an `AppEntity` with an `EntityStringQuery` over the app list Spotlight also
indexes, so Shortcuts can name an app instead of typing its package.

## Metadata: what the system reads

The system only sees an app's intents through `Contents/Resources/Metadata.appintents`,
written by `appintentsmetadataprocessor` (in
`$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/`). It is not produced by
compiling alone, and SwiftPM has no build phase for it. Xcode's `ExtractAppIntentsMetadata`
phase is two halves:

1. **Compile with const-values extraction.** swiftc gets `-emit-const-values` and
   `-const-gather-protocols-list <protocols.json>`; it writes one
   `<source>.swiftconstvalues` per file next to the object files (the list of those files is
   `<Module>.SwiftConstValuesFileList`). The protocol JSON is a toolchain constant: the
   `AppIntent`, `AppEntity`, `AppShortcutsProvider` … protocols whose conformances carry
   the statically visible metadata (titles, parameter names, phrases, defaults).
2. **Run the processor.** It parses those files and writes
   `Metadata.appintents/extract.actionsdata` (one JSON blob: every action, entity, query
   and auto-shortcut) plus `version.json`.

The exact invocation the Xcode 27 phase used (read from `xcodebuild`'s log while building a
throwaway probe target):

```
appintentsmetadataprocessor --toolchain-dir <toolchain> --module-name PocketDeck \
  --sdk-root <sdk> --xcode-version <build> --platform-family macOS --deployment-target 26.0 \
  --bundle-identifier dev.pocketdeck.mac --output <app>/Contents/Resources \
  --target-triple arm64-apple-macos26.0 --binary-file <app>/Contents/MacOS/PocketDeck \
  --source-file-list <module>.SwiftFileList --swift-const-vals-list <list of *.swiftconstvalues> \
  --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization
```

Both list arguments are newline-separated file paths — pass the `.swiftconstvalues` files
themselves, not a JSON array. The processor exits 0 with "Extracted no relevant App Intents
symbols, skipping writing output" when none of the module's files conform, so a plain build
stays green.

### How the bundle gets it (`scripts/bundle.sh`)

`bundle.sh` passes `-Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list
-Xswiftc scripts/appintents-protocols.json` to `swift build -c release`, then runs the
processor against the `Release` intermediate folder before codesigning. SwiftPM applies
`-Xswiftc` to every Swift target it compiles, dependencies included, so const-values files
for NIO/ASN.1 are written too; the processor is handed only PocketDeck's own (they carry the
module's mangled names). If the toolchain has no `appintentsmetadataprocessor`,
`bundle.sh` warns and builds without metadata rather than failing.

The probe (a throwaway Xcode app with one `AppIntent` + `AppShortcutsProvider`, and later a
temporary `ProbeIntent` inside this app) showed `extract.actionsdata` listing the intent by
identifier and mangled type name, so the route is the same for SwiftPM bundles.

## What can be checked without Shortcuts

- **In the bundle, no system service needed:** `extract.actionsdata` exists, is one JSON
  object, and lists every intent identifier, the entity, the query and the
  `AppShortcut` phrases. The `intents` e2e check does this on the built bundle (fast plist/
  JSON read; it never opens Shortcuts or Siri).
- **Behaviour, through the debug hook:** `--debug-intent "<name> <args>"` (PD_TEST_HOOKS
  only) runs the same `IntentsCore` entry the intents call and writes a JSON result line, so
  the e2e checks cover the real open/connect/drop paths without the Shortcuts UI.
- **Not checkable headlessly:** that Siri or Spotlight actually *offers* a phrase, and the
  Shortcuts editor's UI. Those belong to the system's own index (Siri/Shortcuts register the
  bundle by its LaunchServices record), so the VM check only looks for index evidence in
  `log show` and must not register the test copy on the host.
