# Direct link — the Wi-Fi Aware provider

Design for epic "direct link", phase P0. Implements decisions D6–D9 of
the epic plan. The session layer it plugs into is
`docs/design/paths.md`; the requirements are `docs/specs/transport.md`
(`DIRECT-n`). The evidence is `docs/research/wifi-aware-direct-link/` (the
README, the 2026-10-30 proof, and the probe sources it names).

The short version of the research: the Mac already contains a working Wi-Fi
Aware (NAN) stack — `nan0`, `wifip2pd`, the private `WiFiPeerToPeer` toolkit —
and a data path (NDP) to a stock Android phone comes up with a PSK. What does
not work is an ordinary socket on `nan0`: macOS's network policy refuses flows
that are not Apple's own. The path that works, and the one this design uses, is
a **BPF tap on `nan0` plus a userspace IPv6 stack**. Everything above it is the
same TLS and the same session layer as the LAN.

This provider is optional, off by default, and never in the public build
(D6). The Mac half needs SIP off and an AMFI boot argument, which is why it can
only ever be a self-build.

## 1. The gating

### 1.1 macOS: a compile condition, a product, and one script

- `CONTIGUA_DIRECT` is a Swift compilation condition. Every direct-only file
  is wrapped in `#if CONTIGUA_DIRECT` — the provider, its settings row, the
  UNIX-socket client, and the helper's own sources.
- `contigua-directd` is a separate SwiftPM **product** (an executable). The
  app target does not depend on it.
- `macos/scripts/direct/build.sh` is the only thing that passes the condition:
  it builds `Contigua.app` with `-Xswiftc -DCONTIGUA_DIRECT`, builds
  `--product contigua-directd` with the same flag, ad-hoc signs the helper,
  and writes all of it to `macos/build/direct/`. `macos/scripts/bundle.sh` (the
  public bundler) never passes the flag, so `swift build`, `swift test` and the
  public bundle compile a stub: `main` prints `built without CONTIGUA_DIRECT`
  and exits 2, and no file mentions a private framework.
- The helper's target does exist in `Package.swift` (so the product name is
  real and K2 builds it), but its gated-away body is empty. That is deliberate:
  a public `swift build` must not compile a line of Aware code, and K2 runs
  exactly that build.

### 1.2 Android: one Gradle property

- `-Pcontigua.direct=true` adds `app/src/direct/java` to the main source set
  and `app/src/direct/AndroidManifest.xml` to the manifest merge, using the
  variant API (`androidComponents.onVariants { variant.sources.manifests
  .addStaticSourceDirectory("src/direct") }`; AGP 8.7 already has it).
- Without the property, `src/direct/` is not a compile input and the merged
  manifest has no `NEARBY_WIFI_DEVICES`: the public APK has no Aware code and no
  extra permission.
- The direct manifest overlay carries the permissions in §4.4 and nothing else;
  the application's own manifest keeps every shared declaration.

### 1.3 The check that proves the public build has none of it

A gate that cannot fail is not a gate, so the check runs in both directions.

