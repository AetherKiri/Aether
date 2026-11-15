# iOS exports link the managed object and its runtime into the application.
# The publisher retains NativeAOT's C++ bootstrap initializer alongside the ABI.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(Freetype REQUIRED)
find_package(OpenAL CONFIG REQUIRED)
find_package(FFMPEG REQUIRED)
find_package(Iconv REQUIRED)

set(_n2_ios_host_archive "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/libaether_n2system_native.a")
set(_n2_ios_minimum_version "${CMAKE_OSX_DEPLOYMENT_TARGET}")
if(NOT _n2_ios_minimum_version)
    set(_n2_ios_minimum_version 16.0)
endif()
set(_n2_runtime_cjk_font "${CMAKE_SOURCE_DIR}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf")
set(_n2_stamp "${CMAKE_CURRENT_BINARY_DIR}/nativeaot.stamp")
add_custom_command(OUTPUT "${_n2_stamp}" "${_n2_ios_host_archive}"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tools/build_n2system_ios.py"
        --dotnet "${AETHERKIRI_DOTNET_EXECUTABLE}"
        --project "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/AetherN2System.Host.csproj"
        --rid "${AETHERKIRI_N2SYSTEM_RID}"
        --destination "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}"
        --minimum-version "${_n2_ios_minimum_version}"
        --font "${_n2_runtime_cjk_font}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_n2_stamp}"
    DEPENDS ${_n2_sources} "${_n2_runtime_cjk_font}"
        "${CMAKE_SOURCE_DIR}/tools/build_n2system_ios.py"
        "${AETHERKIRI_N2SYSTEM_DIR}/Directory.Build.props"
        "${AETHERKIRI_N2SYSTEM_DIR}/Directory.Build.targets"
        "${AETHERKIRI_N2SYSTEM_DIR}/OutputPath.props"
        "${AETHERKIRI_N2SYSTEM_DIR}/NuGet.Config"
    COMMENT "Publishing N2System static NativeAOT host (${AETHERKIRI_N2SYSTEM_RID})"
    VERBATIM)
add_custom_target(aether_n2system_host DEPENDS "${_n2_stamp}" "${_n2_ios_host_archive}")
add_library(aether_n2system_native_host STATIC IMPORTED GLOBAL)
set_target_properties(aether_n2system_native_host PROPERTIES IMPORTED_LOCATION "${_n2_ios_host_archive}")
add_dependencies(aether_n2system_native_host aether_n2system_host)

set(_n2_ios_link_libraries aether_n2system_native_host Freetype::Freetype OpenAL::OpenAL
    ${FFMPEG_LIBRARIES} Iconv::Iconv
    "-framework CoreFoundation" "-framework CryptoKit" "-framework Foundation"
    "-framework Network" "-framework Security" "-framework GSS"
    "-framework Metal" "-framework QuartzCore" icucore z objc c++ swiftCore swiftFoundation)
set(_n2_ios_link_options "-L/usr/lib/swift")
