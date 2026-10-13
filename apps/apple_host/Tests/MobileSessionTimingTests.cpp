#include "SessionTiming.h"
#include <cassert>
#include <limits>
#include <iostream>
using namespace aether::mobile;
int main() {
    SessionTiming clock;
    assert(!clock.delta(1));
    clock.start();
    assert(clock.delta(10).value() == 0);
    uint32_t sum = 0;
    for (int i=1;i<=120;++i) sum += clock.delta(10 + i/120.0).value();
    assert(sum == 1000); // High refresh must advance one real second, not 120×16ms.
    clock.setReasons(sceneInactive | audioInterruption);
    assert(!clock.delta(500));
    clock.setReasons(audioInterruption); // Foreground cannot override interruption.
    assert(!clock.ticking());
    clock.setReasons(audioInterruption | systemModal);
    clock.setReasons(systemModal); // Ended interruption cannot override modal.
    assert(!clock.ticking());
    clock.setReasons(0);
    assert(clock.delta(1000).value() == 0); // Never catch up background time.
    assert(clock.delta(1000.016).value() == 16);
    assert(clock.delta(1005).value() == 100); // Bound a foreground stall.
    clock.setReasons(userResumeRequired | sceneInactive);
    clock.setReasons(sceneInactive); // User resume cannot override background.
    assert(!clock.ticking());
    clock.setReasons(0);
    assert(clock.delta(2000).value() == 0);
    assert(!clock.delta(std::numeric_limits<double>::quiet_NaN()));
    assert(clock.delta(2001).value() == 0);
    assert(clock.delta(1900).value() == 0); // Monotonic reset, no unsigned overflow.
    clock.stop(); assert(!clock.delta(3000));
    clock.start(); assert(clock.delta(4000).value() == 0);
    std::cout << "PASS mobile pause overlap, 120Hz elapsed, resume reset, stalls, invalid clocks, stop/restart\n";
}
