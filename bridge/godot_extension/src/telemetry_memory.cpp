#include "telemetry_memory.h"

#if defined(__EMSCRIPTEN__)
#include <emscripten/heap.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#elif defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#elif defined(__linux__)
#include <cstdio>
#include <unistd.h>
#endif

int64_t aether_telemetry_memory_bytes() {
#if defined(__EMSCRIPTEN__)
    return static_cast<int64_t>(emscripten_get_heap_size());
#elif defined(__APPLE__)
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS &&
        count >= TASK_VM_INFO_REV1_COUNT) {
        return static_cast<int64_t>(info.phys_footprint);
    }
#elif defined(_WIN32)
    PROCESS_MEMORY_COUNTERS info{};
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &info, sizeof(info))) {
        return static_cast<int64_t>(info.WorkingSetSize);
    }
#elif defined(__linux__)
    // statm's second field counts the process's resident pages.
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        return 0;
    }
    if (std::FILE *file = std::fopen("/proc/self/statm", "r")) {
        unsigned long long total = 0;
        unsigned long long resident = 0;
        const int fields = std::fscanf(file, "%llu %llu", &total, &resident);
        std::fclose(file);
        if (fields == 2) {
            return static_cast<int64_t>(resident) * page_size;
        }
    }
#endif
    return 0;
}
