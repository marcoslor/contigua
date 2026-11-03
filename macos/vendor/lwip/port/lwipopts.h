/* lwIP options for the direct-link helper (docs/design/direct-link.md §2.4).
 *
 * One stack, one thread: NO_SYS=1 with the daemon's kevent loop as the only
 * owner. IPv6 only, TCP only; no sockets API, no DHCP, no IPv4.
 */
#ifndef PD_LWIPOPTS_H
#define PD_LWIPOPTS_H

#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0

#define LWIP_IPV6 1
#define LWIP_IPV6_SCOPES 0
#define LWIP_IPV4 0
#define LWIP_ETHERNET 1
#define LWIP_TCP 1
#define LWIP_UDP 0
#define LWIP_RAW 0
#define LWIP_ICMP 0
#define LWIP_ICMP6 1
#define LWIP_ND6 1
#define LWIP_IPV6_MLD 0
#define LWIP_IPV6_AUTOCONFIG 0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS 0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT 0
#define LWIP_IPV6_FRAG 0
#define IPV6_FRAG_COPYHEADER 1
#define LWIP_DHCP 0
#define LWIP_DHCP6 0
#define LWIP_AUTOIP 0
#define LWIP_SOCKET 0
#define LWIP_NETCONN 0
#define LWIP_DNS 0
#define LWIP_NETIF_HOSTNAME 0
#define LWIP_NETIF_STATUS_CALLBACK 0
#define LWIP_NETIF_LINK_CALLBACK 0
#define LWIP_NETIF_EXT_STATUS_CALLBACK 0
/* The boot harness reads these counters (link/IPv6/ND/TCP/heap) on SIGTERM.
 * 16-bit counters wrap inside one 30 s benchmark (boot 7: tcp xmit=627), so
 * keep them 32-bit. */
#define LWIP_STATS 1
#define LWIP_STATS_LARGE 1
#define LWIP_DEBUG 0
#define LWIP_TCP_SACK_OUT 0
#define LWIP_TCP_TIMESTAMPS 0
#define LWIP_WND_SCALE 0
#define TCP_MSS 1400
#define TCP_WND 65535
/* Without window scaling lwIP's tcpwnd_size_t is u16_t, so 64 KiB becomes 0
 * and tcp_sndbuf() reports no room: the helper accepted the handshake and
 * never wrote a byte. One less than 64 KiB is the largest that fits. */
#define TCP_SND_BUF 65535
#define TCP_SND_QUEUELEN 188
#define MEMP_NUM_TCP_PCB 8
#define MEMP_NUM_TCP_SEG 192
#define MEM_SIZE (512 * 1024)
#define PBUF_POOL_SIZE 160
#define PBUF_POOL_BUFSIZE 1600
#define MEMP_NUM_PBUF 32
#define MEMP_NUM_SYS_TIMEOUT 16
#define MEMP_NUM_ND6_QUEUE 32
#define ND6_QUEUEING 1
#define LWIP_ND6_NUM_NEIGHBORS 8
#define LWIP_ND6_NUM_DESTINATIONS 8
#define LWIP_ND6_NUM_PREFIXES 4
#define LWIP_ND6_NUM_ROUTERS 1
#define LWIP_ND6_ALLOW_RA_UPDATES 0
#define LWIP_ND6_TCP_REACHABILITY_HINTS 0
#define LWIP_CHKSUM_ALGORITHM 3
#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS 1
#define LWIP_RAND() ((u32_t)arc4random())
#define LWIP_PLATFORM_DIAG(x) do { pdl_diag x; } while (0)
#define LWIP_PLATFORM_ASSERT(x) do { pdl_diag("assert: %s\n", x); abort(); } while (0)

#endif /* PD_LWIPOPTS_H */
