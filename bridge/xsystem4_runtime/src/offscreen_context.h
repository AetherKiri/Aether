#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace aetherkiri::xsystem4 {
    class OffscreenContext {
    public:
        OffscreenContext();
        ~OffscreenContext();
        bool initialize(uint32_t width, uint32_t height, std::string &error);
        unsigned framebuffer() const;
        bool read(std::vector<uint8_t> &rgba, std::string &error);

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
    };
} // namespace aetherkiri::xsystem4
