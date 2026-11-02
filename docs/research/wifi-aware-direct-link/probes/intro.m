#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
static void dump(const char *name) {
    Class c = objc_getClass(name); if (!c) { printf("== %s missing\n", name); return; }
    printf("== %s : %s\n", name, class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
    unsigned n; Method *m = class_copyMethodList(object_getClass(c), &n);
    for (unsigned i = 0; i < n; i++) printf("  + %s %s\n", sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]));
    m = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) printf("  - %s\n", sel_getName(method_getName(m[i])));
    objc_property_t *p = class_copyPropertyList(c, &n);
    for (unsigned i = 0; i < n; i++) printf("  @ %s %s\n", property_getName(p[i]), property_getAttributes(p[i]));
    unsigned pc; Protocol * __unsafe_unretained *pr = class_copyProtocolList(c, &pc);
    for (unsigned i = 0; i < pc; i++) printf("  <%s>\n", protocol_getName(pr[i]));
}
int main(int argc, char **argv) {
    dlopen("/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer", RTLD_NOW);
    for (int i = 1; i < argc; i++) dump(argv[i]);
}
