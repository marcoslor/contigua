// nanagent — netagent helper + BPF L3 probe for the Wi-Fi Aware link
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <net/if.h>
#include <net/bpf.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if_dl.h>
#include <uuid/uuid.h>
#include <time.h>
#include <stdarg.h>

#define SIOCAIFAGENTID _IOWR('i', 165, struct if_agentidreq)
#define SIOCDIFAGENTID _IOWR('i', 166, struct if_agentidreq)
#define SIOCGIFAGENTIDS _IOWR('i', 167, struct if_agentidsreq64)

struct if_agentidreq {
	char ifar_name[IFNAMSIZ];
	uuid_t ifar_uuid;
};

struct if_agentidsreq64 {
	char ifar_name[IFNAMSIZ];
	uint32_t ifar_count;
	uint32_t pad;
	uint64_t ifar_uuids;
};

static int open_if(void) {
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) perror("socket");
	return s;
}

static int cmd_list(const char *ifn) {
	int s = open_if(); if (s < 0) return 1;
	uuid_t uuids[32]; memset(uuids, 0, sizeof uuids);
	struct if_agentidsreq64 r; memset(&r, 0, sizeof r);
	strlcpy(r.ifar_name, ifn, IFNAMSIZ);
	r.ifar_count = 32;
	r.ifar_uuids = (uint64_t)(uintptr_t)uuids;
	if (ioctl(s, SIOCGIFAGENTIDS, &r) < 0) { perror("SIOCGIFAGENTIDS"); return 1; }
	printf("count=%u\n", r.ifar_count);
	char buf[64];
	for (uint32_t i = 0; i < r.ifar_count && i < 32; i++) {
		uuid_unparse_lower(uuids[i], buf);
		printf("%s\n", buf);
	}
	return 0;
}

static int cmd_agent(int add, const char *ifn, const char *uuidstr) {
	int s = open_if(); if (s < 0) return 1;
	struct if_agentidreq a; memset(&a, 0, sizeof a);
	strlcpy(a.ifar_name, ifn, IFNAMSIZ);
	if (uuid_parse(uuidstr, a.ifar_uuid)) { fprintf(stderr, "bad uuid\n"); return 2; }
	if (ioctl(s, add ? SIOCAIFAGENTID : SIOCDIFAGENTID, &a) < 0) { perror(add ? "add" : "del"); return 1; }
	printf("%s ok\n", add ? "add" : "del");
	return 0;
}

/* ---------- BPF L3 probe ---------- */

static uint32_t csum_add(uint32_t sum, const void *data, size_t len) {
	const uint16_t *p = (const uint16_t *)data;
	while (len > 1) { sum += *p++; len -= 2; }
	if (len) sum += *(const uint8_t *)p;
	return sum;
}
static uint16_t csum_fold(uint32_t sum) {
	while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
	return (uint16_t)~sum;
}

static int get_if_mac(const char *ifn, uint8_t mac[6]) {
	struct ifaddrs *ifa = NULL, *p;
	if (getifaddrs(&ifa)) return -1;
	int ok = -1;
	for (p = ifa; p; p = p->ifa_next) {
		if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
		if (strcmp(p->ifa_name, ifn)) continue;
		struct sockaddr_dl *sdl = (struct sockaddr_dl *)p->ifa_addr;
		if (sdl->sdl_alen == 6) { memcpy(mac, LLADDR(sdl), 6); ok = 0; break; }
	}
	freeifaddrs(ifa);
	return ok;
}
static int get_if_v6(const char *ifn, struct in6_addr *out) {
	struct ifaddrs *ifa = NULL, *p;
	if (getifaddrs(&ifa)) return -1;
	int ok = -1;
	for (p = ifa; p; p = p->ifa_next) {
		if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET6) continue;
		if (strcmp(p->ifa_name, ifn)) continue;
		struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)p->ifa_addr;
		if (IN6_IS_ADDR_LINKLOCAL(&s6->sin6_addr)) { *out = s6->sin6_addr; ok = 0; break; }
	}
	freeifaddrs(ifa);
	return ok;
}


