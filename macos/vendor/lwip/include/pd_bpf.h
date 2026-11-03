/* BPF and interface plumbing for the direct-link helper
 * (docs/design/direct-link.md §2.3). Kept in C: the ioctl shapes and the
 * bpf_hdr chain are C structures, not Swift ones.
 */
#ifndef PDLBPF_H
#define PDLBPF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opens an exclusive BPF descriptor for `ifname` with the options §2.3 lists
 * (immediate, no header completion, 200 ms read timeout, 256 KiB buffer).
 * Brute-forces /dev/bpf0..63. Returns -1 when none could be bound. */
int pdl_bpf_open(const char *ifname);

/* One BPF read: calls `cb` once per frame in the buffer. Returns the number of
 * frames, 0 when nothing arrived (timeout/EAGAIN), -1 on error. */
typedef void (*pdl_frame_cb)(void *ctx, const uint8_t *frame, size_t len);
int pdl_bpf_read(int fd, pdl_frame_cb cb, void *ctx);

/* One frame, header included, in one write(2). Returns 0 or -1. */
int pdl_bpf_write(int fd, const uint8_t *frame, size_t len);

/* The interface's Ethernet address. Returns 0 on success. */
int pdl_if_mac(const char *ifname, uint8_t mac[6]);

/* The interface's first kernel link-local (16 bytes). Returns 0 on success. */
int pdl_if_linklocal(const char *ifname, uint8_t ll[16]);

#ifdef __cplusplus
}
#endif

#endif /* PDLBPF_H */
