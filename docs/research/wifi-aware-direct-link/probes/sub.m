#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
@interface NSObject (P) - (id)initWithServiceName:(id)n; - (id)initWithConfiguration:(id)c; - (void)setDelegate:(id)d; - (void)start; - (void)stop; - (void)setAuthenticationType:(long)a;
- (id)initWithDiscoveryResult:(id)r serviceType:(long)t serviceSpecificInfo:(id)s; - (id)initWithDiscoveryResult:(id)r serviceType:(long)t serviceSpecificInfo:(id)s passphrase:(id)p; @end

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/time.h>
static double now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
static void *conn_main(void *arg) {
    int c = (int)(intptr_t)arg; char m; if (recv(c, &m, 1, MSG_WAITALL) != 1) { close(c); return NULL; }
    int one = 1; setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (m == 'E') { char b[64]; ssize_t n; while ((n = recv(c, b, sizeof b, 0)) > 0) send(c, b, n, 0); }
    else if (m == 'D') { static char b[1 << 16]; long long tot = 0; ssize_t n; double t0 = now();
        while ((n = recv(c, b, sizeof b, 0)) > 0) tot += n;
        char r[32]; int l = snprintf(r, sizeof r, "%lld", tot); send(c, r, l, 0);
        printf("server: discard %lld B in %.2fs\n", tot, now() - t0); fflush(stdout); }
    close(c); return NULL;
}
static void *server_main(void *arg) {
    int s = socket(AF_INET6, SOCK_STREAM, 0), one = 1, zero = 0;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(s, SOL_SOCKET, 0x1104 /* SO_RECV_ANYIF */, &one, sizeof one);
    setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
    struct sockaddr_in6 a = { .sin6_len = sizeof a, .sin6_family = AF_INET6, .sin6_port = htons(47999), .sin6_addr = in6addr_any };
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 8)) { perror("server"); return NULL; }
    printf("server: listening :47999 (in-process)\n"); fflush(stdout);
    for (;;) { struct sockaddr_in6 p; socklen_t pl = sizeof p; int c = accept(s, (struct sockaddr *)&p, &pl); if (c < 0) continue;
        printf("server: conn ifindex=%u\n", p.sin6_scope_id); fflush(stdout);
        pthread_t t; pthread_create(&t, NULL, conn_main, (void *)(intptr_t)c); pthread_detach(t); }
    return NULL;
}

#import <Network/Network.h>
static void nw_echo(nw_connection_t c) {
    nw_connection_receive(c, 1, 65536, ^(dispatch_data_t d, nw_content_context_t ctx, bool done, nw_error_t e) {
        if (d) nw_connection_send(c, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t se) {});
        if (!done && !e) nw_echo(c); else nw_connection_cancel(c);
    });
}
static void nw_discard(nw_connection_t c, long long tot, double t0) {
    nw_connection_receive(c, 1, 1 << 20, ^(dispatch_data_t d, nw_content_context_t ctx, bool done, nw_error_t e) {
        long long n = tot + (d ? (long long)dispatch_data_get_size(d) : 0);
        if (done || e) {
            char r[32]; int l = snprintf(r, sizeof r, "%lld", n);
            dispatch_data_t out = dispatch_data_create(r, l, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(c, out, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t se) { nw_connection_cancel(c); });
            printf("server: discard %lld B in %.2fs\n", n, now() - t0); fflush(stdout);
        } else nw_discard(c, n, t0);
    });
}
static nw_listener_t gListener;
static void nw_server_start(void) {
    nw_parameters_t p = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_include_peer_to_peer(p, true);
    nw_parameters_set_reuse_local_address(p, true);
    gListener = nw_listener_create_with_port("48111", p);
    dispatch_queue_t q = dispatch_queue_create("srv", DISPATCH_QUEUE_SERIAL);
    nw_listener_set_queue(gListener, q);
    nw_listener_set_state_changed_handler(gListener, ^(nw_listener_state_t s, nw_error_t e) { printf("server: listener state %d err=%d\n", s, e ? nw_error_get_error_code(e) : 0); fflush(stdout); });
    nw_listener_set_new_connection_handler(gListener, ^(nw_connection_t c) {
        nw_path_t path = nw_connection_copy_current_path(c);
        nw_connection_set_queue(c, q);
        nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t s, nw_error_t e) {
            if (s == nw_connection_state_ready) {
                nw_path_t pp = nw_connection_copy_current_path(c); NSMutableString *ifn = [NSMutableString stringWithString:@"?"];
                nw_path_enumerate_interfaces(pp, ^bool(nw_interface_t i) { [ifn setString:@(nw_interface_get_name(i))]; return false; });
                printf("server: conn ready on %s\n", ifn.UTF8String); fflush(stdout);
                nw_connection_receive(c, 1, 1, ^(dispatch_data_t d, nw_content_context_t ctx, bool done, nw_error_t e2) {
                    if (!d) { nw_connection_cancel(c); return; }
                    __block char m = 0; dispatch_data_apply(d, ^bool(dispatch_data_t r, size_t o, const void *b, size_t l) { m = ((const char *)b)[0]; return false; });
                    if (m == 'E') nw_echo(c); else if (m == 'D') nw_discard(c, 0, now()); else nw_connection_cancel(c);
                });
            }
        });
        (void)path;
        nw_connection_start(c);
    });
    nw_listener_start(gListener);
}
#include <netdb.h>
#include <net/if.h>
#include <errno.h>

