/* lwIP -> BPF netif, static peer neighbour, and the TCP pcb wrappers
 * (docs/design/direct-link.md §2.4). Single-threaded, NO_SYS.
 */
#include "pd_stack.h"

#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <time.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "lwip/init.h"
#include "lwip/ip6.h"
#include "lwip/ip6_addr.h"
#include "lwip/nd6.h"
#include "lwip/ethip6.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "netif/ethernet.h"

struct pdl {
    struct netif netif;
    int fd;
    uint8_t own_mac[6];
    uint8_t peer_mac[6];
    ip6_addr_t peer_addr;
    int peer_known;
};

struct pdl_conn {
    struct tcp_pcb *pcb;
    void *ctx;
    pdl_connected_cb connected_cb;
    pdl_recv_cb recv_cb;
    pdl_sent_cb sent_cb;
    pdl_err_cb err_cb;
    int connected;
    int dead;
    struct pdl_conn *next;
};

static int lwip_started;
static struct pdl_conn *conns;

/* lwIP's clock when NO_SYS=1: monotonic milliseconds. */
u32_t sys_now(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (u32_t)((uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u);
}

void pdl_diag(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static uint16_t checksum_add(uint32_t sum, const uint8_t *data, size_t len)
{
    size_t i;
    for (i = 0; i + 1 < len; i += 2) {
        sum += ((uint32_t)data[i] << 8) | data[i + 1];
    }
    if (i < len) {
        sum += (uint32_t)data[i] << 8;
    }
    return (uint16_t)sum;
}

static uint16_t checksum_fold(uint32_t sum)
{
    while (sum >> 16) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return (uint16_t)(~sum & 0xffff);
}

/* One frame, header included: BPF writes must be a single write() call. */
static err_t pdl_linkoutput(struct netif *netif, struct pbuf *p)
{
    struct pdl *s = netif->state;
    uint8_t frame[1514];
    if (p->tot_len > sizeof frame) {
        return ERR_BUF;
    }
    if (pbuf_copy_partial(p, frame, p->tot_len, 0) != p->tot_len) {
        return ERR_BUF;
    }
    ssize_t wrote = write(s->fd, frame, p->tot_len);
    if (wrote != (ssize_t)p->tot_len) {
        return ERR_IF;
    }
    return ERR_OK;
}

static err_t pdl_output_ip6(struct netif *netif, struct pbuf *q, const ip6_addr_t *addr)
{
    struct pdl *s = netif->state;
    if (s->peer_known && ip6_addr_cmp_zoneless(addr, &s->peer_addr)) {
        /* The static neighbour entry: no solicitation round trip. */
        const struct eth_addr src = {{s->own_mac[0], s->own_mac[1], s->own_mac[2],
                                      s->own_mac[3], s->own_mac[4], s->own_mac[5]}};
        const struct eth_addr dst = {{s->peer_mac[0], s->peer_mac[1], s->peer_mac[2],
                                      s->peer_mac[3], s->peer_mac[4], s->peer_mac[5]}};
        return ethernet_output(netif, q, &src, &dst, ETHTYPE_IPV6);
    }
    return ethip6_output(netif, q, addr);
}

static err_t pdl_netif_init(struct netif *netif)
{
    struct pdl *s = netif->state;
    netif->hwaddr_len = ETH_HWADDR_LEN;
    memcpy(netif->hwaddr, s->own_mac, ETH_HWADDR_LEN);
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_LINK_UP;
    netif->linkoutput = pdl_linkoutput;
    netif->output_ip6 = pdl_output_ip6;
    return ERR_OK;
}

/* One unsolicited neighbour advertisement for our address (RFC 4861 §4.4.1):
 * the peer's cache learns our MAC before its first packet needs it. */
static void send_unsolicited_na(struct pdl *s)
{
    uint8_t pkt[72];
    uint8_t icmp[32];
    uint32_t sum = 0;
    const uint8_t all_nodes[16] = {0xff, 0x02, 0, 0, 0, 0, 0, 0,
                                   0, 0, 0, 0, 0, 0, 0, 1};
    const uint8_t *own = (const uint8_t *)s->netif.ip6_addr[0].addr;
    struct pbuf *p;
    const struct eth_addr src = {{s->own_mac[0], s->own_mac[1], s->own_mac[2],
                                  s->own_mac[3], s->own_mac[4], s->own_mac[5]}};
    const struct eth_addr dst = {{0x33, 0x33, 0, 0, 0, 1}};

    memset(icmp, 0, sizeof icmp);
    icmp[0] = 136; /* neighbour advertisement */
    icmp[4] = 0x20; /* override */
    memcpy(icmp + 8, own, 16);
    icmp[24] = 2; /* target link-layer address */
    icmp[25] = 1;
    memcpy(icmp + 26, s->own_mac, 6);
    /* Pseudo header: src, dst, upper-layer length, next header. */
    sum = checksum_add(sum, own, 16);
    sum = checksum_add(sum, all_nodes, 16);
    sum += 32;
    sum += 58; /* ICMPv6 */
    sum = checksum_add(sum, icmp, sizeof icmp);
    icmp[2] = (uint8_t)(checksum_fold(sum) >> 8);
    icmp[3] = (uint8_t)(checksum_fold(sum) & 0xff);

    memset(pkt, 0, sizeof pkt);
    pkt[0] = 0x60;
    pkt[4] = 0;
    pkt[5] = 32;
    pkt[6] = 58;
    pkt[7] = 255;
    memcpy(pkt + 8, own, 16);
    memcpy(pkt + 24, all_nodes, 16);
    memcpy(pkt + 40, icmp, 32);

    p = pbuf_alloc(PBUF_IP, sizeof pkt, PBUF_RAM);
    if (p == NULL) {
        return;
    }
    memcpy(p->payload, pkt, sizeof pkt);
    (void)ethernet_output(&s->netif, p, &src, &dst, ETHTYPE_IPV6);
    pbuf_free(p);
}

pdl *pdl_new(int bpf_fd, const uint8_t own_mac[6])
{
    struct pdl *s;
    if (!lwip_started) {
        lwip_init();
        lwip_started = 1;
    }
    s = (struct pdl *)calloc(1, sizeof *s);
    if (s == NULL) {
        return NULL;
    }
    s->fd = bpf_fd;
    memcpy(s->own_mac, own_mac, 6);
    return s;
}

void pdl_free(pdl *s)
{
    if (s == NULL) {
        return;
    }
    if (netif_is_up(&s->netif)) {
        netif_set_down(&s->netif);
    }
    netif_remove(&s->netif);
    free(s);
}

int pdl_start(pdl *s, const uint8_t ll[16], int announce)
{
    ip6_addr_t addr;
    memcpy(addr.addr, ll, 16);
    if (netif_add_noaddr(&s->netif, s, pdl_netif_init, ethernet_input) == NULL) {
        return -1;
    }
    netif_ip6_addr_set(&s->netif, 0, &addr);
    netif_ip6_addr_set_state(&s->netif, 0, IP6_ADDR_PREFERRED);
    netif_set_link_up(&s->netif);
    netif_set_up(&s->netif);
    if (announce) {
        send_unsolicited_na(s);
    }
    return 0;
}

void pdl_set_peer(pdl *s, const uint8_t ll[16], const uint8_t mac[6])
{
    memcpy(s->peer_addr.addr, ll, 16);
    memcpy(s->peer_mac, mac, 6);
    s->peer_known = 1;
    nd6_clear_destination_cache();
}

void pdl_clear_peer(pdl *s)
{
    s->peer_known = 0;
}

void pdl_input(pdl *s, const uint8_t *frame, size_t len)
{
    struct pbuf *p;
    if (len < 14 || frame[12] != 0x86 || frame[13] != 0xdd) {
        return;
    }
    p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
    if (p == NULL) {
        return;
    }
    if (pbuf_take(p, frame, (u16_t)len) != ERR_OK) {
        pbuf_free(p);
        return;
    }
    if (s->netif.input(p, &s->netif) != ERR_OK) {
        pbuf_free(p);
    }
}

void pdl_poll(pdl *s)
{
    (void)s;
    sys_check_timeouts();
}

uint16_t pdl_mtu(void)
{
    return 1500;
}

/* --- connections ------------------------------------------------------- */

static struct pdl_conn *conn_for(void *arg)
{
    struct pdl_conn *c = (struct pdl_conn *)arg;
    return c != NULL && !c->dead ? c : NULL;
}

static void unlink_conn(struct pdl_conn *c)
{
    struct pdl_conn **slot = &conns;
    while (*slot != NULL) {
        if (*slot == c) {
            *slot = c->next;
            return;
        }
        slot = &(*slot)->next;
    }
}

static void conn_died(struct pdl_conn *c, int code)
{
    if (c->dead) {
        return;
    }
    c->dead = 1;
    c->pcb = NULL;
    unlink_conn(c);
    if (c->err_cb != NULL) {
        c->err_cb(c->ctx, code);
    }
}

static void on_error(void *arg, err_t err)
{
    struct pdl_conn *c = (struct pdl_conn *)arg;
    if (c == NULL) {
        return;
    }
    /* lwIP has already freed the pcb here. */
    conn_died(c, err == ERR_ABRT ? 0 : 1);
}

static err_t on_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    struct pdl_conn *c = conn_for(arg);
    (void)pcb;
    (void)len;
    if (c != NULL && c->sent_cb != NULL) {
        c->sent_cb(c->ctx, tcp_sndbuf(pcb));
    }
    return ERR_OK;
}

static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    struct pdl_conn *c = conn_for(arg);
    uint16_t took = 0;
    if (c == NULL) {
        if (p != NULL) {
            pbuf_free(p);
        }
        return ERR_OK;
    }
    if (err != ERR_OK) {
        if (p != NULL) {
            pbuf_free(p);
        }
        conn_died(c, 0);
        return ERR_OK;
    }
    if (p == NULL) {
        /* The peer sent FIN: the app sees EOF, the link is down. */
        tcp_arg(pcb, NULL);
        tcp_recv(pcb, NULL);
        tcp_sent(pcb, NULL);
        tcp_err(pcb, NULL);
        if (tcp_close(pcb) != ERR_OK) {
            tcp_abort(pcb);
        }
        conn_died(c, 0);
        return ERR_OK;
    }
    if (p->tot_len > 0 && c->recv_cb != NULL) {
        /* A linear copy: the callback writes it to the socket once. */
        uint8_t *flat = (uint8_t *)malloc(p->tot_len);
        if (flat != NULL) {
            pbuf_copy_partial(p, flat, p->tot_len, 0);
            took = c->recv_cb(c->ctx, flat, (uint16_t)p->tot_len);
            free(flat);
            if (took > p->tot_len) {
                took = p->tot_len;
            }
            /* Acknowledge only what the app took; the rest closes the window. */
            if (took > 0) {
                tcp_recved(pcb, took);
            }
        }
    }
    pbuf_free(p);
    return ERR_OK;
}

