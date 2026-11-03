/* The C side of the direct-link helper: lwIP on one BPF descriptor
 * (docs/design/direct-link.md §2.1, §2.4).
 *
 * Single-threaded. The Swift daemon owns the event loop; this file owns the
 * stack and the Ethernet frame plumbing. No locks.
 */
#ifndef PDLWIP_H
#define PDLWIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pdl pdl;
typedef struct pdl_conn pdl_conn;

/* Bytes the receive callback took; the rest stays unacknowledged, so lwIP's
 * window is the second half of the backpressure. */
typedef uint16_t (*pdl_recv_cb)(void *ctx, const uint8_t *data, uint16_t len);
typedef void (*pdl_sent_cb)(void *ctx, uint16_t free_bytes);
typedef void (*pdl_connected_cb)(void *ctx);
/* 0: the peer reset or the connection timed out (the pcb is gone).
 * 1: the connect failed. */
typedef void (*pdl_err_cb)(void *ctx, int code);

/* Opens the stack on one BPF descriptor. own_mac is the interface's hardware
 * address (frames are written with it). */
pdl *pdl_new(int bpf_fd, const uint8_t own_mac[6]);
void pdl_free(pdl *stack);

/* Brings the netif up with `ll` (16 bytes, unicast link-local) and, when
 * announce is non-zero, sends one unsolicited neighbour advertisement so the
 * peer can reach us without a solicitation round trip. Returns 0 on success. */
int pdl_start(pdl *stack, const uint8_t ll[16], int announce);

/* The peer's link-local and MAC: the static neighbour entry §2.4 asks for.
 * Frames to that address go straight out; everything else uses lwIP's nd6. */
void pdl_set_peer(pdl *stack, const uint8_t ll[16], const uint8_t mac[6]);
void pdl_clear_peer(pdl *stack);

/* One complete Ethernet frame (header included), as read from BPF. */
void pdl_input(pdl *stack, const uint8_t *frame, size_t len);

/* TCP/IP timers and the 200 ms tick of the daemon loop. */
void pdl_poll(pdl *stack);

/* Connects to peer_ll:port. Returns NULL when the pcb could not be allocated.
 * Callbacks run only inside pdl_input/pdl_poll/pdl_write/pdl_close, i.e. on
 * the daemon's own thread. */
pdl_conn *pdl_connect(pdl *stack, const uint8_t peer_ll[16], uint16_t port,
                      void *ctx, pdl_connected_cb connected_cb, pdl_recv_cb recv_cb,
                      pdl_sent_cb sent_cb, pdl_err_cb err_cb);

/* Pushes what tcp_write queued onto the wire (the daemon calls it after a
 * write and after every sent callback). */
void pdl_output(pdl_conn *conn);

/* Free send space in bytes (capped at 32 KiB by the caller anyway). */
uint16_t pdl_sndbuf(pdl_conn *conn);
/* Queues up to `len` bytes; accepted says how many the stack took. Returns 0,
 * or -1 when the connection is already gone. */
int pdl_write(pdl_conn *conn, const uint8_t *data, size_t len, size_t *accepted);
/* Acknowledges receive bytes the callback did not take earlier. */
void pdl_rx_done(pdl_conn *conn, uint16_t bytes);
/* Graceful close (FIN); the connection record stays valid until pdl_release. */
void pdl_close(pdl_conn *conn);
/* Frees the C record after close/error. Does not touch the pcb after an error
 * callback (lwIP already freed it). */
void pdl_release(pdl_conn *conn);
/* Non-zero while the conn is usable (connected and not closed/reset). */
int pdl_conn_alive(pdl_conn *conn);

/* The netif's MTU (1500). */
uint16_t pdl_mtu(void);

#ifdef __cplusplus
}
#endif

#endif /* PDLWIP_H */
