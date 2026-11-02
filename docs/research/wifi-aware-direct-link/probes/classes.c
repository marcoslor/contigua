#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdlib.h>
int main(void) {
    const char *imgs[] = {"/System/Library/Frameworks/WiFiAware.framework/Versions/A/WiFiAware", "/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer"};
    for (int k = 0; k < 2; k++) {
        if (!dlopen(imgs[k], RTLD_NOW)) { printf("dlopen fail %s\n", imgs[k]); continue; }
        unsigned n = 0; const char **c = objc_copyClassNamesForImage(imgs[k], &n);
        printf("== %s: %u classes\n", imgs[k], n);
        for (unsigned i = 0; i < n; i++) printf("%s\n", c[i]);
        free(c);
    }
}
