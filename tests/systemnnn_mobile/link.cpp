#include "systemnnn_runtime.h"

// The shared-library entry remains externally reachable on Android; the iOS
// executable main makes the same complete provider/dependency link mandatory.
extern "C" __attribute__((visibility("default")))
int aether_systemnnn_mobile_link_probe() {
    return static_cast<int>(aether_systemnnn_register_runtime());
}

#ifndef __ANDROID__
int main() {
    return aether_systemnnn_mobile_link_probe();
}
#endif