static double now_s(void) {
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static size_t build_echo(uint8_t *pkt, const uint8_t *smac, const uint8_t *dmac,
    const struct in6_addr *s6, const struct in6_addr *d6, uint16_t seq, int payload_len) {
	uint8_t *e = pkt;
	memcpy(e, dmac, 6); memcpy(e + 6, smac, 6); e[12] = 0x86; e[13] = 0xdd;
	uint8_t *ip = e + 14;
	size_t icmp_len = 8 + payload_len;
	ip[0] = 0x60; ip[4] = (icmp_len >> 8) & 0xff; ip[5] = icmp_len & 0xff;
	ip[6] = 58; ip[7] = 255;
	memcpy(ip + 8, s6, 16); memcpy(ip + 24, d6, 16);
	uint8_t *ic = ip + 40;
	memset(ic, 0, icmp_len);
	ic[0] = 128; ic[1] = 0;
	ic[4] = 0x12; ic[5] = 0x34; ic[6] = (seq >> 8) & 0xff; ic[7] = seq & 0xff;
	for (int i = 0; i < payload_len; i++) ic[8 + i] = (uint8_t)(i + seq);
	uint32_t sum = 0;
	sum = csum_add(sum, s6, 16); sum = csum_add(sum, d6, 16);
	uint32_t phlen = htonl((uint32_t)icmp_len);
	sum = csum_add(sum, &phlen, 4);
	uint8_t ph[4] = { 0, 0, 0, 58 }; sum = csum_add(sum, ph, 4);
	sum = csum_add(sum, ic, icmp_len);
	uint16_t ck = csum_fold(sum);
	ic[2] = ck & 0xff; ic[3] = (ck >> 8) & 0xff;
	return 14 + 40 + icmp_len;
}


static void log_line(FILE *lg, const char *fmt, ...) {
	if (!lg) return;
	struct timespec rt; clock_gettime(CLOCK_REALTIME, &rt);
	struct tm tm; localtime_r(&rt.tv_sec, &tm);
	char ts[32]; strftime(ts, sizeof ts, "%H:%M:%S", &tm);
	fprintf(lg, "%s.%03ld ", ts, (long)(rt.tv_nsec / 1000000));
	va_list ap; va_start(ap, fmt); vfprintf(lg, fmt, ap); va_end(ap);
	fputc('\n', lg);
}

static int cmd_stream(const char *ifn, const char *peer_ip, const char *peer_mac,
    int secs, int pps, int payload_len, const char *csvpath, int verbose, const char *logpath) {
	uint8_t smac[6], dmac[6];
	struct in6_addr s6, d6;
	if (get_if_mac(ifn, smac)) { fprintf(stderr, "no mac\n"); return 1; }
	if (get_if_v6(ifn, &s6)) { fprintf(stderr, "no v6\n"); return 1; }
	if (inet_pton(AF_INET6, peer_ip, &d6) != 1) { fprintf(stderr, "bad ip\n"); return 1; }
	unsigned m[6];
	if (sscanf(peer_mac, "%x:%x:%x:%x:%x:%x", &m[0],&m[1],&m[2],&m[3],&m[4],&m[5]) != 6) return 1;
	for (int i = 0; i < 6; i++) dmac[i] = (uint8_t)m[i];

	char path[32]; int fd = -1;
	for (int i = 0; i < 64; i++) { snprintf(path, sizeof path, "/dev/bpf%d", i); fd = open(path, O_RDWR); if (fd >= 0) break; }
	if (fd < 0) { perror("open /dev/bpf"); return 1; }
	struct ifreq ifr; memset(&ifr, 0, sizeof ifr);
	strlcpy(ifr.ifr_name, ifn, IFNAMSIZ);
	if (ioctl(fd, BIOCSETIF, &ifr) < 0) { perror("BIOCSETIF"); return 1; }
	int one = 1; ioctl(fd, BIOCIMMEDIATE, &one); ioctl(fd, BIOCSHDRCMPLT, &one);
	struct timeval tv0 = { 0, 0 }; ioctl(fd, BIOCSRTIMEOUT, &tv0);

	FILE *lg = NULL;
	if (verbose && logpath) { lg = fopen(logpath, "a"); if (lg) setvbuf(lg, NULL, _IOLBF, 0); }
	#define LOGF(...) do { if (lg) { fprintf(lg, __VA_ARGS__); } } while (0)
	int count = secs * pps;
	double *tx = calloc(count, sizeof(double));
	double *rtt = malloc(count * sizeof(double));
	for (int i = 0; i < count; i++) rtt[i] = -1;
	int got = 0;
	double t0 = now_s();
	uint8_t pkt[2048], buf[4096];

	for (int i = 0; i < count; i++) {
		double due = t0 + (double)i / pps;
		double w = due - now_s();
		if (w > 0) usleep((useconds_t)(w * 1e6));
		size_t len = build_echo(pkt, smac, dmac, &s6, &d6, (uint16_t)i, payload_len);
		if (write(fd, pkt, len) < 0) { perror("write"); break; }
		tx[i] = now_s();
		if (lg) log_line(lg, "TX seq=%d len=%zu", i, len);
		/* drain replies without blocking */
		for (;;) {
			fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
			struct timeval z = { 0, 0 };
			if (select(fd + 1, &rf, NULL, NULL, &z) <= 0) break;
			ssize_t n = read(fd, buf, sizeof buf);
			if (n <= 0) break;
			ssize_t off = 0;
			while (off + (ssize_t)sizeof(struct bpf_hdr) <= n) {
				struct bpf_hdr *bh = (struct bpf_hdr *)(buf + off);
				uint8_t *fr = buf + off + bh->bh_hdrlen;
				size_t fl = bh->bh_caplen;
				if (fl > 54 && fr[12] == 0x86 && fr[13] == 0xdd) {
					uint8_t *ip6 = fr + 14;
					if (ip6[6] == 58 && ip6[40] == 129) {
						uint16_t sq = (ip6[46] << 8) | ip6[47];
						if (sq < count && rtt[sq] < 0) {
							rtt[sq] = (now_s() - tx[sq]) * 1000.0;
							got++;
							if (lg) log_line(lg, "RX seq=%d rtt=%.1fms", sq, rtt[sq]);
						}
					}
				}
				off += BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
			}
		}
		if (lg && (i + 1) % pps == 0) {
			int last = i - pps + 1, rx = 0, kk = 0; double sum = 0;
			for (int j = last; j <= i; j++) if (rtt[j] >= 0) { rx++; sum += rtt[j]; kk++; }
			log_line(lg, "---- 1s: tx=%d rx=%d loss=%.0f%% avg=%.1fms ----", pps, rx, 100.0 * (pps - rx) / pps, kk ? sum / kk : 0.0);
		}
	}
	/* final drain */
	double end = now_s() + 1.0;
	while (now_s() < end) {
		fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
		struct timeval z = { 0, 1 };
		if (select(fd + 1, &rf, NULL, NULL, &z) <= 0) continue;
		ssize_t n = read(fd, buf, sizeof buf);
		if (n <= 0) continue;
		ssize_t off = 0;
		while (off + (ssize_t)sizeof(struct bpf_hdr) <= n) {
			struct bpf_hdr *bh = (struct bpf_hdr *)(buf + off);
			uint8_t *fr = buf + off + bh->bh_hdrlen;
			size_t fl = bh->bh_caplen;
			if (fl > 54 && fr[12] == 0x86 && fr[13] == 0xdd) {
				uint8_t *ip6 = fr + 14;
				if (ip6[6] == 58 && ip6[40] == 129) {
					uint16_t sq = (ip6[46] << 8) | ip6[47];
					if (sq < count && rtt[sq] < 0) { rtt[sq] = (now_s() - tx[sq]) * 1000.0; got++; }
				}
			}
			off += BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
		}
	}

	FILE *csv = fopen(csvpath, "w");
	if (csv) { fprintf(csv, "seq,rtt_ms\n"); for (int i = 0; i < count; i++) if (rtt[i] >= 0) fprintf(csv, "%d,%.3f\n", i, rtt[i]); fclose(csv); }

	double *vals = malloc(got * sizeof(double)); int k = 0;
	for (int i = 0; i < count; i++) if (rtt[i] >= 0) vals[k++] = rtt[i];
	for (int i = 0; i < k; i++) for (int j = i + 1; j < k; j++) if (vals[j] < vals[i]) { double t = vals[i]; vals[i] = vals[j]; vals[j] = t; }
	printf("sent=%d got=%d loss=%.1f%%", count, got, 100.0 * (count - got) / count);
	if (k) printf(" rtt_ms p50=%.2f p95=%.2f max=%.2f", vals[k/2], vals[(int)(k*0.95)], vals[k-1]);
	printf(" payload=%dB pps=%d dur=%ds\n", payload_len, pps, secs);
	free(vals); free(tx); free(rtt);
	return got > 0 ? 0 : 3;
}




static int cmd_setip(const char *ifn, const char *cidr) {
	char ip[64]; strlcpy(ip, cidr, sizeof ip);
	char *slash = strchr(ip, '/');
	int prefix = 24;
	if (slash) { *slash = 0; prefix = atoi(slash + 1); }
	uint32_t mask = prefix ? (uint32_t)(0xffffffffUL << (32 - prefix)) : 0;
	struct in_addr m; m.s_addr = htonl(mask);
	char mbuf[32]; inet_ntop(AF_INET, &m, mbuf, sizeof mbuf);
	char cmd[256];
	snprintf(cmd, sizeof cmd, "/sbin/ifconfig %s inet %s netmask %s", ifn, ip, mbuf);
	printf("%s\n", cmd); fflush(stdout);
	return system(cmd);
}


static int cmd_delip(const char *ifn, const char *ip) {
	char cmd[192];
	snprintf(cmd, sizeof cmd, "/sbin/ifconfig %s -alias %s", ifn, ip);
	printf("%s\n", cmd); fflush(stdout);
	return system(cmd);
}


static int cmd_manual(const char *ifn, const char *ip, const char *mask) {
	char cmd[192];
	snprintf(cmd, sizeof cmd, "/usr/sbin/ipconfig set %s MANUAL %s %s", ifn, ip, mask);
	printf("%s\n", cmd); fflush(stdout);
	return system(cmd);
}

static int cmd_dhcp(const char *ifn) {
	char cmd[128];
	snprintf(cmd, sizeof cmd, "/usr/sbin/ipconfig set %s DHCP", ifn);
	printf("%s\n", cmd); fflush(stdout);
	return system(cmd);
}

static int cmd_block(const char *ifn, int secs) {
	const char *conf = "/tmp/nan-block.conf";
	FILE *f = fopen(conf, "w");
	if (!f) { perror("conf"); return 1; }
	fprintf(f, "block drop quick on %s all\npass all\n", ifn);
	fclose(f);
	system("/sbin/pfctl -e >/dev/null 2>&1");
	char cmd[256]; snprintf(cmd, sizeof cmd, "/sbin/pfctl -f %s", conf);
	if (system(cmd) != 0) { fprintf(stderr, "pfctl load failed\n"); return 1; }
	printf("blocking %s for %ds\n", ifn, secs); fflush(stdout);
	sleep(secs);
	system("/sbin/pfctl -d >/dev/null 2>&1");
	printf("unblocked\n");
	return 0;
}

static int cmd_link(const char *ifn, int up) {
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) { perror("socket"); return 1; }
	struct ifreq ifr; memset(&ifr, 0, sizeof ifr);
	strlcpy(ifr.ifr_name, ifn, IFNAMSIZ);
	if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) { perror("SIOCGIFFLAGS"); return 1; }
	if (up) ifr.ifr_flags |= IFF_UP; else ifr.ifr_flags &= ~IFF_UP;
	if (ioctl(s, SIOCSIFFLAGS, &ifr) < 0) { perror("SIOCSIFFLAGS"); return 1; }
	printf("%s %s\n", ifn, up ? "up" : "down");
	return 0;
}