static void bsd_bench(const char *addr) {
    struct addrinfo h = { .ai_family = AF_INET6, .ai_socktype = SOCK_STREAM }, *r = NULL;
    if (getaddrinfo(addr, "48112", &h, &r)) { printf("client: bad addr\n"); return; }
    double rtt[200]; int ok = 0;
    for (int attempt = 0; attempt < 5 && !ok; attempt++) {
        int s = socket(AF_INET6, SOCK_STREAM, 0), one = 1; unsigned idx = if_nametoindex("nan0");
        setsockopt(s, SOL_SOCKET, 0x1104, &one, sizeof one); setsockopt(s, IPPROTO_IPV6, 125 /* IPV6_BOUND_IF */, &idx, sizeof idx); setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        struct timeval tv = { 3, 0 }; setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv); setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        if (connect(s, r->ai_addr, r->ai_addrlen)) { printf("client: connect try %d failed errno=%d\n", attempt + 1, errno); fflush(stdout); close(s); sleep(1); continue; }
        ok = 1; char m = 'E', b[64] = {0}; send(s, &m, 1, 0); int n = 0;
        for (; n < 200; n++) { double t = now(); if (send(s, b, 64, 0) != 64) break; int got = 0; while (got < 64) { ssize_t x = recv(s, b + got, 64 - got, 0); if (x <= 0) break; got += x; } if (got < 64) break; rtt[n] = (now() - t) * 1000; }
        close(s);
        if (n < 200) { printf("client: echo stalled after %d round trips\n", n); fflush(stdout); break; }
        for (int i = 0; i < 200; i++) for (int j = i + 1; j < 200; j++) if (rtt[j] < rtt[i]) { double x = rtt[i]; rtt[i] = rtt[j]; rtt[j] = x; }
        printf("client: aware RTT ms p50=%.2f p95=%.2f max=%.2f\n", rtt[100], rtt[190], rtt[199]); fflush(stdout);
        s = socket(AF_INET6, SOCK_STREAM, 0); setsockopt(s, SOL_SOCKET, 0x1104, &one, sizeof one); setsockopt(s, IPPROTO_IPV6, 125, &idx, sizeof idx);
        struct timeval tv2 = { 10, 0 }; setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv2, sizeof tv2); setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv2, sizeof tv2);
        if (connect(s, r->ai_addr, r->ai_addrlen)) { printf("client: upload connect failed\n"); close(s); break; }
        m = 'D'; send(s, &m, 1, 0); static char big[1 << 16]; double t0 = now(); long long sent = 0;
        while (sent < 32LL << 20) { ssize_t x = send(s, big, sizeof big, 0); if (x <= 0) break; sent += x; }
        shutdown(s, SHUT_WR); char ack[32] = {0}; recv(s, ack, sizeof ack - 1, MSG_WAITALL); double secs = now() - t0;
        printf("client: aware Mac->phone %lld B in %.2fs = %.1f Mbit/s (phone got %s)\n", sent, secs, sent * 8 / secs / 1e6, ack); fflush(stdout); close(s);
    }
    freeaddrinfo(r);
}
static void *client_main(void *arg) {
    for (int i = 0; i < 60; i++) { FILE *f = fopen("/tmp/pd-peer.txt", "r"); if (f) { char a[128] = {0}; fgets(a, sizeof a, f); fclose(f); a[strcspn(a, "\r\n")] = 0;
        if (*a) { unlink("/tmp/pd-peer.txt"); printf("client: peer address received\n"); fflush(stdout); bsd_bench(a); return NULL; } } sleep(1); }
    return NULL;
}
static id gSession; static long gType = 1; static const char *gPsk = NULL;
@interface Spy : NSObject @property (copy) NSString *tag; @end
@implementation Spy
- (BOOL)respondsToSelector:(SEL)s { const char *n = sel_getName(s); if (!strncmp(n, "subscri", 7) || !strncmp(n, "dataSession", 11) || !strncmp(n, "datapath", 8)) return YES; return [super respondsToSelector:s]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    NSMethodSignature *m = [super methodSignatureForSelector:s]; if (m) return m;
    NSMutableString *t = [@"v@:" mutableCopy]; for (const char *c = sel_getName(s); *c; c++) if (*c == ':') [t appendString:@"@"];
    return [NSMethodSignature signatureWithObjCTypes:t.UTF8String];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSString *sel = NSStringFromSelector(inv.selector); NSMutableArray *a = [NSMutableArray array]; id result = nil;
    for (NSUInteger i = 2; i < inv.methodSignature.numberOfArguments; i++) { void *p = NULL; [inv getArgument:&p atIndex:i];
        if ((uintptr_t)p > 0x100000) { id o = (__bridge id)p; if ([o isKindOfClass:objc_getClass("WiFiAwareDiscoveryResult")]) result = o; a[a.count] = [NSString stringWithFormat:@"%@", o]; }
        else a[a.count] = [NSString stringWithFormat:@"%lu", (uintptr_t)p]; }
    printf("[%s] %s CB %s %s\n", [[NSDate date] description].UTF8String, self.tag.UTF8String, sel.UTF8String, [[a componentsJoinedByString:@" | "] UTF8String]); fflush(stdout);
    if (result && !gSession) {
        Class C = objc_getClass("WiFiAwareDataSession");
        gSession = gPsk ? [[C alloc] initWithDiscoveryResult:result serviceType:gType serviceSpecificInfo:nil passphrase:@(gPsk)]
                        : [[C alloc] initWithDiscoveryResult:result serviceType:gType serviceSpecificInfo:nil];
        Spy *ds = [Spy new]; ds.tag = @"data"; objc_setAssociatedObject(gSession, "spy", ds, OBJC_ASSOCIATION_RETAIN);
        [gSession setDelegate:ds]; printf("starting data session type=%ld psk=%s: %s\n", gType, gPsk ? "yes" : "no", [[gSession description] UTF8String]); fflush(stdout);
        [gSession start];
    }
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        nw_server_start(); unlink("/tmp/pd-peer.txt"); { pthread_t ct; pthread_create(&ct, NULL, client_main, NULL); }
        dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer", RTLD_NOW);
        NSString *name = argc > 1 ? @(argv[1]) : @"_pdtest._tcp"; double secs = argc > 2 ? atof(argv[2]) : 60;
        if (argc > 3) gType = atol(argv[3]); if (argc > 4 && strcmp(argv[4], "-")) gPsk = argv[4];
        id cfg = [[objc_getClass("WiFiAwareSubscribeConfiguration") alloc] initWithServiceName:name];
        [cfg setAuthenticationType:0];
        id sub = [[objc_getClass("WiFiAwareSubscriber") alloc] initWithConfiguration:cfg];
        Spy *spy = [Spy new]; spy.tag = @"sub"; [sub setDelegate:spy];
        [sub start]; printf("subscribing to %s for %.0fs\n", name.UTF8String, secs); fflush(stdout);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        [gSession stop]; [sub stop]; printf("stopped\n");
    }
}
