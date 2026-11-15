# NativeAOT runs NitroSharp in process and does not require a .NET installation
# on the player's machine.
if(WEB OR EMSCRIPTEN)
    message(FATAL_ERROR "N2System NativeAOT does not support Web; disable AETHERKIRI_ENABLE_N2SYSTEM")
endif()
if(NOT EXISTS "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/AetherN2System.Host.csproj")
    message(FATAL_ERROR "Initialize packages/AetherN2System, or disable AETHERKIRI_ENABLE_N2SYSTEM")
endif()
find_program(AETHERKIRI_DOTNET_EXECUTABLE dotnet REQUIRED)
execute_process(COMMAND "${AETHERKIRI_DOTNET_EXECUTABLE}" --list-sdks
    OUTPUT_VARIABLE _n2_sdks RESULT_VARIABLE _n2_sdk_result)
if(NOT _n2_sdk_result EQUAL 0 OR NOT _n2_sdks MATCHES "(^|\n)([1-9][0-9]+)\\.")
    message(FATAL_ERROR "N2System requires a .NET 10 or newer SDK; install it or disable AETHERKIRI_ENABLE_N2SYSTEM")
endif()
set(_n2_arch "${CMAKE_SYSTEM_PROCESSOR}")
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    set(_n2_arch "${CMAKE_OSX_ARCHITECTURES}")
endif()
if(_n2_arch MATCHES "^(arm64|aarch64|ARM64)$")
    set(_n2_arch arm64)
elseif(_n2_arch MATCHES "^(x86_64|AMD64|amd64|x64)$")
    set(_n2_arch x64)
else()
    message(FATAL_ERROR "N2System NativeAOT requires one x64 or arm64 architecture (got '${_n2_arch}')")
endif()
if(ANDROID)
    if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
        message(FATAL_ERROR "N2System Android currently requires arm64-v8a")
    endif()
    set(_n2_platform linux-bionic)
    set(_n2_stage "android/${ANDROID_ABI}")
elseif(IOS)
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        set(_n2_platform iossimulator)
        if(_n2_arch STREQUAL "x64")
            set(_n2_stage ios-simulator-x64)
        else()
            set(_n2_stage ios-simulator)
        endif()
    else()
        set(_n2_platform ios)
        set(_n2_stage ios)
    endif()
elseif(APPLE)
    set(_n2_platform osx)
    set(_n2_stage macos)
elseif(WIN32)
    set(_n2_platform win)
    set(_n2_stage windows)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(_n2_platform linux)
    set(_n2_stage linux)
else()
    message(FATAL_ERROR "N2System NativeAOT does not support ${CMAKE_SYSTEM_NAME}")
endif()
set(AETHERKIRI_N2SYSTEM_RID "${_n2_platform}-${_n2_arch}")
set(AETHERKIRI_N2SYSTEM_PUBLISH_DIR "${CMAKE_CURRENT_BINARY_DIR}/publish")
file(GLOB_RECURSE _n2_sources CONFIGURE_DEPENDS
    "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/*.cs"
    "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/*.csproj"
    "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/*.py"
    "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/shaders/*"
    "${AETHERKIRI_N2SYSTEM_DIR}/src/*.cs"
    "${AETHERKIRI_N2SYSTEM_DIR}/src/*.csproj"
    "${AETHERKIRI_N2SYSTEM_DIR}/src/*.lic"
    "${AETHERKIRI_N2SYSTEM_DIR}/src/*.glsl"
    "${AETHERKIRI_N2SYSTEM_DIR}/third_party/*.cs"
    "${AETHERKIRI_N2SYSTEM_DIR}/third_party/*.csproj"
    "${AETHERKIRI_N2SYSTEM_DIR}/fonts/*")
list(FILTER _n2_sources EXCLUDE REGEX "/(bin|obj)/")
if(IOS)
    include(cmake/N2SystemIOS.cmake)
else()
# NitroSharp's P/Invoke ABI needs a shared FreeType image. Build it from the
# same target-toolchain packages as Aether instead of shipping NuGet's x64-only
# macOS binary or depending on a developer's Homebrew installation.
find_package(Freetype REQUIRED)
set(_n2_freetype_link_target Freetype::Freetype)
# vcpkg's compatibility Freetype::Freetype target can be an interface around
# its actual archive target; apply whole-archive to that concrete target.
get_target_property(_n2_freetype_type Freetype::Freetype TYPE)
if(_n2_freetype_type STREQUAL "INTERFACE_LIBRARY" AND TARGET freetype)
    set(_n2_freetype_link_target freetype)
    get_target_property(_n2_freetype_type freetype TYPE)
endif()
if(_n2_freetype_type STREQUAL "SHARED_LIBRARY")
    set(_n2_freetype_target ${_n2_freetype_link_target})
