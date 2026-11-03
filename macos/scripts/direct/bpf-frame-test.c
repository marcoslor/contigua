/* One maximum-size frame each way through BPF on a pair of interfaces
 * (docs/design/direct-link.md §7.1). Runs in the VM guest as root:
 *
 *   bpf-frame-test feth0 feth1
 *
 * A is read through a BPF tap, B through another; a 1514-byte frame written
 * with B's BPF must come out of A's, and the reverse. Exits 0 only when both
 * arrived intact. The type is 0x88B5 (local experimental), so nothing else on
 * the link can be mistaken for it.
 */
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define FRAME_LEN 1514
#define PAYLOAD_LEN (FRAME_LEN - 14)
#define TYPE_HI 0x88
#define TYPE_LO 0xb5

static int open_bpf(const char *name)
{
    int i;
    for (i = 0; i < 64; i++) {
        char path[32];
        struct ifreq ifr;
        unsigned int value;
        struct timeval tv;
        int fd;
        snprintf(path, sizeof path, "/dev/bpf%d", i);
        fd = open(path, O_RDWR);
        if (fd < 0) {
            continue;
        }
        value = 1 << 18;
        if (ioctl(fd, BIOCSBLEN, &value) < 0) { close(fd); continue; }
        memset(&ifr, 0, sizeof ifr);
        strncpy(ifr.ifr_name, name, sizeof ifr.ifr_name - 1);
        if (ioctl(fd, BIOCSETIF, &ifr) < 0) { close(fd); continue; }
        value = 1;
        ioctl(fd, BIOCIMMEDIATE, &value);
        ioctl(fd, BIOCSHDRCMPLT, &value);
        value = 0;
        ioctl(fd, BIOCSSEESENT, &value);
        tv.tv_sec = 0;
        tv.tv_usec = 200000;
        ioctl(fd, BIOCSRTIMEOUT, &tv);
        return fd;
    }
    return -1;
}

static int read_mac(const char *name, unsigned char mac[6])
{
    struct ifaddrs *list = NULL, *item;
    int found = -1;
    if (getifaddrs(&list) != 0) { return -1; }
    for (item = list; item != NULL; item = item->ifa_next) {
        if (item->ifa_addr == NULL || item->ifa_addr->sa_family != AF_LINK) { continue; }
        if (strcmp(item->ifa_name, name) != 0) { continue; }
        {
            const struct sockaddr_dl *dl = (const struct sockaddr_dl *)item->ifa_addr;
            if (dl->sdl_alen == 6) {
                memcpy(mac, LLADDR(dl), 6);
                found = 0;
            }
        }
        break;
    }
    freeifaddrs(list);
    return found;
}

static void build(unsigned char *frame, const unsigned char dst[6],
                  const unsigned char src[6], const char *marker)
{
    int i;
    memcpy(frame, dst, 6);
    memcpy(frame + 6, src, 6);
    frame[12] = TYPE_HI;
    frame[13] = TYPE_LO;
    memcpy(frame + 14, marker, 8);
    for (i = 22; i < FRAME_LEN; i++) {
        frame[i] = (unsigned char)(i & 0xff);
    }
}

static int send_one(int fd, const unsigned char *frame)
{
    ssize_t wrote = write(fd, frame, FRAME_LEN);
    if (wrote != FRAME_LEN) {
        printf("write failed: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int receive_one(int fd, const char *marker, const unsigned char src[6])
{
    unsigned char buffer[1 << 18];
    int attempts;
    for (attempts = 0; attempts < 20; attempts++) {
        ssize_t got = read(fd, buffer, sizeof buffer);
        unsigned int offset = 0;
        if (got < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) { continue; }
            printf("read failed: %s\n", strerror(errno));
            return -1;
        }
        while (offset + sizeof(struct bpf_hdr) <= (unsigned int)got) {
            const struct bpf_hdr *header = (const struct bpf_hdr *)(buffer + offset);
            unsigned int at = offset + header->bh_hdrlen;
            if (header->bh_caplen == FRAME_LEN && at + FRAME_LEN <= (unsigned int)got) {
                const unsigned char *frame = buffer + at;
                if (frame[12] == TYPE_HI && frame[13] == TYPE_LO
                    && memcmp(frame + 6, src, 6) == 0
                    && memcmp(frame + 14, marker, 8) == 0) {
                    return 0;
                }
            }
            offset = (at + header->bh_caplen + 3u) & ~3u;
        }
    }
    printf("no frame matching %s\n", marker);
    return -1;
}

int main(int argc, char **argv)
{
    unsigned char mac_a[6], mac_b[6];
    unsigned char frame[FRAME_LEN];
    int bpf_a, bpf_b, failed = 0;

    if (argc != 3) {
        fprintf(stderr, "usage: bpf-frame-test <ifA> <ifB>\n");
        return 2;
    }
    if (read_mac(argv[1], mac_a) != 0 || read_mac(argv[2], mac_b) != 0) {
        printf("cannot read the MACs of %s and %s\n", argv[1], argv[2]);
        return 1;
    }
    bpf_a = open_bpf(argv[1]);
    bpf_b = open_bpf(argv[2]);
    if (bpf_a < 0 || bpf_b < 0) {
        printf("cannot open BPF on %s/%s\n", argv[1], argv[2]);
        return 1;
    }

    build(frame, mac_b, mac_a, "PDFRAME1");
    if (send_one(bpf_a, frame) != 0 || receive_one(bpf_b, "PDFRAME1", mac_a) != 0) {
        printf("bpf-frame %s->%s len=%d FAILED\n", argv[1], argv[2], FRAME_LEN);
        failed = 1;
    } else {
        printf("bpf-frame %s->%s len=%d ok\n", argv[1], argv[2], FRAME_LEN);
    }

    build(frame, mac_a, mac_b, "PDFRAME2");
    if (send_one(bpf_b, frame) != 0 || receive_one(bpf_a, "PDFRAME2", mac_b) != 0) {
        printf("bpf-frame %s->%s len=%d FAILED\n", argv[2], argv[1], FRAME_LEN);
        failed = 1;
    } else {
        printf("bpf-frame %s->%s len=%d ok\n", argv[2], argv[1], FRAME_LEN);
    }

    close(bpf_a);
    close(bpf_b);
    return failed;
}
