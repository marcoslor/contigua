# Contigua

Android apps in native Mac windows, over your home network, with the phone
staying locked.

> **Alpha. There are no downloads yet: build it yourself.** The Mac app has to
> be signed with your own local certificate, or macOS will not let it reach
> your phone over the network. The two-command setup is in
> [docs/TRY-IT.md](docs/TRY-IT.md). Expect rough edges.

![An Android app and the phone's own screen as Mac windows](docs/images/desktop.jpg)

| One Android app, one Mac window | The phone's own screen, mirrored |
|---|---|
| ![Spotify in a Mac window](docs/images/app-window.png) | ![The phone mirror](docs/images/phone-mirror.png) |

## What it does

- **One window per app.** Open any phone app in its own resizable Mac window;
  the app re-lays out to whatever shape you give it.
- **Real input.** Keyboard, clicks, scroll and trackpad gestures go to the app.
- **Audio, clipboard, links, files.** Phone audio plays on the Mac, the
  clipboard goes both ways, links and files move between them, and the phone's
  storage shows up in Finder.
- **The phone stays locked.** Apps run on separate virtual displays; Contigua
  never unlocks the phone.
- **Local only.** One encrypted connection over your network: mutual TLS 1.3
  with keys pinned at pairing. No accounts, no cloud, no analytics.
- **AI agents (optional, off by default).** A local MCP server lets an agent on
  your Mac see and use the phone.

Everything, including what is still unproven: [docs/FEATURES.md](docs/FEATURES.md).

## Requirements

- Android 11 or later, with [Shizuku](https://shizuku.rikka.app/) running. No
  root.
- macOS 26 or later, with Xcode.
- The Mac and the phone on the same network.

Tested on Android 16 (an emulator and a Samsung phone) and macOS 26 and later.

## Get started

[docs/TRY-IT.md](docs/TRY-IT.md) walks through building both apps, signing
the Mac app and pairing.

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