else()
    add_library(aether_n2system_freetype SHARED src/native_dependency_anchor.c)
    target_link_libraries(aether_n2system_freetype PRIVATE Freetype::Freetype)
    set_property(TARGET aether_n2system_freetype PROPERTY
        "LINK_LIBRARY_OVERRIDE_${_n2_freetype_link_target}" WHOLE_ARCHIVE)
    set_target_properties(aether_n2system_freetype PROPERTIES OUTPUT_NAME freetype)
    if(ANDROID)
        set_target_properties(aether_n2system_freetype PROPERTIES OUTPUT_NAME aether_n2system_freetype)
    elseif(WIN32)
        # Static Windows archives do not carry dllexport markers. Export the
        # exact public functions declared by the managed FreeType binding.
        file(STRINGS "${AETHERKIRI_N2SYSTEM_DIR}/src/FreeTypeBindings/FT.cs" _n2_ft_declarations
            REGEX "public static extern")
        set(_n2_ft_exports "EXPORTS\n")
        foreach(_n2_declaration IN LISTS _n2_ft_declarations)
            string(REGEX MATCH "FT_[A-Za-z0-9_]+\\(" _n2_symbol "${_n2_declaration}")
            string(REPLACE "(" "" _n2_symbol "${_n2_symbol}")
            if(_n2_symbol)
                string(APPEND _n2_ft_exports "${_n2_symbol}\n")
            endif()
        endforeach()
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/freetype.def" "${_n2_ft_exports}")
        target_sources(aether_n2system_freetype PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/freetype.def")
        set_target_properties(aether_n2system_freetype PROPERTIES PREFIX "")
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set_target_properties(aether_n2system_freetype PROPERTIES SOVERSION 6)
    endif()
    set(_n2_freetype_target aether_n2system_freetype)
endif()
if(ANDROID)
    set(_n2_freetype_name libaether_n2system_freetype.so)
elseif(WIN32)
    set(_n2_freetype_name freetype.dll)
elseif(APPLE)
    set(_n2_freetype_name libfreetype.dylib)
else()
    set(_n2_freetype_name libfreetype.so.6)
endif()
# NuGet's OpenAL package likewise has no Linux or Apple Silicon image. Keep
# the audio output library private to this runtime with the same toolchain.
find_package(OpenAL CONFIG REQUIRED)
get_target_property(_n2_openal_type OpenAL::OpenAL TYPE)
if(_n2_openal_type STREQUAL "SHARED_LIBRARY")
    set(_n2_openal_target OpenAL::OpenAL)
else()
    add_library(aether_n2system_openal SHARED src/native_dependency_anchor.c)
    target_link_libraries(aether_n2system_openal PRIVATE OpenAL::OpenAL)
    set_property(TARGET aether_n2system_openal PROPERTY
        "LINK_LIBRARY_OVERRIDE_OpenAL::OpenAL" WHOLE_ARCHIVE)
    set_target_properties(aether_n2system_openal PROPERTIES OUTPUT_NAME openal LINKER_LANGUAGE CXX)
    if(ANDROID)
        set_target_properties(aether_n2system_openal PROPERTIES OUTPUT_NAME aether_n2system_openal)
    elseif(WIN32)
        set(_n2_al_symbols "")
        foreach(_n2_binding IN ITEMS AL10 AL11 ALC10 ALC11)
            file(STRINGS "${AETHERKIRI_N2SYSTEM_DIR}/third_party/OpenAL-CS/${_n2_binding}.cs"
                _n2_al_declarations REGEX "static extern")
            foreach(_n2_declaration IN LISTS _n2_al_declarations)
                string(REGEX MATCH "alc?[A-Z][A-Za-z0-9_]+\\(" _n2_symbol "${_n2_declaration}")
                string(REPLACE "(" "" _n2_symbol "${_n2_symbol}")
                if(_n2_symbol)
                    list(APPEND _n2_al_symbols "${_n2_symbol}")
                endif()
            endforeach()
        endforeach()
        list(REMOVE_DUPLICATES _n2_al_symbols)
        list(JOIN _n2_al_symbols "\n" _n2_al_exports)
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/openal.def" "EXPORTS\n${_n2_al_exports}\n")
        target_sources(aether_n2system_openal PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/openal.def")
        set_target_properties(aether_n2system_openal PROPERTIES PREFIX "" OUTPUT_NAME OpenAL32)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set_target_properties(aether_n2system_openal PROPERTIES SOVERSION 1)
    endif()
    set(_n2_openal_target aether_n2system_openal)
endif()
if(ANDROID)
    set(_n2_openal_name libaether_n2system_openal.so)
elseif(WIN32)
    set(_n2_openal_name OpenAL32.dll)
elseif(APPLE)
    set(_n2_openal_name libopenal.dylib)
else()
    set(_n2_openal_name libopenal.so.1)
endif()
include(cmake/N2SystemMedia.cmake)
set(_n2_runtime_cjk_font "${CMAKE_SOURCE_DIR}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf")
set(_n2_stamp "${CMAKE_CURRENT_BINARY_DIR}/nativeaot.stamp")
set(_n2_publish_command "${AETHERKIRI_DOTNET_EXECUTABLE}" publish
    "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/AetherN2System.Host.csproj"
    -c Release -r "${AETHERKIRI_N2SYSTEM_RID}"
    "/p:NativeRid=${AETHERKIRI_N2SYSTEM_RID}"
    -o "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}")
if(ANDROID)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(_n2_publish_byproducts "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/libaether_n2system.so")
    set(_n2_publish_command "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tools/build_n2system_android.py"
        --project "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/AetherN2System.Host.csproj"
        --ndk "${CMAKE_ANDROID_NDK}" --abi "${ANDROID_ABI}"
        --output "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}"
        --dotnet "${AETHERKIRI_DOTNET_EXECUTABLE}" --font "${_n2_runtime_cjk_font}")
endif()
add_custom_command(OUTPUT "${_n2_stamp}"
    BYPRODUCTS ${_n2_publish_byproducts}
    COMMAND ${_n2_publish_command}
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "$<TARGET_FILE:${_n2_freetype_target}>" "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/${_n2_freetype_name}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "$<TARGET_FILE:${_n2_openal_target}>" "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/${_n2_openal_name}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "$<TARGET_FILE:aether_n2system_media>" "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/$<TARGET_FILE_NAME:aether_n2system_media>"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/Fonts"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${_n2_runtime_cjk_font}" "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/Fonts/aetherkiri-runtime-cjk.otf"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_n2_stamp}"
    DEPENDS ${_n2_sources} ${_n2_freetype_target} ${_n2_openal_target} aether_n2system_media "${_n2_runtime_cjk_font}"
        "${CMAKE_SOURCE_DIR}/tools/build_n2system_android.py"
        "${AETHERKIRI_N2SYSTEM_DIR}/Directory.Build.props"
        "${AETHERKIRI_N2SYSTEM_DIR}/Directory.Build.targets"
        "${AETHERKIRI_N2SYSTEM_DIR}/OutputPath.props"
        "${AETHERKIRI_N2SYSTEM_DIR}/NuGet.Config"
    COMMENT "Publishing N2System NativeAOT host (${AETHERKIRI_N2SYSTEM_RID})"
    VERBATIM)
add_custom_target(aether_n2system_host DEPENDS "${_n2_stamp}")
if(ANDROID)
    add_library(aether_n2system_host_image SHARED IMPORTED GLOBAL)
    set_target_properties(aether_n2system_host_image PROPERTIES
        IMPORTED_LOCATION "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}/libaether_n2system.so")
    add_dependencies(aether_n2system_host_image aether_n2system_host)
endif()
endif()
find_package(nlohmann_json CONFIG REQUIRED)
find_package(Threads REQUIRED)
add_library(aether_n2system_runtime STATIC src/n2system_runtime_provider.cpp)
target_compile_features(aether_n2system_runtime PUBLIC cxx_std_17)
set_target_properties(aether_n2system_runtime PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(aether_n2system_runtime PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
    PRIVATE "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/include")
target_link_libraries(aether_n2system_runtime PUBLIC engine_api
    PRIVATE nlohmann_json::nlohmann_json Threads::Threads ${CMAKE_DL_LIBS})
add_dependencies(aether_n2system_runtime aether_n2system_host)
if(IOS)
    target_compile_definitions(aether_n2system_runtime PRIVATE AETHERKIRI_N2SYSTEM_STATIC_HOST=1)
    target_link_libraries(aether_n2system_runtime PUBLIC ${_n2_ios_link_libraries})
    target_link_options(aether_n2system_runtime PUBLIC ${_n2_ios_link_options})
endif()
set_property(TARGET aether_n2system_runtime PROPERTY AETHERKIRI_N2SYSTEM_STAGE "${_n2_stage}")
set_property(TARGET aether_n2system_runtime PROPERTY AETHERKIRI_N2SYSTEM_PUBLISH_DIR
    "${AETHERKIRI_N2SYSTEM_PUBLISH_DIR}")
if(ANDROID)
    set_property(TARGET aether_n2system_runtime PROPERTY AETHERKIRI_N2SYSTEM_SHARED_TARGETS
        aether_n2system_host_image aether_n2system_media ${_n2_freetype_target} ${_n2_openal_target})
endif()
