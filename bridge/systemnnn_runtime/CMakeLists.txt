if(WEB OR EMSCRIPTEN)
    message(FATAL_ERROR "SystemNNN requires a native platform; disable AETHERKIRI_ENABLE_SYSTEMNNN")
endif()
if(NOT EXISTS "${AETHERKIRI_SYSTEMNNN_DIR}/platform/scene/CMakeLists.txt")
    message(FATAL_ERROR "Initialize packages/SystemNNN-Emberfall, or set AETHERKIRI_SYSTEMNNN_DIR")
endif()
set(NNN_USE_SYSTEM_DEPENDENCIES ON CACHE BOOL "Use Aether/vcpkg PNG and zlib" FORCE)
set(NNN_BUILD_TOOLS OFF CACHE BOOL "Do not embed diagnostic players" FORCE)
# Only this directory's third-party subtree sees BUILD_TESTING disabled.
set(BUILD_TESTING OFF)
add_subdirectory("${AETHERKIRI_SYSTEMNNN_DIR}/platform/scene" "${CMAKE_CURRENT_BINARY_DIR}/emberfall")
find_package(Freetype REQUIRED)
set(_systemnnn_iconv Iconv::Iconv)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND VCPKG_INSTALLED_DIR AND VCPKG_TARGET_TRIPLET)
    # Match GNU iconv.h from the target prefix to GNU libraries without
    # replacing the SDK iconv target used by other providers.
    set(_systemnnn_iconv_prefix "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}")
    set(_systemnnn_iconv_dir "${_systemnnn_iconv_prefix}/lib")
    if(CMAKE_BUILD_TYPE STREQUAL "Debug" AND
       EXISTS "${_systemnnn_iconv_prefix}/debug/lib/libiconv.a")
        set(_systemnnn_iconv_dir "${_systemnnn_iconv_prefix}/debug/lib")
    endif()
    file(STRINGS "${_systemnnn_iconv_prefix}/include/iconv.h" _systemnnn_iconv_version
        REGEX "^#define _LIBICONV_VERSION ")
    if(NOT _systemnnn_iconv_version OR NOT EXISTS "${_systemnnn_iconv_dir}/libiconv.a" OR
       NOT EXISTS "${_systemnnn_iconv_dir}/libcharset.a")
        message(FATAL_ERROR "SystemNNN requires the matching GNU iconv header and archives from vcpkg")
    endif()
    add_library(aether_systemnnn_iconv INTERFACE)
    target_include_directories(aether_systemnnn_iconv INTERFACE "${_systemnnn_iconv_prefix}/include")
    target_link_libraries(aether_systemnnn_iconv INTERFACE
        "${_systemnnn_iconv_dir}/libiconv.a" "${_systemnnn_iconv_dir}/libcharset.a")
    set(_systemnnn_iconv aether_systemnnn_iconv)
else()
    find_package(Iconv REQUIRED)
endif()
find_package(nlohmann_json CONFIG REQUIRED)
find_package(Threads REQUIRED)
find_package(OpenAL CONFIG QUIET)
if(NOT TARGET OpenAL::OpenAL)
    find_package(OpenAL REQUIRED)
endif()
# The vcpkg overlay supplies FindFFMPEG and its complete static dependency
# list. Other Windows distributions expose CONFIG targets instead; retain their
# include paths, debug/release locations and transitive dependencies.
find_package(FFMPEG QUIET)
if(NOT FFMPEG_FOUND)
    find_package(FFmpeg CONFIG QUIET)
    if(NOT FFmpeg_FOUND)
        find_package(ffmpeg CONFIG QUIET)
    endif()
endif()
set(_systemnnn_ffmpeg "")
foreach(_systemnnn_ffmpeg_namespace IN ITEMS FFmpeg ffmpeg FFMPEG)
    set(_systemnnn_ffmpeg_targets "")
    foreach(_systemnnn_ffmpeg_component IN ITEMS avformat avcodec avutil swscale swresample)
        if(TARGET ${_systemnnn_ffmpeg_namespace}::${_systemnnn_ffmpeg_component})
            list(APPEND _systemnnn_ffmpeg_targets
                ${_systemnnn_ffmpeg_namespace}::${_systemnnn_ffmpeg_component})
        endif()
    endforeach()
    list(LENGTH _systemnnn_ffmpeg_targets _systemnnn_ffmpeg_target_count)
    if(_systemnnn_ffmpeg_target_count EQUAL 5)
        set(_systemnnn_ffmpeg ${_systemnnn_ffmpeg_targets})
        break()
    endif()
endforeach()
if(NOT _systemnnn_ffmpeg AND FFMPEG_FOUND AND FFMPEG_LIBRARIES)
    set(_systemnnn_ffmpeg ${FFMPEG_LIBRARIES})
endif()
if(NOT _systemnnn_ffmpeg)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SYSTEMNNN_FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswscale libswresample)
    set(_systemnnn_ffmpeg PkgConfig::SYSTEMNNN_FFMPEG)
endif()
if(COMMAND aetherkiri_sanitize_openal_link)
    aetherkiri_sanitize_openal_link()
endif()
add_library(aether_systemnnn_runtime STATIC
    src/systemnnn_runtime_provider.cpp src/systemnnn_text.cpp
    src/systemnnn_presenter.cpp src/systemnnn_audio.cpp src/systemnnn_progress.cpp
    src/systemnnn_movie.cpp src/systemnnn_startup.cpp src/systemnnn_minigame.cpp src/systemnnn_minigame_binding.cpp)
target_compile_features(aether_systemnnn_runtime PUBLIC cxx_std_17)
set_target_properties(aether_systemnnn_runtime PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(aether_systemnnn_runtime PUBLIC include PRIVATE ${FFMPEG_INCLUDE_DIRS})
target_link_libraries(aether_systemnnn_runtime PUBLIC engine_api
    PRIVATE emberfall-scene Freetype::Freetype ${_systemnnn_iconv}
    nlohmann_json::nlohmann_json Threads::Threads OpenAL::OpenAL ${_systemnnn_ffmpeg})
set_property(TARGET aether_systemnnn_runtime PROPERTY AETHERKIRI_SYSTEMNNN_STATIC_TARGETS
    aether_systemnnn_runtime emberfall-scene emberfall-render nnn-script-core
    nnn-game-audio nnn-dwq-core nnn-png-core nnn-image-core nnn-archive-core)
if(MSVC)
    target_compile_options(aether_systemnnn_runtime PRIVATE /utf-8)
endif()