static err_t on_connected(void *arg, struct tcp_pcb *pcb, err_t err)
{
    struct pdl_conn *c = conn_for(arg);
    if (c == NULL) {
        return ERR_OK;
    }
    if (err != ERR_OK) {
        conn_died(c, 1);
        return ERR_OK;
    }
    c->connected = 1;
    tcp_arg(pcb, c);
    tcp_recv(pcb, on_recv);
    tcp_sent(pcb, on_sent);
    tcp_err(pcb, on_error);
    if (c->connected_cb != NULL) {
        c->connected_cb(c->ctx);
    }
    return ERR_OK;
}

pdl_conn *pdl_connect(pdl *s, const uint8_t peer_ll[16], uint16_t port,
                      void *ctx, pdl_connected_cb connected_cb, pdl_recv_cb recv_cb,
                      pdl_sent_cb sent_cb, pdl_err_cb err_cb)
{
    struct tcp_pcb *pcb;
    struct pdl_conn *c;
    ip_addr_t addr;
    err_t err;

    pcb = tcp_new_ip_type(IPADDR_TYPE_V6);
    if (pcb == NULL) {
        return NULL;
    }
    c = (struct pdl_conn *)calloc(1, sizeof *c);
    if (c == NULL) {
        tcp_abort(pcb);
        return NULL;
    }
    c->pcb = pcb;
    c->ctx = ctx;
    c->connected_cb = connected_cb;
    c->recv_cb = recv_cb;
    c->sent_cb = sent_cb;
    c->err_cb = err_cb;
    c->next = conns;
    conns = c;

    tcp_arg(pcb, c);
    tcp_err(pcb, on_error);
    tcp_sent(pcb, on_sent);
    ip6_addr_t peer;
    memcpy(peer.addr, peer_ll, 16);
    ip_addr_copy_from_ip6(addr, peer);
    err = tcp_connect(pcb, &addr, port, on_connected);
    if (err != ERR_OK) {
        c->pcb = NULL;
        c->dead = 1;
        unlink_conn(c);
        tcp_abort(pcb);
        if (err_cb != NULL) {
            err_cb(ctx, 1);
        }
        return NULL;
    }
    tcp_nagle_disable(pcb);
    return c;
}

