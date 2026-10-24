cmake_minimum_required(VERSION 3.28)
if(NOT DEFINED AETHERKIRI_XSYSTEM35_DIR)
    get_filename_component(AETHERKIRI_XSYSTEM35_DIR "${CMAKE_CURRENT_LIST_DIR}/../../packages/xsystem35" ABSOLUTE)
endif()
if(NOT EXISTS "${AETHERKIRI_XSYSTEM35_DIR}/src/embedded.c")
    message(FATAL_ERROR "Initialize packages/xsystem35 on its Aether embedding branch")
endif()

find_package(ZLIB REQUIRED)
find_package(SDL2 CONFIG REQUIRED)
find_package(SDL2_mixer CONFIG REQUIRED)
find_package(Freetype REQUIRED)
find_package(WebP CONFIG REQUIRED)
find_package(Threads REQUIRED)
find_package(Iconv REQUIRED)
find_package(uchardet CONFIG REQUIRED)

set(generated "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${generated}")
set(PACKAGE xsystem35)
set(XSYSTEM35_VERSION 2.20.0)
set(XSYSTEM35_SDL_VERSION 2)
set(ENABLE_MIDI_SDLMIXER 1)
set(HAVE_MMAP 1)
set(HAVE_WEBP 1)
set(DEFAULT_PLAYLIST_PATH playlist.txt)
configure_file("${AETHERKIRI_XSYSTEM35_DIR}/config.h.in" "${generated}/config.h")
add_custom_command(OUTPUT "${generated}/nls_catalog.h"
    COMMAND "${CMAKE_COMMAND}" "-DPO_DIR=${AETHERKIRI_XSYSTEM35_DIR}/po"
        -DLANGUAGES=ja "-DOUTPUT=${generated}/nls_catalog.h"
        -P "${AETHERKIRI_XSYSTEM35_DIR}/po/generate_nls_catalog.cmake"
    DEPENDS "${AETHERKIRI_XSYSTEM35_DIR}/po/ja.po"
        "${AETHERKIRI_XSYSTEM35_DIR}/po/generate_nls_catalog.cmake"
    VERBATIM)

# Use the same source sets as upstream, without its standalone executable,
# desktop debugger, platform window or platform-specific audio front ends.
file(GLOB sources CONFIGURE_DEPENDS "${AETHERKIRI_XSYSTEM35_DIR}/src/*.c")
list(FILTER sources EXCLUDE REGEX "(_test|src_tests|nanojpeg|debug[^/]*|midi\.[^/]*|mixer\.[^/]*|pcm\.[^/]*|bgm\.[^/]*|cdrom\.emscripten)\\.c$")
list(APPEND sources
    "${AETHERKIRI_XSYSTEM35_DIR}/src/microui/microui.c"
    "${AETHERKIRI_XSYSTEM35_DIR}/src/midi.sdlmixer.c"
    "${AETHERKIRI_XSYSTEM35_DIR}/src/mixer.sdl2mixer.c"
    "${AETHERKIRI_XSYSTEM35_DIR}/src/pcm.sdlmixer.c"
    "${AETHERKIRI_XSYSTEM35_DIR}/src/bgm.sdlmixer.c")
file(STRINGS "${AETHERKIRI_XSYSTEM35_DIR}/modules/CMakeLists.txt" module_lines REGEX "^[ ]+[^ ]+\\.c$")
set(modules "")
foreach(line IN LISTS module_lines)
    string(STRIP "${line}" relative)
    list(APPEND modules "${AETHERKIRI_XSYSTEM35_DIR}/modules/${relative}")
endforeach()
add_library(aether_xsystem35_core STATIC ${sources} ${modules} "${generated}/nls_catalog.h")
target_compile_definitions(aether_xsystem35_core PRIVATE XSYSTEM35_EMBEDDED SDL_MAIN_HANDLED _DEFAULT_SOURCE)
target_compile_options(aether_xsystem35_core PRIVATE -Wno-pointer-sign
    -include "${AETHERKIRI_XSYSTEM35_DIR}/src/embedded_io.h")
target_include_directories(aether_xsystem35_core PRIVATE "${generated}"
    "${AETHERKIRI_XSYSTEM35_DIR}/src" "${AETHERKIRI_XSYSTEM35_DIR}/modules"
    "${AETHERKIRI_XSYSTEM35_DIR}/modules/lib")
target_link_libraries(aether_xsystem35_core PRIVATE
    $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>
    $<IF:$<TARGET_EXISTS:SDL2_mixer::SDL2_mixer>,SDL2_mixer::SDL2_mixer,SDL2_mixer::SDL2_mixer-static>
    Freetype::Freetype ZLIB::ZLIB WebP::webp Iconv::Iconv)
set_target_properties(aether_xsystem35_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(UNIX AND NOT APPLE)
    target_link_libraries(aether_xsystem35_core PRIVATE m)
endif()

add_library(aether_xsystem35_runtime STATIC src/xsystem35_runtime_provider.cpp)
target_compile_features(aether_xsystem35_runtime PRIVATE cxx_std_17)
target_include_directories(aether_xsystem35_runtime PUBLIC "${CMAKE_CURRENT_LIST_DIR}/include"
    PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../abi/include" "${AETHERKIRI_XSYSTEM35_DIR}/src")
target_link_libraries(aether_xsystem35_runtime PRIVATE aether_xsystem35_core Threads::Threads uchardet::libuchardet
    $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>
    $<IF:$<TARGET_EXISTS:SDL2_mixer::SDL2_mixer>,SDL2_mixer::SDL2_mixer,SDL2_mixer::SDL2_mixer-static>)
set_target_properties(aether_xsystem35_runtime PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(TARGET engine_api)
    target_link_libraries(aether_xsystem35_runtime PRIVATE engine_api)
endif()
