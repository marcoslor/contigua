# lwIP, vendored

Upstream: https://github.com/lwip-tcpip/lwip (mirror of
https://git.savannah.nongnu.org/git/lwip.git)
Tag: `STABLE-2_2_1_RELEASE` (annotated tag `009c2256469004009488b3385ba269461e8eb616`)
Commit: `77dcd25a72509eb83f72b033d219b1d40cd8eb95` ("Prepare 2.2.1 release", 2025-02-05)
Licence: BSD-3-Clause, `COPYING` beside this file (unchanged).

Vendored for `pocketdeck-directd` (docs/design/direct-link.md §2.4): IPv6,
TCP and ND6 only, `NO_SYS=1`, compiled by the SwiftPM C target `PDLWIP`
(`macos/Package.swift`).

## What was copied

- `src/include/lwip/**` and `src/include/netif/**` — the headers the modules need.
- `src/core/`: `def.c`, `inet_chksum.c`, `init.c`, `ip.c`, `mem.c`, `memp.c`,
  `netif.c`, `pbuf.c`, `sys.c`, `tcp.c`, `tcp_in.c`, `tcp_out.c`, `timeouts.c`.
- `src/core/ipv6/`: `ethip6.c`, `icmp6.c`, `inet6.c`, `ip6.c`, `ip6_addr.c`,
  `ip6_frag.c`, `nd6.c`.
- `src/netif/ethernet.c`.

`ip6_frag.c` is linked only because lwIP's timer table names `ip6_reass_tmr`;
fragmentation is off (`LWIP_IPV6_FRAG=0`). Nothing else is copied: no IPv4,
UDP, sockets API, apps, altcp, DHCP, DNS, MLD or ARP.

## Local changes to upstream files

**None.** `src/` is byte-identical to the commit above. The two behaviours
§2.4 expected to need patches live in the port layer instead, because lwIP
leaves both seams public:

1. **Writing a pbuf to BPF** — `netif->linkoutput` is ours
   (`port/pdlwip.c`, `pdl_linkoutput`): it flattens the frame and writes it in
   one `write(2)`, which is what BPF requires.
2. **The static neighbour entry** — `netif->output_ip6` is ours
   (`port/pdlwip.c`, `pdl_output_ip6`): for the peer the session reported it
   writes the frame with the peer's MAC directly, and every other destination
   falls through to upstream `ethip6_output`/`nd6`.

## The port layer (ours, not upstream)

- `port/lwipopts.h` — the options §2.4 lists (`LWIP_IPV6=1`, `LWIP_IPV4=0`,
  `LWIP_TCP=1`, `LWIP_UDP=0`, `LWIP_ICMP=0`, `LWIP_ICMP6=1`, `LWIP_ND6=1`,
  `LWIP_DHCP=0`, `LWIP_SOCKET=0`, `LWIP_NETCONN=0`, `TCP_MSS=1400`,
  `MEM_SIZE` 512 KiB per path, `MEMP_NUM_TCP_PCB` 8, `LWIP_TCP_SACK_OUT=0`)
  plus the buffer sizes that make one 8 Mbit/s connection fit.
- `port/arch/cc.h` — the Darwin types and the log sink.
- `port/pdlwip.c`, `port/pd_stack.h` — the netif, the static peer, the NA and
  the TCP pcb callbacks Swift uses.
- `port/pdlbpf.c`, `port/pd_bpf.h` — `/dev/bpf*` open/read/write and
  `getifaddrs` helpers.
- `include/PDLWIP.h` — the umbrella header Swift imports.
