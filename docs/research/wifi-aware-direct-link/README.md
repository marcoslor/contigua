# Mac ↔ Android direct link: Wi-Fi Aware research

Oct 28, 2026. Lab research, not shipped code. Kept here for anyone with the time and the hardware to push it further. Probe sources are in [`probes/`](probes/) (sources only, no binaries or run logs).

## Summary

Wi-Fi Aware is the only realistic direct Mac-to-Android radio link, and the Mac half is already built and working down to the chip. Only one "supported" answer is missing. On 10-28 the Mac's Wi-Fi Aware service answered a query with real numbers: 2.4 and 5 GHz, pairing encryption, 8 publishers, 8 subscribers, 16 data links.

- **Phone side:** the Galaxy S25+ supports Wi-Fi Aware with pairing (Aware 4.0), through Android's public API. No Shizuku needed.
- **Mac side:** Apple's public API answers "not supported". Its private toolkit underneath (`WiFiPeerToPeer`) has publish, subscribe, pairing and data-session classes.
- **Status:** lab-only. It needs SIP off and code-signing checks off (AMFI), so it can't ship to other people until Apple turns it on.

**Update, 10-28 22:13: discovery works.** The Mac advertised `_pdtest._tcp` through the private toolkit, and a test app on the S25+ found it through Android's public API. Two more blockers were found and passed:

- The service only lets Apple's own apps advertise. The boot setting `wifiaware_allowlist=0` turns that check off.
- Pairing fails because the service can't reach its keychain on macOS ("No keychain is available"), so the test advertises without pairing.

Side effect: while code signing is off (AMFI), every Java program on the Mac crashes at start, Gradle included. The phone app was built in a Linux container instead.

**Update, 10-28 22:58: an encrypted direct link comes up; macOS blocks app traffic on it.**

| Step | Result |
| --- | --- |
| Router baseline, phone → Mac | 5.5 ms median lag, 209 Mbit/s upload |
| Phone asks Mac for a link | Refused: Apple wants its own field in the request, which Android can't set |
| Mac asks phone for a link, open | Refused: Apple requires encryption |
| Mac asks phone, passphrase (SK-128) | Link established in about 3.5 s; both sides get addresses |
| TCP over the link | Blocked on the Mac by its network policy (NECP): replies dropped, outgoing connections unreachable |

The policy only lets traffic onto the Wi-Fi Aware interface through Apple's own Wi-Fi Aware network agent, and that agent refuses our flows. Options: reverse-engineer what the agent accepts, lift the interface restriction (root helper or kext, fragile), or stop here with radio and encryption interop proven.

## Ideation

Five routes are still open. Only Wi-Fi Aware keeps the Mac on the home network and needs no cable; it is also the only one that can't ship today.

