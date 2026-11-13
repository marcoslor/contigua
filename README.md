# Contigua

Mac-style continuity for Android phones. Contigua uses
[Shizuku](https://shizuku.rikka.app/) and modern Android APIs to put your
phone's apps on your Mac, each in its own window, while the phone stays locked
in your pocket.

> **Alpha: expect rough edges.**
>
> - **Android:** the app will be on the [Releases](https://github.com/marcoslor/contigua/releases) page.
> - **Mac:** there is no public build yet. A Mac app that others can download
>   needs an Apple Developer certificate (US$99 a year). Until then, build the Mac app
>   yourself and sign it with a free local certificate. Two commands, in
>   [docs/TRY-IT.md](docs/TRY-IT.md).
>
> Want a ready-made Mac download sooner?
> [Buy me a coffee](https://buymeacoffee.com/marcoslor): it goes toward the certificate.

![Phone apps and the phone's own screen as Mac windows](docs/images/desktop.jpg)

## What you can do

| | |
|---|---|
| ✅ | 🪟 Open any phone app in its own Mac window, and resize it to any shape |
| ✅ | 📱 See and use your phone's whole screen on the Mac |
| ✅ | ⌨️ Type, click and scroll in phone apps with your Mac's keyboard and trackpad |
| ✅ | 🔊 Hear the phone's sound on the Mac |
| ✅ | 📋 Copy on one, paste on the other: text and pictures |
| ✅ | 🔗 Send links and shares between the Mac and the phone |
| ✅ | 📂 Drag files onto the phone, or install Android apps from the Mac |
| ✅ | 🗂️ Browse the phone's files in Finder |
| ✅ | 🚀 Start phone apps from the Dock, Launchpad or Spotlight |
| ✅ | 🌙 Mac Focus mode silences the phone too |
| ✅ | 🔍 Select and copy text inside any phone app window |
| ✅ | 🤖 Let an AI agent on your Mac use the phone (off unless you turn it on) |
| 🧪 | 🔔 Phone notifications on the Mac, with reply |
| 🧪 | 🎵 Phone music in the Mac's Now Playing |
| 🚧 | 🎛️ Phone controls in Control Center |
| 🚧 | 📷 Use the phone as the Mac's camera |

✅ works · 🧪 built, still being tested on real devices · 🚧 in progress

🔒 Always: the phone stays locked, nothing leaves your home network (encrypted
end to end, keys made at pairing), no accounts, no tracking. Details and known
limits: [docs/FEATURES.md](docs/FEATURES.md).

## Requirements

- Android 11 or later, with [Shizuku](https://shizuku.rikka.app/) running. No
  root.
- macOS 26 or later, with Xcode.
- The Mac and the phone on the same network.

Tested on Android 16 (an emulator and a Samsung phone) and macOS 26 and later.

## Get started

[docs/TRY-IT.md](docs/TRY-IT.md) walks through installing the phone app, building and signing
the Mac app, and pairing.

## Docs

| | |
|---|---|
| [docs/TRY-IT.md](docs/TRY-IT.md) | build, sign, pair, troubleshoot |
| [docs/FEATURES.md](docs/FEATURES.md) | every feature and known limit |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the phone and the Mac work |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | the wire protocol |
| [docs/ROADMAP.md](docs/ROADMAP.md) | status and what is next |
| [docs/design/mcp.md](docs/design/mcp.md) | connecting an AI agent |
| [SECURITY.md](SECURITY.md) · [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) | reporting a vulnerability, threat model |
| [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | contributing; the code is written with AI agents under human review ([AGENTS.md](AGENTS.md)) |

## Support

Contigua is built by one person. If it is useful to you, you can
[buy me a coffee](https://buymeacoffee.com/marcoslor).

## License

Source-available under the [Functional Source License 1.1, Apache 2.0 future
license](LICENSE) (FSL-1.1-ALv2): use, change and share it for anything except
a competing product or service. Each release becomes Apache 2.0 two years
after it is published. Dependencies keep their own licenses.
