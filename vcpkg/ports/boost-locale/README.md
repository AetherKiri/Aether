This overlay backports Boost.Locale's source-group fixes from upstream commits `1d070743d98469809a92c5bb3fca4720bd2bd782` and `f51b58cd34a2a0e3a1ce974287ec0ede0fc9d1fe` to Boost 1.92.0. The umbrella header `include/boost/locale.hpp` must be removed from the list grouped under `include/boost/locale`; otherwise CMake configuration fails because that header is outside the group's tree.

Windows builds also enable the iconv conversion backend so game text and translation scripts can use GB18030 on hosts where Windows code page 54936 is unavailable. These scripts use GB18030 to represent characters outside the GBK range.

When updating the vcpkg baseline, check both CMake configuration and a GB18030 round trip on Windows before removing this overlay.