| Route | How it works | What it needs | Ships to others? | Next test |
| --- | --- | --- | --- | --- |
| Wi-Fi Aware, private Mac toolkit | Mac publishes through WiFiPeerToPeer (`WiFiAwarePublisher`, `WiFiAwareDataSession`); phone subscribes via Android's `WifiAwareManager` | Mac: SIP off, AMFI off, ad-hoc entitled helper. Phone: public API, nearby-devices permission | No, lab only | Mac publishes a test service; S25+ test app looks for it; then a data link and a speed/lag run against the router |
| Wi-Fi Aware, public Apple API | The same link through `WAPublisher` / `WASubscriber`, once Apple enables macOS | Apple ships it; paid developer account for the entitlement | Yes | Watch each macOS release; rerun the capability probe |
| Phone hotspot | Mac joins the S25+'s access point; the phone stays on home Wi-Fi (STA+AP concurrency is supported) | Shizuku to start tethering (`TetheringManager`); this build's `cmd wifi` has no start-softap | Yes | Not run: it moves the Mac off home Wi-Fi for a few minutes, so it needs the owner's OK |
| Wi-Fi Direct group | Phone owns a P2P group; Mac joins it as an ordinary Wi-Fi client | Android `WifiP2pManager` (public) | Yes | Same trade-off as the hotspot; compare setup time and speed |
| USB networking | Phone tethers over USB (NCM); macOS has the driver built in | A cable; USB tethering switched on (today the phone's USB mode is charging + adb) | Yes | Quick speed/lag run; good as the fast "plugged in" mode |

The router stays the default and the fallback for every route.

**Notes from the [WiFiles Wi-Fi Direct research (issue #3, Aug 2026)](https://github.com/felixlix45/WiFiles/issues/3).** It's an automated research pass on Android OEMs, not a hands-on test, and it says nothing about Apple or Wi-Fi Aware. What applies to us:

- **Wi-Fi Direct works only as an opportunistic fast path, never as the main link.** Samsung still supports it, but a Feb 2025 patch reportedly broke Quick Share's transport on the S24 until a later fix.
- **Location services must be on for discovery** on every Android version, which is a common cause of silent failures. Android 13+ also needs the nearby-devices permission at runtime.
- **The group owner always makes a 5 GHz group;** asking for 2.4 GHz is ignored (AOSP 271303579, Won't Fix).
- **TLS cost:** a file-sharing app's P2P link measured 50 MB/s over plain HTTP vs 7 MB/s over HTTPS. Our session is TLS, so measure with it on.
- **Android 16 Local Network Protections** (opt-in for now) may put LAN traffic behind a new permission, the P2P subnet included. That affects the router, hotspot and Direct routes alike.
- Claimed speeds: 10–30 MB/s is a ceiling, not a guarantee. P2P is about 2–3× a 2.4 GHz hotspot and 1.2–1.5× a 5 GHz hotspot.

## Dead ends

Six routes are ruled out. Each one below was tested or read on this Mac or the S25+ on 10-28, unless noted.

| Route | Why it's dead | Evidence |
| --- | --- | --- |
| AWDL (the link AirDrop and iPhone Mirroring use) from Android | Apple-only protocol. The open re-implementation needs Wi-Fi monitor mode and frame injection, which a stock S25+ can't do, even with Shizuku (shell user, no root) | Research, not a test on the phone |
| Wi-Fi Aware through Mac Catalyst | Apple's docs list Mac Catalyst 26.0+, but the framework there does nothing | Xcode 27 SDK marks all 31 symbols unavailable on macOS and Catalyst; a Catalyst build fails with "no such module 'WiFiAware'"; [Apple's engineer](https://developer.apple.com/forums/thread/827887): it ships only so iPhone apps can launch on a Mac |
| Apple's public Wi-Fi Aware API on macOS 27.2 | Says "not supported" even with the permission | `WACapabilities.supportedFeatures` is empty. From the disassembly, it looks for feature 1 in the service's answer; the service reports only feature 0 |
| The hidden `WiFiAwareOnMacOS` switch | Turning it on doesn't change the service's answer | Override is read: `os_feature_enabled` returns 1 in both domains (a known switch reads 1, a made-up one 0). The service's answer stays the same after a reboot |
| Self-signed permission with code signing on | macOS kills the program at launch | Exit 137; AMFI: "adhoc signed but contains restricted entitlements" |
| Borrowing an Apple program that has the permission | Only background services hold it, none can be driven by hand | Holders found: sharingd, rapportd, airportd, mDNSResponder, SidecarRelay, ContinuityCaptureAgent, avconferenced and a few more |

## What could change (Apple's side)

Apple has built nearly all of Wi-Fi Aware for the Mac and left it switched off. One release that flips it on would make the direct link shippable.

**Signs Apple is building it**

- A `nan0` Wi-Fi Aware adapter showed up in the macOS 27 beta ([forum, June 2026](https://developer.apple.com/forums/thread/834091)). It exists on this Mac's 27.2, idle.
- The Mac's Wi-Fi Aware service has a switch named `WiFiAwareOnMacOS`, off by default.
- The service, its private toolkit and the Wi-Fi driver all work on the Mac today: a query powers up `nan0` and returns the chip's real limits.
- Apple's engineer, May 2026: "the Wi-Fi Aware team fully understands the desire" for Mac support ([forum](https://developer.apple.com/forums/thread/827887)).

**What to watch for in each macOS release**

- The SDK drops `@available(macOS, unavailable)` from the WiFiAware framework.
- `WACapabilities.supportedFeatures` returns `wifiAware` on a normal Mac (SIP and AMFI on).
- Apple's docs or release notes list macOS, not only Mac Catalyst.

**What we'd do then**

- Rerun the capability probe ([`probes/feat.swift`](probes/feat.swift)) on each macOS update; it takes seconds.
- Get a paid developer account for the Wi-Fi Aware permission (the camera work also waits on one).
- Add Wi-Fi Aware as a second transport under the existing encrypted session, with the router as fallback. The phone side uses Android's public API, so it can be built and tested before then.

## Evidence and current state

A request from our program gets through every layer except the public "supported" check. The next test goes around that check, straight to the private toolkit.

Mac Wi-Fi Aware stack, 5 layers, 1 gate closed (green = works, red = blocked, amber = reachable but not yet tested): the public API gate is the closed one; the service, the private `WiFiPeerToPeer` toolkit, the driver and the `nan0` adapter all answered.

**Phone (Galaxy S25+), read over wireless adb**

- Wi-Fi Aware: on, pairing supported, 8 data sessions, 1 data interface.
- Wi-Fi Direct and Wi-Fi RTT present; STA+AP and STA+STA concurrency supported.
- USB mode today: charging + adb.

**The Mac's state (changed for the lab)**

| Change | Undo |
| --- | --- |
| SIP off (was already off) | `csrutil enable` from Recovery |
| AMFI off: `amfi_get_out_of_my_way=1` (plus `wifiaware_allowlist=0`) | `sudo nvram -d boot-args`, then reboot |
| `WiFiAwareOnMacOS` override in `/Library/Preferences/FeatureFlags/Domain/` (WiFiP2P and WiFiAware) | `sudo rm` both plists, then `sudo killall wifip2pd` |

## Probe sources

All in [`probes/`](probes/). Built by hand with `swiftc`/`clang`; Mac programs are signed ad hoc with the entitlements in the `.plist` files (for example `codesign -f -s - -i dev.pocketdeck.awaretest --entitlements ent-pub.plist pub`). Pass a passphrase as an argument, never in the source.

| File | What it does |
| --- | --- |
| `feat.swift`, `probe.swift`, `caps*.swift`, `feat2.swift` | Query the public API's capability getters |
| `ff.c` | `os_feature_enabled` check for the feature-flag override |
| `classes.c`, `classes.txt`, `intro.m`, `proto.m` | List and reflect on the private `WiFiPeerToPeer` classes |
| `tr.py`, `walk.py`, `trace.lldb` | lldb scripts that trace the service's gate checks |
| `pub.m` | Mac publisher through the private toolkit |
| `sub.m`, `server.py` | Mac-side subscriber and data-link test, and a TCP echo server |
| `android/` | S25+ test app using the public `WifiAwareManager` (build outside macOS while AMFI is off) |

## Sources

- [Apple: Wi-Fi Aware documentation](https://developer.apple.com/documentation/wifiaware)
- [Apple forums: Do Mac computers support Wi-Fi Aware?](https://developer.apple.com/forums/thread/827887)
- [Apple forums: A Wi-Fi Aware network adapter has appeared in macOS 27 beta](https://developer.apple.com/forums/thread/834091)
- [Apple forums: Wi-Fi Aware support on MacCatalyst](https://developer.apple.com/forums/thread/813156)
- [WiFiles issue #3: Wi-Fi Direct health on major OEMs (2026)](https://github.com/felixlix45/WiFiles/issues/3)