| Where | What |
|---|---|
| K2 `DirectGateTests.testPublicSourcesCarryNoDirectCode` | scans `macos/Sources/**` and fails on `WiFiPeerToPeer`, `WiFiAware`, `nan0`, `wifi-aware`, `contigua-directd` or `CONTIGUA_DIRECT` outside a `#if CONTIGUA_DIRECT` block (comments included: a copied line is how this leaks) |
| K2 `DirectGateTests.testPublicBuildHasNoProvider` | `DirectProvider.isCompiledIn == false`, and the app target's dependencies do not contain the helper |
| K1 `DirectGateTest` | the source set contains no `src/direct` directory and the build flag is false |
| K1 Gradle `verifyPublicBuildHasNoDirect` (runs inside K1's `assembleDebug`) | the merged debug manifest has no `NEARBY_WIFI_DEVICES` and the compiled class list has no `app.contigua.direct` class |
| `macos/scripts/direct/gate.sh --public <Contigua.app>` | the built bundle's binary and `Info.plist` carry none of the listed strings and the bundle contains no `contigua-directd`; run by the reviewer's P4 sign-off |
| `macos/scripts/direct/gate.sh --direct <dir>` | the positive control: the direct build **does** contain the helper binary, the entitlement and the strings — so the public check is known to be able to see them |

## 2. The Mac helper: `contigua-directd`

### 2.1 Process layout

| Piece | Path | Notes |
|---|---|---|
| the daemon | `/Library/Application Support/Contigua/contigua-directd` | `root:wheel`, `0755`, ad-hoc signed with the entitlement |
| its plist | `/Library/LaunchDaemons/app.contigua.directd.plist` | `root:wheel 0644`, `RunAtLoad`, `KeepAlive`, `UserName` root |
| its log | `/var/log/contigua-directd.log` | `root:wheel 0640`; states, counts and codes only |
| its socket | `/var/run/contigua-directd.sock` | `SOCK_STREAM`, `0660 root:staff`, removed on unload |
| our probe | the same binary, `--probe` | one JSON line to stdout, then exits |

- **Root LaunchDaemon** because it opens `/dev/bpf` and installs a route (D7).
  It has no UI, no network client of its own and no knowledge of Contigua's
  protocol.
- **Signature**: `codesign -f -s - --identifier app.contigua.directd
  --entitlements macos/direct/directd.entitlements <binary>`. Entitlements:
  `com.apple.developer.wifi-aware` = `["Publish","Subscribe"]` and
  `com.apple.wifip2pd` = `true` (the pair the probes used, `ent-pub.plist`).
  Its `Info.plist` declares `WiFiAwareServices` → `_contigua-nan._tcp` with
  `Publishable` and `Subscribable`, which is what makes the service name legal
  for the toolkit.
- Ad-hoc signing is why AMFI has to be relaxed: the entitlement is restricted,
  and macOS kills an ad-hoc binary that carries it as soon as code-signing
  checks are on (exit 137, "adhoc signed but contains restricted
  entitlements"). Nothing in the public build touches any of this.
- The daemon is a single-threaded event loop (`kevent` over: its listening
  socket, its client sockets, one BPF descriptor). No lwIP thread, no work
  queues: one owner of the stack means no locks in the datapath.

### 2.2 NAN: subscribing and the data path

The private toolkit has no headers and no link-time symbols, so the helper
`dlopen`s it and speaks Objective-C to the classes the probes named:

```objc
dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer", RTLD_NOW);
```

**Subscribe** (as `sub.m`):

1. `WiFiAwareSubscribeConfiguration` `-initWithServiceName:` with
   `_contigua-nan._tcp`; `-setAuthenticationType:0`.
2. `WiFiAwareSubscriber` `-initWithConfiguration:`, `-setDelegate:`, `-start`.
3. The delegate's discovery callback hands over a `WiFiAwareDiscoveryResult`.
   `sub.m` does not name that selector: it forwards every selector whose name
   starts with `subscri…` and takes the `WiFiAwareDiscoveryResult` it finds among
   the arguments. The helper pins the real selector with `proto.m`
   (`objc_getProtocol` + `protocol_copyMethodDescriptionList`) and keeps the
   forwarding delegate as the fallback, because Apple renames private selectors
   between releases.
4. On a discovery result whose service-specific info matches our HMAC (§6):
   `WiFiAwareDataSession` `-initWithDiscoveryResult:serviceType:
   serviceSpecificInfo:passphrase:` with `serviceType` 1 and the PSK
   passphrase, `-setDelegate:`, `-start`. This is the NDP: the phone is the
   publisher, the Mac the subscriber and the initiator, which is the direction
   the proof used (Android cannot set the field Apple wants in a phone-initiated
   request).
5. The data session's own state reports carry the peer's link-local IPv6 and
   MAC (`WiFiAwareDataPathState`, `WiFiAwareNDIInfo`, `WiFiAwareDataPath-
   SessionInfo`, `WiFiAwareNDISessionCounters` in the toolkit's class list).
   The helper needs nothing else: from here the peer is "one MAC and one
   link-local address on `nan0`".

The **publish** side is documented only for completeness — in this product the
phone publishes and the Mac subscribes (`pub.m` is the reference if a Mac-side
publish is ever needed): `WiFiAwarePublishConfiguration` `-initWithServiceName:`,
`-setDatapathConfiguration:` built from `WiFiAwarePublishDatapathConfiguration`
`-initWithServiceType:securityConfiguration:` and
`WiFiAwarePublishDatapathSecurityConfiguration`
`-initWithPMKList:passphraseList:`, then `WiFiAwarePublisher`
`-initWithConfiguration:`, `-setDelegate:`, `-start`.

Timing: the proof brought an NDP up in about 3.5 s. The helper allows 20 s and
reports `ndp_timeout` after it; the LAN path keeps running throughout, so a slow
radio costs nothing the person sees.

### 2.3 BPF on `nan0`

One descriptor per interface, opened by brute force over `/dev/bpf0…63` (macOS
hands out one exclusive descriptor per interface), with exactly the options the
probes used:

| ioctl | Value | Why |
|---|---|---|
| `BIOCSETIF` | `nan0` | the interface |
| `BIOCIMMEDIATE` | 1 | read as frames arrive; a buffered read would add the pool's latency to every packet |
| `BIOCSHDRCMPLT` | 1 | we supply the Ethernet header on write (there is no kernel source-address fill for a frame we build) |
| `BIOCSRTIMEOUT` | 200 ms | the loop's own tick, so timers run without a second thread |
| `BIOCSBLEN` | 256 KiB | two MTU-sized frames plus headroom, so a burst is not dropped |

- Read: the buffer is a chain of `bpf_hdr` + frame; each frame is Ethernet with
  ether type `0x86DD` and is handed to lwIP. Frames to another MAC are ignored.
- Write: build Ethernet (our MAC, the peer's MAC from the data session) +
  IPv6 + TCP (nanagent's `build_echo` is the shape) and `write()` the whole
  frame. No checksum offload: lwIP computes the TCP/UDP checksum itself.
- The MAC and the link-local come from `getifaddrs` on `nan0`, read after the
  data session reports up.
- Net effect: the network policy that refuses a `socket(AF_INET6)` on `nan0`
  never sees this traffic, because there is no kernel socket (proof §3/§4).

### 2.4 lwIP, and the per-peer route

- **Stack**: lwIP, vendored source, `NO_SYS=1`, single-threaded inside the
  daemon's loop. Modules: `core/ipv6` (`ip6.c`), `core/nd6.c` (neighbour
  solicitation/Advertisement for our own address), `core/icmp6.c`,
  `core/tcp*.c`, `core/pbuf.c`, `core/memp.c`, `core/mem.c`,
  `core/timeouts.c`, `core/netif.c` and `netif/ethernet.c` for the header.
  Options: `LWIP_IPV6=1`, `LWIP_IPV4=0`, `LWIP_TCP=1`, `LWIP_UDP=0`,
  `LWIP_ICMP=0`, `LWIP_ICMP6=1`, `LWIP_ND6=1`, `LWIP_DHCP=0`,
  `LWIP_SOCKET=0`, `LWIP_NETCONN=0`, `TCP_MSS=1400`, `MEM_SIZE` 512 KiB per
  path, `MEMP_NUM_TCP_PCB` 8, `LWIP_TCP_SACK_OUT=0`.
- **netif**: one `struct netif` on `nan0` whose `linkoutput` writes a built
  Ethernet frame to the BPF descriptor and whose `output_ip6` resolves the peer
  through lwIP's own neighbour table. Because the data session already told us
  the peer's MAC, the peer gets a **static neighbour entry** and no
  solicitation round trip is needed in that direction. In the other direction
  we must answer: the phone solicits for our link-local before it sends, so
  `nd6`'s solicitation answer is load-bearing (and is what the proof's
  `icmp6` counters show).
- **The route**: `nan0` gets a link-local address but no `fe80::%nan0/64` route
  is installed (proof §3), so the helper adds a per-peer host route,
  `route add -inet6 <peer-ll> -interface nan0`, idempotent, and removes it when
  the link goes down. It is what makes the kernel's own NDP and `ifconfig`
  honest; the data path itself never uses a kernel socket. lwIP holds its own
  per-peer route table.
- **Pinned commit**: chosen in P2. The requirement on it: one git commit hash,
  its `LICENSE` (BSD-3-Clause) and a `VENDORED.md` beside it naming the hash,
  the upstream URL and the local patches (a full list — the design expects two:
  a `pbuf` write into BPF, and the static neighbour entry). No patches beyond
  those two without a note in that file.
- **Cost**: one TCP connection of a screen stream is ~8 Mbit/s; lwIP on one
  core runs at tens of Mbit/s. P2 measures it (§7) rather than assuming it.

### 2.5 The UNIX socket API

One socket, `/var/run/contigua-directd.sock`, one request per line, one reply
per line. UTF-8 JSON, `\n`-terminated, request ≤ 4096 bytes, reply ≤ 4096 bytes,
plus one file descriptor where a link is handed over.

| Request | Reply |
|---|---|
| `{"op":"hello","v":1}` | `{"ok":true,"v":1,"toolkit":{"publish":true,"subscribe":true,"dataLinks":16}}` |
| `{"op":"probe"}` | `{"ok":true,"ready":false,"codes":["amfi_enabled"],"detail":"…"}` |
| `{"op":"dial","peer":"<32 hex>","svc":"_contigua-nan._tcp","psk":"<64 hex>","port":<u16>}` | `{"ok":true,"link":"<16 hex>","mtu":1500}` **+ one fd** |
| `{"op":"close","link":"<16 hex>"}` | `{"ok":true}` |
| `{"op":"links"}` | `{"ok":true,"links":[{"link":"<16 hex>","peer":"<32 hex>","state":"up","rttMs":11}]}` |
| anything else | `{"ok":false,"code":"bad_request","message":"…"}` |

- The `dial` reply's fd is a connected `socketpair` end sent with `sendmsg` and
  `SCM_RIGHTS` (one `cmsghdr`, `SOL_SOCKET`, `SCM_RIGHTS`, one `int`). The app
  reads and writes it as an ordinary socket; **TLS lives in the app**, so the
  helper only ever moves ciphertext (D2). The helper bridges it to one lwIP
  `tcp_pcb` connected to the peer's link-local on `port`.
- `psk` is the 32-byte NDP key as 64 hex; the helper derives the passphrase
  (§5), uses it for the NDP and wipes both buffers at once. It never appears in
  a log, an error message or the reply.
- Error codes: `bad_request`, `not_ready`, `not_console_user`, `busy`,
  `no_key`, `ndp_timeout`, `ndp_refused`, `link_unknown`, `too_many_links`.
- **Access control**: on every `accept`, `getpeereid(fd, &uid, &gid)` must equal
  the console user's uid (`SCDynamicStoreCopyConsoleUser`); the socket's mode
  is `0660 root:staff` and the peer check is the real gate. A mismatch replies
  `{"ok":false,"code":"not_console_user"}` and closes without reading a
  request. Every console user of this Mac is the same person; the check exists
  so a *different* local account (or a sandboxed process running as another
  user) cannot drive the helper.
- The app connects at launch, keeps one connection, and drops it when the
  helper restarts: a broken pipe means "probe again", never a crash.

### 2.6 The probe at launch, and its codes

`contigua-directd --probe` runs the same checks the installer runs, in the
same order, and prints one JSON line:

| Code | Meaning | What the settings say |
|---|---|---|
| `ok` | every check passed | "Direct link is ready." |
| `sip_enabled` | `csrutil status` is enabled | "System Integrity Protection is on. The installer prints the Recovery step." |
| `amfi_enabled` | `amfi_get_out_of_my_way=1` is not in `nvram boot-args` | "Code-signing checks are on. The installer prints the boot argument." |
| `allowlist_enabled` | `wifiaware_allowlist=0` is not in `nvram boot-args` | same sentence, naming that argument |
| `entitlement_denied` | the toolkit refused the entitlement (the binary died with 137) | "macOS refused the Wi-Fi Aware entitlement. See the installer's last step." |
| `nan0_absent` | `if_nametoindex("nan0")` is 0 | "This Mac has no Wi-Fi Aware interface." |
| `wifip2pd_unreachable` | `com.apple.wifip2pd` did not answer within 2 s | "The Wi-Fi Aware service is not answering. Restart the Mac." |
| `directd_not_running` | the app cannot reach the socket | "The direct link helper is not running. Run the installer again." |
| `socket_permissions` | the socket exists but the peer check failed | "The direct link helper refused this app." |

- The daemon re-runs the probe at launch **and after every wake of the Wi-Fi
  stack** (a data-session failure re-probes once). It never caches "it worked
  last time": a macOS update may move any of these gates, and the research's
  whole point is that they are policy, not capability.
- A failed probe means there is **no `direct` provider at all** for that
  session: the app offers only `lan`, and the settings row for direct is
  disabled with the code's sentence (honest settings, CONV-PD-09).
- **Where the person sees it** (decided by the reviewer, 10-30): the Direct
  link switch lives on that phone's Settings page, beside "Share notifications
  and Now Playing"; the probe's answer is shown once in **This Mac ▸ General**,
  where the install belongs. P4 draws both, after the person sees options.

## 3. Install and uninstall

The scripts live in `macos/scripts/direct/`, run with the person's own `sudo`
and are the only thing that ever writes outside the app's build directory.

### 3.1 `install.sh`

1. Refuse (with the exact line to run) when it is not root, or when it cannot
   find `macos/build/direct/contigua-directd` (i.e. `build.sh` was not run).
2. Run `contigua-directd --probe` once in the foreground **before installing
   anything**, and print its codes. Exit 137 is reported as
   `entitlement_denied`.
3. Check and print, never change:
   - `csrutil status` → if enabled, print the Recovery step verbatim:
     "Restart in macOS Recovery (hold the power button until the options
     appear), open Terminal, run `csrutil disable`, restart."
   - `nvram boot-args` → print the exact command the person must run, and the
     revert:
     ```
     sudo nvram boot-args="wifiaware_allowlist=0 amfi_get_out_of_my_way=1"
     # revert: sudo nvram -d boot-args
     ```
4. Print the cost, in these words (they are the product's, not a warning
   boilerplate):

   > This turns off two of macOS's own protections for the whole Mac, for every
   > program, not only Contigua. With code-signing checks off, every Java
   > program crashed at launch on this Mac — Android Studio and Gradle builds
   > included — so the phone app cannot be built here while the setting is on.
   > The phone's battery pays too: while a session is live it keeps a Wi-Fi
   > Aware discovery session and an idle data path up, so the Mac can come back
   > to it.

5. Take a **typed confirmation**, not a keypress: the person types
   `install contigua-directd` exactly. Anything else aborts with nothing
   changed.
6. Install: copy the binary to `/Library/Application Support/Contigua/`,
   write the plist, `chown root:wheel`, `chmod 0755` the binary and `0644` the
   plist, then `launchctl bootstrap system /Library/LaunchDaemons/
   app.contigua.directd.plist`.
7. Verify: `launchctl print system/app.contigua.directd` says running, the
   socket exists with `0660 root:staff`, and `--probe` now answers `ok` (or the
   code that says what is still missing).
8. Say the last step: the boot arguments need a restart, and after the restart
   Contigua ▸ Settings ▸ Direct link shows the probe's answer.

The installer never sets SIP or boot-args, never reboots, and never edits
anything else in `/Library`.

### 3.2 `uninstall.sh`

1. Typed confirmation `remove contigua-directd`.
2. `launchctl bootout system/app.contigua.directd`, then remove the plist, the
   binary, the socket and `/Library/Application Support/Contigua/` (when it
   holds nothing else), and the log.
3. Print the revert, without running it:
   ```
   sudo nvram -d boot-args      # then restart
   csrutil enable               # in Recovery
   ```
4. Say what is **not** reverted by the script: the phone's direct switch keeps
   its value (the person turns it off on the phone), and the stored key stays
   until the phone is forgotten (§5).

## 4. The phone provider (`src/direct/`)

### 4.1 Attach, publish, and the service name

1. `WifiAwareManager.isAvailable()` and
   `PackageManager.hasSystemFeature(FEATURE_WIFI_AWARE)`: both must be true or
   the row is disabled with its reason. Register for
   `ACTION_WIFI_AWARE_STATE_CHANGED`; on it, drop every session and re-attach
   (the platform's own rule).
2. `WifiAwareManager.attach(callback, identityListener, handler)` →
   `WifiAwareSession` (one per app process, kept while direct is on).
3. `WifiAwareSession.publish(PublishConfig, callback, handler)` with
   `setServiceName("_contigua-nan._tcp")`,
   `setServiceSpecificInfo(ssi8)` (§6),
   `setDataPathSecurityConfig(WifiAwareDataPathSecurityConfig.Builder(
   WIFI_AWARE_CIPHER_SUITE_NCS_SK_128).setPskPassphrase(passphrase).build())`,
   `setTerminateNotificationEnabled(true)`.
4. One publish session per Mac it holds a key for and whose switch was last
   reported on (§4.3), because the SSI is per PSK and a Mac can only recognise
   its own. The platform allows 8
   publishers; past that (or on `onSessionConfigFailed`) direct is off for this
   session with the reason "This phone's Wi-Fi is already busy with another
   Aware app."
5. The SSI is updated every 10 minutes: `updatePublish` with the new bytes, or
   a publish/republish when the platform refuses an in-place update. A failed
   update is not fatal; the next tick retries.

The service name is a constant in one place per side (`_contigua-nan._tcp`),
and the helper's `Info.plist` declares it.

### 4.2 The NDP and the listener

1. On `onPublishStarted(session)`, the phone builds
   `WifiAwareNetworkSpecifier.Builder(publishSession)`
   `.setPskPassphrase(passphrase).setPort(P)` (`.setTransportProtocol(6)` — TCP)
   and `connectivityManager.requestNetwork(NetworkRequest with
   TRANSPORT_WIFI_AWARE, callback, handler, 30_000)`.
2. On `onAvailable(network)`: create the `ServerSocket`, `network.bindSocket(ss)`
   so it is bound to the Aware network, `ss.bind(InetSocketAddress(P))`, and
   accept — in the **app** process, because the network belongs to the uid that
   asked for it (§4.5). `WifiAwareNetworkInfo` gives the peer's IPv6 (the Mac's)
   and the link's bandwidth estimate, which is logged as a number and nothing
   else. A connection can arrive at any time the NDP is up: as a path of a live
   session, or as the first path that founds one.
3. Each accepted socket is handed to the shell service (§4.5) and then goes
   through the **existing** server path: the same TLS wrap, the same gates, the
   same `Session` slot (a `join`, or the first path of a new session). One more
   listener, no second server: the Aware socket and the LAN socket feed the same
   `Server`.
4. Because the Mac dials, the phone needs no client-side Aware code at all:
   no `subscribe`, no `NetworkRequest` from the phone.

### 4.3 Lifecycle: when it publishes, and the standby path

The phone publishes while **all** of these hold, and tears down within one
second of any of them failing:

- its own **Direct link** switch is on (and its permission is granted);
- it holds a direct key for at least one paired Mac **whose switch was last
  reported on** — the key only exists once that Mac turned its own direct switch
  on inside a LAN session (§5), and `direct.enable` is stored, not just acted
  on, so `on: false` (with no session open) keeps that Mac from being published
  for; a later `on: true` restores it. This is the phone's half of "a paired Mac
  has direct on";
- the app process is alive: only the app may own an Aware network, so only the
  app can publish and accept (§4.2).

**A session is not required** (D8; the review's F2). Publishing with no session
is what lets a direct path *start* a session: after the LAN has gone and the
30 s grace has ended, the phone is still discoverable, the Mac's helper is still
subscribed, and the next attempt can be a direct one. A publish alone carries no
data path and no traffic.

While a session is live the NDP is kept up as a **standby path**, even when the
LAN is carrying everything — that is what makes a switch instant. The standby
begins with the session (the Mac's `direct.enable` for this phone and a live
session) and ends with it. So the direct build has **two** exceptions to
ARCHITECTURE's idle-cost rule, and the settings name both: an idle **publish**
whenever the switch is on and a key exists, and the **standby NDP** while a
session is live. The reviewer measures the idle drain with publish on and off
(percent per hour) and the phone's row repeats the cost in one sentence
(transport.md `DIRECT-16`).

A session may start on either path. The Mac dials the LAN and the direct path in
parallel (§paths §9); the first to finish TLS sends the plain `hello` and founds
the session, and the other joins it. The phone's slot does not care which
listener a connection came from — it sees one `Connect` either way.

A network that is lost (`onLost`) or an Aware state change tears the NDP down,
tells the session (the path goes down), and leaves the publish running so the
next attempt (or the grace) can bring an NDP back. Every change the phone makes
to its own side (the switch, the permission, a refused publish) is sent as
`direct.state` (PROTOCOL.md "Direct link"), so the Mac's row shows the phone's
real state instead of assuming it.

### 4.4 Permissions

| API | Permission | Notes |
|---|---|---|
| 33+ | `NEARBY_WIFI_DEVICES` with `usesPermissionFlags="neverForLocation"` | the runtime permission the person grants in context |
| 30–32 | `ACCESS_FINE_LOCATION` | required for Aware discovery below 33; minSdk is 30, so this branch ships |
| all | `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `INTERNET`, `CHANGE_NETWORK_STATE`, `ACCESS_NETWORK_STATE` | the probe's manifest, all normal permissions |

- The runtime permission is asked **when the person turns the switch on**, with
  one sentence: "Contigua uses Wi-Fi Aware to reach your Mac directly, without
  your router." A denial turns the switch back off and leaves a sentence, not a
  dead switch (CONV-AND-03).
- Location services must be on for discovery on every Android version; a phone
  with them off reports "Location is off, so Wi-Fi Aware cannot find your Mac."
- Nothing else is asked, and the public build asks for none of it (§1.3).

### 4.5 The process split: the app owns Aware, the shell serves the socket

An Aware network created by `requestNetwork` belongs to the **UID that asked
for it**, and only the app process has a `WifiAwareManager`. The shell service
(UID 2000) can do neither. So, and this is the decision:

- **The app process** owns `attach`, `publish`, the NDP's `requestNetwork`, the
  `ServerSocket` bound to the network (`network.bindSocket`), and `accept`.
- **Every accepted socket goes to the shell service** as a
  `ParcelFileDescriptor` (`ParcelFileDescriptor.fromSocket(socket)`) over the
  existing AIDL — one new growable transaction, `adoptDirectSocket(fd)`, added
  at the end of `IDeckService` (the transaction codes only ever grow). The app
  hands the descriptor over and closes its own copy; the shell `dup`s it and
  wraps it as a `Socket`, then runs **the same** TLS wrap, the same gates, the
  same `SessionSlot` and the same `Session` as a LAN socket. TLS still
  terminates in the shell, exactly as for the LAN, and a handed-over socket can
  be a session's *first* path as readily as a later one (§4.3).
- **The key never goes to the shell.** The app stores it Keystore-wrapped and
  decrypts it only for its own `publish` and `requestNetwork` calls (§5).

**The named risk**: using an accepted socket's descriptor from another UID. On
Android a socket descriptor is not UID-bound once it is duplicated into another
process, but no public API promises that: SELinux policy, a library that checks
the creator's credentials, or a future platform change could refuse it. The
proof is the reviewer's phone: the shell's TLS handshake completes over a
handed-over Aware socket (`DIRECT-17`). Wrapping the descriptor uses the
platform's package-private `Socket(FileDescriptor)` constructor through the
same guarded reflection the shell already uses elsewhere; a failure logs one
closed token (`path-fd-wrap failed`) and is not fatal.

**The named fallback**: the *bridge*. The app creates an `AF_UNIX` `socketpair`,
hands one end to the shell over the same AIDL call, keeps the other, and copies
bytes between the Aware socket and its end (two threads, 8 KiB buffers, no
framing, no parsing). TLS still terminates in the shell, so the guarantee is
unchanged; the cost is two copies per byte (a few percent of one core at mirror
rates). It is used only when the descriptor cannot be wrapped for that session,
and it logs `path-bridge` once so a log shows which path ran.

A path that ends closes its socket in the shell and frees the app's reference;
nothing about a socket survives the path. Only the app process holds the Aware
session, the NDP and the key.

## 5. The key (D9)

- **Length and shape**: 32 random bytes from the Mac's system RNG
  (`SecRandomCopyBytes`), carried as 64 lowercase hex.
- **Generating it**: the Mac does it on the **first session over LAN** (never
  over direct: there is nothing to carry it on) in which both sides announced
  both switches are on, and no key is stored for that phone. It sends `{"t":"direct.key","key":"<64 hex>"}` inside TLS and stores
  it (`directKeys[deviceId]`, §5). The phone answers `direct.key.ok` once it
  has stored it; an unacknowledged key is regenerated on the next LAN session
  (the phone may have missed it).
- **Storage, Mac**: a per-profile `direct.json` (`0600`, in the `0700` profile
  folder, beside `pins.json`), one record per phone: `{"<deviceId>":{"key":
  "<64 hex>","created":<epoch s>}}`. **Not the login Keychain**, which is
  today's profile rule for key material (pairing.md PAIR-1); decided by the
  reviewer on 10-30, recorded in `docs/specs/transport.md`'s decisions. The
  daemon cannot read the person's
  login keychain anyway (the research hit exactly that: "No keychain is
  available"), which is why the key is handed to the helper per dial rather
  than read by it.
- **Storage, phone**: `AES-256-GCM` with a non-exportable key in the Android
  Keystore (alias `contigua-direct-psk`); the ciphertext (`iv ‖ ct`, base64)
  lives in the app's private prefs as `direct.psk.<clientId>`. The app decrypts
  it only for its own `publish` and `requestNetwork` calls (§4.5); it never
  crosses AIDL and the shell service never receives it.
- **Rotation**: deleting the pairing deletes the key on both sides — the Mac on
  Forget This Phone… (and on a pin mismatch that forces a re-pair), the phone
  on Forget / Forget All Macs… (Forget All rotates the phone's identity, so the
  Mac's pin fails and its key goes with the record). The next LAN session mints
  a fresh one. A key is never reused across a re-pair.
- **R-PRIV-1**: nothing about the key is ever logged. The one line that
  mentions it carries `key=<first 8 hex of SHA-256(key)>` and a length; the
  passphrase string is never logged, never in an error message, never in the
  UNIX socket's reply, and never in the e2e share log. K1 and K2 grep their own
  logs for the 64-hex value and for the passphrase (the e2ee suite's pattern).
- **The air** (§6): the key never travels on the radio; only an HMAC of it does.

## 6. Discovery carries no stable identifier

- Per 10-minute window `w = floor(unixSeconds / 600)`:
  `ssi = HMAC-SHA256(psk, "pd-nan-v1" || u64_be(w))[0..8]` — 8 bytes.
- The phone publishes `ssi` for the current window and updates it when the
  window turns. The helper accepts the current window and its two neighbours
  (±10 minutes) so a clock that is a few minutes off still matches, and ignores
  every discovery result whose 8 bytes match neither.
- What an observer on the air sees: a service name that is the same for every
  Contigua pair, 8 bytes that change every 10 minutes, and the phone's
  Aware discovery MAC, which the platform itself rotates on every attach
  (Android's own behaviour, re-created per `attach`). No device id, no name, no
  fingerprint, no key: the mDNS `id`/`name`/`model` never appear here.
- The helper does not use a NAN match filter: a match filter is plaintext on
  the air, and the SSI check happens in the helper after discovery anyway.
- Matching is only an optimisation: a stranger cannot compute a valid SSI, and
  a wrong match buys nothing because the next step is a TLS handshake against
  the pinned certificate.

## 7. The P2 test plan (Mac helper, no phone)

P2 builds the helper and proves it in the VM with a **`feth` pair**: the guest's
kernel plays the phone, our helper plays itself, and no radio is involved.

### 7.1 Does `feth` exist in the guest?

Yes — from the sources, not from a boot:

- `feth` is XNU's "fake ethernet" driver, `bsd/net/if_fake.c` in Apple's
  open-source XNU, still present on `main`. It is a pair of interfaces whose
  output/input paths are crossed over: `ifconfig feth0 create`,
  `ifconfig feth1 create`, `ifconfig feth0 peer feth1`, both `up`, and frames
  written on one come out of the other. Their `ether` starts `66:65:74:68`
  ("feth").
- It is **undocumented**: `ifconfig(8)` on this Mac (macOS 26) has no `feth`
  entry, and this repo has no reference to it. It has been in the Darwin kernel
  since 10.13 and is used by VM tooling for exactly this job.
- Nothing about it needs SIP, AMFI or the radio, so it works in the stock
  `macos-tahoe` guest the e2e VM uses.
- What is *not* known from the sources: whether the guest image's kernel has the
  interface compiled in, and the maximum frame a BPF `write` accepts on `feth`
  (field reports put the injection limit at 2048 bytes even with a larger MTU).
  Both get one command at the start of the P2 run, not a boot now:
  `ifconfig feth0 create && ifconfig feth1 create && ifconfig feth0 peer feth1`
  and one max-size frame each way. If either fails, the plan falls back to a
  `bridge` + `vlan` pair, and the doc records which one ran.

### 7.2 The harness

1. `bash macos/scripts/vm-e2e.sh feth-path` (one boot, inside the heavy lock):
   the guest creates the `feth` pair, gives `feth0` a link-local
   (`fe80::1%feth0`), and runs `contigua-directd` with
   `CONTIGUA_DIRECT_IF=feth0` (a test-only override of the interface name).
2. `tools/fakephone/fethphone.py` plays everything the radio would: it answers
   neighbour solicitations for `feth1`'s link-local, runs a TCP listener, and
   answers the helper's frames when the helper writes to a pinned MAC.
3. Steps: probe → dial over the UNIX socket → the helper's fd → the app's TLS
   client on it → `hello`/`welcome` → `path.ping` RTT → a 30 s transfer. Every
   step prints a line the check asserts.
4. The `feth` path is also where **lwIP's own correctness** is proven: a
  1 MiB echo with every byte compared, a 1400-byte MSS boundary run, a frame
   that arrives fragmented (two writes), and a peer that closes mid-transfer
   (the helper must report `link` down, not hang).

### 7.3 The throughput benchmark

Three numbers, all in the guest, all recorded in `docs/design/direct-link.md`
when P2 runs (they replace "unknown" with a measurement):

| Figure | How | Why |
|---|---|---|
| lwIP TCP, plaintext | 64 KiB writes, 30 s, `fakephone` reading | the stack's own ceiling |
| TLS over it | the app's `TlsV2` client over the helper's fd | what the product actually gets |
| helper CPU | `ps -o %cpu` sampled each second | one core is all the daemon has |

Pass/fail against the product's need: **≥ 8 Mbit/s with TLS** (one 1080p60
mirror, ARCHITECTURE's number) with a loss-free 30 s run. A radio figure is
still unmeasured until P4; the VM number is the stack's, not the link's, and the
doc says so.

### 7.4 The NAN proof — the reviewer's, on real hardware

Never an agent, never in a VM: the reviewer's Mac with the boot arguments, the
real phone, and `--probe` saying `ok`. Then: publish on the phone, discovery on
the Mac whose SSI matches, an NDP with the PSK, the fd from the helper, a pinned
TLS handshake, and a 30 s `path.ping` run whose p50/p95/loss are written down
next to the research's numbers (10–16 ms, 0.2–1%). The real-hardware proof in
P4 adds: different LANs, the LAN cut mid-mirror continuing over direct, the LAN
back returning to LAN, and the throughput figure against the mirror's need.

## 8. The P3 test plan (phone provider)

### 8.1 K1 with fakes

The Aware API is a platform surface the JVM cannot run, so the logic sits behind
a port and the port has a fake:

- `AwarePort` (interface): `available()`, `attach(onAttached)`, `publish(ssi,
  passphrase, onStarted)`, `updateSsi(ssi)`, `requestNetwork(passphrase, port,
  onAvailable(Network), onLost)`, `unpublish()`. The real adapter
  (`PlatformAwarePort`) is thin: it maps the platform callbacks one-to-one.
- `AwareLink` (the machine): `Off → Attaching → Publishing`, then
  `NdpPending → Up` while a session is live, plus `Lost` and `Blocked(code)`.
  Events: `SwitchOn`, `SwitchOff`, `KeyStored`, `KeyForgotten`, `Attached`,
  `PublishStarted`, `SessionLive(directOn)`, `SessionEnded`,
  `NdpAvailable(network)`, `NdpLost`, `AwareStateChanged`, `PermissionDenied`,
  `SsiTick(window)`. `Attaching` needs the switch, the permission and a stored
  key — **not** a session; `NdpPending` needs a live session and the Mac's
  `direct.enable`, and it returns to `Publishing` when the session ends.
- K1 tests every transition, including the ignored ones (a publish callback
  after `SwitchOff` is dropped; an `NdpAvailable` with no publish is closed at
  once; two `SsiTick`s in one window do nothing).
- The listener binding is tested with a fake `Network`
  (`bindSocket` called before `bind`, the port from the specifier, one accept
  loop per publish session).
- `DirectGateTest` (§1.3) lives here too.

### 8.2 Does the Android emulator support Wi-Fi Aware?

**No, and the docs say so**, so P3 does not plan an emulator proof of the radio:

- Android's own emulator networking documentation lists what it emulates:
  Ethernet, Wi-Fi (a simulated access point), cellular, Bluetooth and UWB. There
  is no Wi-Fi Aware line.
- Aware needs the vendor HAL and firmware: AOSP's Wi-Fi Aware page requires
  `WIFI_HIDL_FEATURE_AWARE` and an NAN-capable HAL, which the emulator's
  simulated AP does not provide. `hasSystemFeature(FEATURE_WIFI_AWARE)` is
  therefore false there and `isAvailable()` is false.
- What the emulator *can* prove, and the only thing planned: the **disabled**
  path — the Direct link row is present, disabled, with its reason ("This
  phone's Wi-Fi doesn't support Wi-Fi Aware."), the switch cannot be turned on,
  and nothing crashes or retries in a loop. That is one emulator step in P3, in
  the existing `emulator`/`settings` style, not a radio test.

### 8.3 The real phone — the reviewer's

Publish with the switch on, the Mac's helper discovering it, the NDP, the
listener bound to the Aware network, the pinned TLS handshake over it, the
standby path while a mirror is live on the LAN, and a switch to direct and back.
The battery figure (a 10-minute idle standby's drain) is recorded there too,
because it is the price the settings text promises.

## 9. Risks

| Risk | What it would do | What the design does about it |
|---|---|---|
| **A macOS update moves a gate** | the probe starts failing, or the private API changes shape | the probe re-runs at launch and after a Wi-Fi wake; a failure is a disabled row with a sentence, never a crash; P2 re-runs the probe on every macOS major, and the reviewer's P4 is repeated after one |
| **The private API is removed or renamed** | no direct provider on that release | everything is `dlopen` + `objc_getClass`, so the app still launches and only the provider disappears; the selector discovery (`proto.m`) and the forwarding delegate are the fallback for a rename; if Apple ever enables the public framework, §2.2 is the only code to replace |
| **The network policy changes** | a BPF tap stops delivering, or `nan0` gains a route policy | the probe's first dial fails → no provider; the fallback is the LAN, which is always there |
| **AMFI off hurts the Mac** | every JVM dies; a person's other tools break | the installer says it plainly and never sets it; the public build needs none of it; uninstall prints the exact revert |
| **Throughput is too low for a mirror** | direct works for control and files but not for video | the class floor (8 Mbit/s) and the ranking keep the LAN current unless direct can win; P2 measures, P4 confirms; if the measurement misses the need, the class floor is lowered in one place and direct becomes a fallback-only path — no session-layer change |
| **Battery** | a phone on a desk drains faster with an idle publish and, while a session is live, a standby NDP | the publish needs the switch on and a stored key; the standby needs a live session; the switch off ends both at once; the settings name both costs in one sentence and the reviewer measures the idle drain (percent per hour) for `DIRECT-16` |
| **Two phones, two keys** | more publish sessions than the platform allows | one publish per Mac with direct on, capped at 8 with a reason; the Mac side is single-phone today anyway (settings.md) |
| **An old phone or an old Mac** | a peer on protocol 3 | it is refused with `error version` and a close (paths §1.1); no `direct.*` message is ever sent to one, and nothing tells a v3 peer that this build has the provider |
