#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace aether::mobile {
enum PauseReason : uint32_t {
    sceneInactive = 1u << 0,
    audioInterruption = 1u << 1,
    userResumeRequired = 1u << 2,
    audioUnavailable = 1u << 3,
    systemModal = 1u << 4,
    audioServicesLost = 1u << 5,
    applicationInactive = 1u << 6,
};

// UIKit adapters own side effects. Removing one reason never clears another.
class SessionTiming {
public:
    void start() { running_ = true; resetClock(); }
    void stop() { running_ = false; reasons_ = 0; resetClock(); }
    void setReasons(uint32_t reasons) {
        if (reasons_ != reasons) resetClock();
        reasons_ = reasons;
    }
    uint32_t reasons() const { return reasons_; }
    bool ticking() const { return running_ && reasons_ == 0; }
    void resetClock() { previous_.reset(); remainder_ = 0; }
    std::optional<uint32_t> delta(double timestamp) {
        if (!ticking() || !std::isfinite(timestamp)) { resetClock(); return std::nullopt; }
        if (!previous_) { previous_ = timestamp; return 0; }
        if (timestamp < *previous_) { resetClock(); previous_ = timestamp; return 0; }
        double elapsed = std::min(0.1, timestamp - *previous_);
        previous_ = timestamp;
        double exact = elapsed * 1000 + remainder_;
        auto milliseconds = static_cast<uint32_t>(std::max(0.0, std::round(exact)));
        remainder_ = exact - milliseconds;
        return milliseconds;
    }
private:
    bool running_ = false;
    uint32_t reasons_ = 0;
    std::optional<double> previous_;
    double remainder_ = 0;
};
} // namespace aether::mobile