uint16_t pdl_sndbuf(pdl_conn *c)
{
    if (c == NULL || c->pcb == NULL || c->dead) {
        return 0;
    }
    return tcp_sndbuf(c->pcb);
}

int pdl_write(pdl_conn *c, const uint8_t *data, size_t len, size_t *accepted)
{
    uint16_t room;
    err_t err;
    *accepted = 0;
    if (c == NULL || c->pcb == NULL || c->dead) {
        return -1;
    }
    room = tcp_sndbuf(c->pcb);
    if (len > room) {
        len = room;
    }
    if (len > 0xffff) {
        len = 0xffff;
    }
    if (len == 0) {
        return 0;
    }
    err = tcp_write(c->pcb, data, (u16_t)len, TCP_WRITE_FLAG_COPY);
    if (err != ERR_OK) {
        return err == ERR_MEM ? 0 : -1;
    }
    *accepted = len;
    return 0;
}

void pdl_output(pdl_conn *c)
{
    if (c != NULL && c->pcb != NULL && !c->dead) {
        (void)tcp_output(c->pcb);
    }
}

void pdl_rx_done(pdl_conn *c, uint16_t bytes)
{
    if (bytes > 0 && c != NULL && c->pcb != NULL && !c->dead) {
        tcp_recved(c->pcb, bytes);
    }
}

void pdl_close(pdl_conn *c)
{
    if (c == NULL || c->pcb == NULL || c->dead) {
        return;
    }
    tcp_arg(c->pcb, NULL);
    tcp_recv(c->pcb, NULL);
    tcp_sent(c->pcb, NULL);
    tcp_err(c->pcb, NULL);
    if (tcp_close(c->pcb) != ERR_OK) {
        tcp_abort(c->pcb);
    }
    c->pcb = NULL;
    c->dead = 1;
    unlink_conn(c);
}

void pdl_release(pdl_conn *c)
{
    if (c == NULL) {
        return;
    }
    unlink_conn(c);
    free(c);
}

int pdl_conn_alive(pdl_conn *c)
{
    return c != NULL && !c->dead && c->pcb != NULL;
}