static int cmd_ping(const char *ifn, const char *peer_ip, const char *peer_mac) {
	uint8_t smac[6], dmac[6];
	struct in6_addr s6, d6;
	if (get_if_mac(ifn, smac)) { fprintf(stderr, "no mac for %s\n", ifn); return 1; }
	if (get_if_v6(ifn, &s6)) { fprintf(stderr, "no link-local v6 for %s\n", ifn); return 1; }
	if (inet_pton(AF_INET6, peer_ip, &d6) != 1) { fprintf(stderr, "bad peer ip\n"); return 1; }
	unsigned m[6];
	if (sscanf(peer_mac, "%x:%x:%x:%x:%x:%x", &m[0],&m[1],&m[2],&m[3],&m[4],&m[5]) != 6) { fprintf(stderr, "bad peer mac\n"); return 1; }
	for (int i = 0; i < 6; i++) dmac[i] = (uint8_t)m[i];

	char path[32]; int fd = -1;
	for (int i = 0; i < 64; i++) {
		snprintf(path, sizeof path, "/dev/bpf%d", i);
		fd = open(path, O_RDWR);
		if (fd >= 0) break;
	}
	if (fd < 0) { perror("open /dev/bpf"); return 1; }

	struct ifreq ifr; memset(&ifr, 0, sizeof ifr);
	strlcpy(ifr.ifr_name, ifn, IFNAMSIZ);
	if (ioctl(fd, BIOCSETIF, &ifr) < 0) { perror("BIOCSETIF"); return 1; }
	int one = 1;
	ioctl(fd, BIOCIMMEDIATE, &one);
	ioctl(fd, BIOCSHDRCMPLT, &one);   /* we supply the ethernet header */
	struct timeval tv = { 2, 0 };
	ioctl(fd, BIOCSRTIMEOUT, &tv);

	/* build: ethernet + ipv6 + icmp6 echo request */
	uint8_t pkt[128]; memset(pkt, 0, sizeof pkt);
	uint8_t *e = pkt;
	memcpy(e, dmac, 6); memcpy(e + 6, smac, 6); e[12] = 0x86; e[13] = 0xdd;
	uint8_t *ip = e + 14;
	const char *payload = "contigua-aware";
	size_t plen = strlen(payload);
	size_t icmp_len = 8 + plen;
	ip[0] = 0x60; ip[4] = (icmp_len >> 8) & 0xff; ip[5] = icmp_len & 0xff;
	ip[6] = 58; ip[7] = 255;
	memcpy(ip + 8, &s6, 16); memcpy(ip + 24, &d6, 16);
	uint8_t *ic = ip + 40;
	ic[0] = 128; ic[1] = 0;
	ic[4] = 0x12; ic[5] = 0x34; ic[6] = 0; ic[7] = 1;
	memcpy(ic + 8, payload, plen);
	/* icmp6 checksum with pseudo-header */
	uint32_t sum = 0;
	sum = csum_add(sum, &s6, 16);
	sum = csum_add(sum, &d6, 16);
	uint32_t phlen = htonl((uint32_t)icmp_len);
	sum = csum_add(sum, &phlen, 4);
	uint8_t ph[4] = { 0, 0, 0, 58 };
	sum = csum_add(sum, ph, 4);
	ic[2] = ic[3] = 0;
	sum = csum_add(sum, ic, icmp_len);
	uint16_t ck = csum_fold(sum);
	ic[2] = ck & 0xff; ic[3] = (ck >> 8) & 0xff;

	size_t total = 14 + 40 + icmp_len;
	ssize_t w = write(fd, pkt, total);
	if (w < 0) { perror("bpf write"); return 1; }
	printf("TX %zd bytes icmp6 echo -> %s (%s)\n", w, peer_ip, peer_mac);

	/* read replies */
	uint8_t buf[4096];
	int replies = 0;
	for (int loop = 0; loop < 6; loop++) {
		fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
		struct timeval t2 = { 1, 0 };
		int r = select(fd + 1, &rf, NULL, NULL, &t2);
		if (r <= 0) continue;
		ssize_t n = read(fd, buf, sizeof buf);
		if (n <= 0) continue;
		ssize_t off = 0;
		while (off + (ssize_t)sizeof(struct bpf_hdr) <= n) {
			struct bpf_hdr *bh = (struct bpf_hdr *)(buf + off);
			uint8_t *frame = buf + off + bh->bh_hdrlen;
			size_t flen = bh->bh_caplen;
			if (flen > 54 && frame[12] == 0x86 && frame[13] == 0xdd) {
				uint8_t *ip6 = frame + 14;
				uint8_t nh = ip6[6];
				uint8_t *l4 = ip6 + 40;
				if (nh == 58 && l4[0] == 129) {
					char src[INET6_ADDRSTRLEN] = "?";
					inet_ntop(AF_INET6, ip6 + 8, src, sizeof src);
					printf("RX %zu bytes icmp6 echo reply src=%02x:%02x:%02x:%02x:%02x:%02x ip=%s\n",
					    flen, frame[6], frame[7], frame[8], frame[9], frame[10], frame[11], src);
					replies++;
				} else if (nh == 58) {
					printf("RX icmp6 type=%u\n", l4[0]);
				}
			}
			off += BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
		}
		if (replies) break;
	}
	printf("replies=%d\n", replies);
	return replies ? 0 : 3;
}

