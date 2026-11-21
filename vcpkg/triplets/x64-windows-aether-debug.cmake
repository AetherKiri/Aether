# Godot's template_debug uses the release dynamic CRT. The host keeps Debug
# symbols and Godot diagnostics while linking dependencies built for that ABI.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PROVIDED_FORTRAN ON)
set(VCPKG_BUILD_TYPE release)
