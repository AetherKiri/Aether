# Native Apple host: do not change the legacy Godot iOS triplet.
include("${CMAKE_CURRENT_LIST_DIR}/arm64-ios.cmake")
set(VCPKG_OSX_DEPLOYMENT_TARGET 18.0)

# Use the SDK iconv library; no target CLI relocatable wrapper is needed.
set(X_VCPKG_BUILD_GNU_LIBICONV 0)
