#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
int main(int argc, char **argv) {
    dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer", RTLD_NOW);
    for (int a = 1; a < argc; a++) {
        Protocol *p = objc_getProtocol(argv[a]); if (!p) { printf("no %s\n", argv[a]); continue; }
        printf("== %s\n", argv[a]);
        for (int req = 1; req >= 0; req--) { unsigned n; struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req, YES, &n);
            for (unsigned i = 0; i < n; i++) printf("  %s %s %s\n", req ? "req" : "opt", sel_getName(d[i].name), d[i].types); }
    }
}
