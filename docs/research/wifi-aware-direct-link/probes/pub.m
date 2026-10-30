#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
@interface NSObject (P) - (id)initWithServiceName:(id)n; - (id)initWithConfiguration:(id)c; - (void)setDelegate:(id)d; - (void)start; - (void)stop; - (void)setAuthenticationType:(long)t; - (id)initWithServiceType:(long)t securityConfiguration:(id)c; - (id)initWithPMKList:(id)a passphraseList:(id)b; - (void)setDatapathConfiguration:(id)d; @end
@interface Spy : NSObject @end
@implementation Spy
- (BOOL)respondsToSelector:(SEL)s { const char *n = sel_getName(s); if (!strncmp(n, "publish", 7) || !strncmp(n, "subscri", 7)) return YES; return [super respondsToSelector:s]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    NSMethodSignature *m = [super methodSignatureForSelector:s]; if (m) return m;
    NSMutableString *t = [@"v@:" mutableCopy]; for (const char *c = sel_getName(s); *c; c++) if (*c == ':') [t appendString:@"@"];
    return [NSMethodSignature signatureWithObjCTypes:t.UTF8String];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSString *sel = NSStringFromSelector(inv.selector); NSMutableArray *a = [NSMutableArray array];
    for (NSUInteger i = 2; i < inv.methodSignature.numberOfArguments; i++) { void *p = NULL; [inv getArgument:&p atIndex:i];
        a[a.count] = ((uintptr_t)p > 0x100000) ? [NSString stringWithFormat:@"%@", (__bridge id)p] : [NSString stringWithFormat:@"%lu", (uintptr_t)p]; }
    printf("[%s] CB %s %s\n", [[NSDate date] description].UTF8String, sel.UTF8String, [[a componentsJoinedByString:@" | "] UTF8String]); fflush(stdout);
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer", RTLD_NOW);
        NSString *name = argc > 1 ? @(argv[1]) : @"_pdtest._tcp"; double secs = argc > 2 ? atof(argv[2]) : 60;
        id cfg = [[objc_getClass("WiFiAwarePublishConfiguration") alloc] initWithServiceName:name];
        if (argc > 3) [cfg setAuthenticationType:atol(argv[3])];
        if (argc > 4) {
            id sec = nil;
            if (argc > 5 && strcmp(argv[5], "-")) sec = [[objc_getClass("WiFiAwarePublishDatapathSecurityConfiguration") alloc] initWithPMKList:nil passphraseList:@[@(argv[5])]];
            id dp = [[objc_getClass("WiFiAwarePublishDatapathConfiguration") alloc] initWithServiceType:atol(argv[4]) securityConfiguration:sec];
            [cfg setDatapathConfiguration:dp];
        }
        id pub = [[objc_getClass("WiFiAwarePublisher") alloc] initWithConfiguration:cfg];
        Spy *spy = [Spy new]; [pub setDelegate:spy];
        printf("config %s\n", [[cfg description] UTF8String]);
        [pub start]; printf("started publish of %s for %.0fs\n", name.UTF8String, secs); fflush(stdout);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        [pub stop]; printf("stopped\n");
    }
}
