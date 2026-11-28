#pragma once

#include <cstdint>

// Current process memory in bytes, or zero if unavailable. On the Web this
// reports the WebAssembly linear memory capacity shared by the engine and host.
int64_t aether_telemetry_memory_bytes();
