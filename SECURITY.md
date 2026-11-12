# Security policy

Contigua runs Android apps in Mac windows. Part of it runs on the phone at
shell UID (2000) inside Shizuku. The Mac and the phone talk over mutual TLS 1.3
with keys pinned at pairing. An optional local MCP server lets an AI agent on
the Mac drive the phone. Security reports matter here.

## Report a vulnerability privately

Use GitHub's private advisory form for this repository:

1. Open the **Security** tab of this repository.
2. Choose **Report a vulnerability**.
3. Fill in the form.

Please do not open a public issue, pull request or discussion for a
vulnerability. Please do not post it anywhere public before a fix exists.

There is no email address for reports. The advisory form is the only channel.

## What to include

- What you found, and what an attacker gains by using it.
- The attacker's position: same LAN, a malicious app on the phone, another
  process on the Mac, an AI agent connected over MCP, or something else.
- Steps to reproduce, or a short proof of concept.
- The commit you tested (`git rev-parse HEAD`), the Android version and phone
  model, and the macOS version.
- Whether the Mac and the phone were paired, and how.

Do not include real personal data from a phone. Do not include private keys
from a device you do not own.

## In scope

- **Pairing**: the six-digit code flow, the QR flow, the Allow prompt, and the
  rules that refuse unpaired or unpinned peers (docs/PROTOCOL.md, "Pairing").
- **TLS and pins**: TLS 1.3 only, mutual authentication, certificate pinning,
  no resumption, no plaintext fallback, and how identities and pins are stored
  (docs/design/e2ee.md).
- **The MCP socket**: who can connect to it, the on/off gate, and what a
  connected agent can reach (docs/design/mcp.md).
- **The shell-UID server**: anything that lets a caller other than the paired
  Mac make it read, write, inject or install something it should not.
- **The File Provider and the other Mac extensions**: path handling, the local
  App Group socket, and what each extension can reach (docs/design/files.md).
- **Logging rules**: a log line that carries text, names, paths, contents or
  key material breaks the rule in AGENTS.md. Logs may carry ids, counts,
  sizes, states, durations and error codes only.

## Out of scope

- A phone or a Mac that is already compromised.
- Physical access to an unlocked phone or an unlocked Mac.
- Anything that needs root on the phone or on the Mac.
- Weaknesses in Android, macOS, Shizuku or other third-party software, unless
  Contigua makes them worse. Report those to their owners.
- Denial of service by someone who is on the same network and can already
  drop packets. Flooding bugs that bypass a documented limit are in scope.
- Reports that rely on the person tapping Allow on a pairing prompt whose code
  does not match the Mac's screen.

## Supported versions

Contigua is a pre-release alpha. There are no releases. Only the `main` branch
is supported. A fix lands on `main`. Nothing is backported.

## What to expect

This project has one maintainer. Reports are handled on a best-effort basis,
with no fixed response time. There is no bug bounty and no payment.

When a report is valid, the aim is to fix it on `main`, then publish the
advisory and credit you if you want to be credited. If you plan to publish
your own write-up, say so in the report and we will agree a date.
