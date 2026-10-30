#include <stdio.h>
#include <stdbool.h>
extern bool _os_feature_enabled_impl(const char *domain, const char *feature);
int main(void) {
    const char *q[][2] = {{"WiFiP2P","AWDLDiscoveryTimeout"},{"WiFiP2P","WiFiAwareOnMacOS"},{"WiFiAware","WiFiAwareOnMacOS"},{"WiFiP2P","EphemeralPKBootstrapping"},{"WiFiAware","EphemeralPKBootstrapping"},{"WiFiP2P","NoSuchFlagXYZ"}};
    for (int i = 0; i < 6; i++) printf("%s/%s = %d\n", q[i][0], q[i][1], _os_feature_enabled_impl(q[i][0], q[i][1]));
}
