include("${CMAKE_CURRENT_LIST_DIR}/../../../vcpkg/triplets/arm64-android.cmake")
# One shared C++ runtime across engine_api and the adapter DSO.
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
