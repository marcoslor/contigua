#include "pd_bpf.h"

#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/bpf.h>
#include <net/if.h>
#include <netinet/in.h>
#include <net/if_dl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#define PDL_BPF_BUFLEN (256 * 1024)
#define PDL_BPF_ALIGN (sizeof(int32_t))

static uint32_t align_word(uint32_t value)
{
    return (value + (uint32_t)(PDL_BPF_ALIGN - 1)) & ~(uint32_t)(PDL_BPF_ALIGN - 1);
}

int pdl_bpf_open(const char *ifname)
{
    int i;
    for (i = 0; i < 64; i++) {
        char path[32];
        struct ifreq ifr;
        uint32_t value;
        struct timeval tv;
        int fd;

        snprintf(path, sizeof path, "/dev/bpf%d", i);
        fd = open(path, O_RDWR);
        if (fd < 0) {
            continue;
        }
        value = PDL_BPF_BUFLEN;
        if (ioctl(fd, BIOCSBLEN, &value) < 0) {
            close(fd);
            continue;
        }
        memset(&ifr, 0, sizeof ifr);
        strncpy(ifr.ifr_name, ifname, sizeof ifr.ifr_name - 1);
        if (ioctl(fd, BIOCSETIF, &ifr) < 0) {
            close(fd);
            continue;
        }
        value = 1;
        (void)ioctl(fd, BIOCIMMEDIATE, &value);
        value = 1;
        (void)ioctl(fd, BIOCSHDRCMPLT, &value);
        value = 0; /* our own injected frames are not input */
        (void)ioctl(fd, BIOCSSEESENT, &value);
        tv.tv_sec = 0;
        tv.tv_usec = 200 * 1000;
        (void)ioctl(fd, BIOCSRTIMEOUT, &tv);
        return fd;
    }
    return -1;
}

int pdl_bpf_read(int fd, pdl_frame_cb cb, void *ctx)
{
    uint8_t buffer[PDL_BPF_BUFLEN];
    ssize_t got;
    uint32_t offset = 0;
    int frames = 0;

    got = read(fd, buffer, sizeof buffer);
    if (got < 0) {
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
    }
    if (got == 0) {
        return 0;
    }
    while (offset + sizeof(struct bpf_hdr) <= (uint32_t)got) {
        const struct bpf_hdr *header = (const struct bpf_hdr *)(buffer + offset);
        uint32_t frame_at = offset + header->bh_hdrlen;
        if (header->bh_caplen == 0 || frame_at + header->bh_caplen > (uint32_t)got) {
            break;
        }
        cb(ctx, buffer + frame_at, header->bh_caplen);
        frames++;
        offset = align_word(offset + header->bh_hdrlen + header->bh_caplen);
    }
    return frames;
}

int pdl_bpf_write(int fd, const uint8_t *frame, size_t len)
{
    ssize_t wrote = write(fd, frame, len);
    return wrote == (ssize_t)len ? 0 : -1;
}

int pdl_if_mac(const char *ifname, uint8_t mac[6])
{
    struct ifaddrs *list = NULL;
    struct ifaddrs *item;
    int found = -1;

    if (getifaddrs(&list) != 0) {
        return -1;
    }
    for (item = list; item != NULL; item = item->ifa_next) {
        if (item->ifa_addr == NULL || item->ifa_addr->sa_family != AF_LINK) {
            continue;
        }
        if (strcmp(item->ifa_name, ifname) != 0) {
            continue;
        }
        {
            const struct sockaddr_dl *link = (const struct sockaddr_dl *)item->ifa_addr;
            if (link->sdl_alen == 6) {
                memcpy(mac, LLADDR(link), 6);
                found = 0;
            }
        }
        break;
    }
    freeifaddrs(list);
    return found;
}

int pdl_if_linklocal(const char *ifname, uint8_t ll[16])
{
    struct ifaddrs *list = NULL;
    struct ifaddrs *item;
    int found = -1;

    if (getifaddrs(&list) != 0) {
        return -1;
    }
    for (item = list; item != NULL; item = item->ifa_next) {
        const struct sockaddr_in6 *addr;
        const uint8_t *bytes;
        if (item->ifa_addr == NULL || item->ifa_addr->sa_family != AF_INET6) {
            continue;
        }
        if (strcmp(item->ifa_name, ifname) != 0) {
            continue;
        }
        addr = (const struct sockaddr_in6 *)item->ifa_addr;
        bytes = addr->sin6_addr.s6_addr;
        if (IN6_IS_ADDR_LINKLOCAL((const struct in6_addr *)&addr->sin6_addr)) {
            memcpy(ll, bytes, 16);
            found = 0;
            break;
        }
    }
    freeifaddrs(list);
    return found;
}