int main(int argc, char **argv) {
	if (argc < 3) {
		fprintf(stderr, "usage: %s list|del|add <ifname> [uuid] | ping <ifname> <peer-ipv6> <peer-mac>\n", argv[0]);
		return 2;
	}
	const char *cmd = argv[1], *ifn = argv[2];
	if (!strcmp(cmd, "list")) return cmd_list(ifn);
	if (!strcmp(cmd, "add") && argc >= 4) return cmd_agent(1, ifn, argv[3]);
	if (!strcmp(cmd, "del") && argc >= 4) return cmd_agent(0, ifn, argv[3]);
	if (!strcmp(cmd, "ping") && argc >= 5) return cmd_ping(ifn, argv[3], argv[4]);
	if (!strcmp(cmd, "stream") && argc >= 8) return cmd_stream(ifn, argv[3], argv[4], atoi(argv[5]), atoi(argv[6]), atoi(argv[7]), argc >= 9 ? argv[8] : "/tmp/nanstream.csv", 0, NULL);
	if (!strcmp(cmd, "log") && argc >= 8) return cmd_stream(ifn, argv[3], argv[4], atoi(argv[5]), atoi(argv[6]), atoi(argv[7]), "/tmp/nan-log.csv", 1, argc >= 9 ? argv[8] : "/tmp/nan-link.log");
	if (!strcmp(cmd, "link") && argc >= 4) return cmd_link(ifn, !strcmp(argv[3], "up"));
	if (!strcmp(cmd, "block") && argc >= 4) return cmd_block(ifn, atoi(argv[3]));
	if (!strcmp(cmd, "setip") && argc >= 4) return cmd_setip(ifn, argv[3]);
	if (!strcmp(cmd, "dhcp") && argc >= 3) return cmd_dhcp(ifn);
	if (!strcmp(cmd, "manual") && argc >= 5) return cmd_manual(ifn, argv[3], argv[4]);
	if (!strcmp(cmd, "delip") && argc >= 4) return cmd_delip(ifn, argv[3]);
	fprintf(stderr, "bad args\n");
	return 2;
}
