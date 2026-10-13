#pragma once
#include <cstddef>
namespace aether::mobile {
// A sequence cannot acquire a new primary until every finger has left.
struct TouchSequence {
    bool captured = false;
    bool waiting = false;
    bool begin(std::size_t active) {
        if (captured) { if (active > 1) waiting = true; return false; }
        if (waiting || active != 1) { if (active) waiting = true; return false; }
        captured = true; return true;
    }
    void reject() { captured = false; waiting = true; }
    void cancel() { if (captured) { captured = false; waiting = true; } }
    void finish(std::size_t active, bool primaryEnded) {
        if (primaryEnded) captured = false;
        if (!active) { captured = false; waiting = false; }
        else if (primaryEnded) waiting = true;
    }
};
}
