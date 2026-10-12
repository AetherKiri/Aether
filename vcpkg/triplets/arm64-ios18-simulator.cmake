include("${CMAKE_CURRENT_LIST_DIR}/arm64-ios-simulator.cmake")
set(VCPKG_OSX_DEPLOYMENT_TARGET 18.0)

# Use the SDK iconv library; no target CLI relocatable wrapper is needed.
set(X_VCPKG_BUILD_GNU_LIBICONV 0)

# Legacy vcpkg_configure_make embeds this as one shell argument string.
# A CMake list (semicolon) truncates bash -c before OpenSSL's Configure args.
if(PORT STREQUAL "openssl")
    set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-apple-darwin --build=x86_64-apple-darwin")
endif()
