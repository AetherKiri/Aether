cmake_minimum_required(VERSION 3.28)
if(NOT DEFINED AETHERKIRI_SYSTEM3_DIR)
    get_filename_component(AETHERKIRI_SYSTEM3_DIR "${CMAKE_CURRENT_LIST_DIR}/../../packages/system3" ABSOLUTE)
endif()
if(NOT EXISTS "${AETHERKIRI_SYSTEM3_DIR}/src/embedded.cpp")
    message(FATAL_ERROR "Initialize packages/system3 on its Aether embedding branch")
endif()
if(NOT EXISTS "${AETHERKIRI_SYSTEM3_DIR}/deps/ymfm/src/ymfm_opn.cpp")
    message(FATAL_ERROR "Initialize packages/system3 recursively (deps/ymfm)")
endif()
find_package(SDL2 CONFIG REQUIRED)
find_package(SDL2_ttf CONFIG REQUIRED)
find_package(Threads REQUIRED)

set(core "${AETHERKIRI_SYSTEM3_DIR}")
file(GLOB vm_sources CONFIGURE_DEPENDS "${core}/src/sys/*.cpp")
list(FILTER vm_sources EXCLUDE REGEX "/mako_midi\\.cpp$")
add_library(aether_system3_core STATIC
    ${vm_sources}
    "${core}/src/embedded.cpp"
    "${core}/src/config.cpp"
    "${core}/src/fileio.cpp"
    "${core}/src/resource.cpp"
    "${core}/src/encoding.cpp"
    "${core}/src/texthook.cpp"
    "${core}/src/generic/nact_generic.cpp"
    "${core}/src/generic/mako.cpp"
    "${core}/src/fm/makofm.cpp"
    "${core}/src/fm/mako_ymfm.cpp"
    "${core}/deps/ymfm/src/ymfm_opn.cpp"
    "${core}/deps/ymfm/src/ymfm_adpcm.cpp"
    "${core}/deps/ymfm/src/ymfm_ssg.cpp")
target_compile_features(aether_system3_core PRIVATE cxx_std_17)
target_compile_definitions(aether_system3_core PRIVATE SYSTEM3_EMBEDDED
    SYSTEM3_SDL_VERSION=2 SDL_MAIN_HANDLED RESOURCE_PATH="")
target_compile_options(aether_system3_core PRIVATE
    -include "${core}/src/embedded_symbols.h")
target_include_directories(aether_system3_core PRIVATE
    "${core}/src" "${core}/src/sys" "${core}/deps/ymfm/src"
    "${core}/deps/dr_libs" "${core}/deps/stb")
set_source_files_properties("${core}/src/sys/music_decoder.cpp" PROPERTIES COMPILE_OPTIONS "-w")
target_link_libraries(aether_system3_core PRIVATE
    $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>
    $<IF:$<TARGET_EXISTS:SDL2_ttf::SDL2_ttf>,SDL2_ttf::SDL2_ttf,SDL2_ttf::SDL2_ttf-static>)
set_target_properties(aether_system3_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(aether_system3_runtime STATIC src/system3_runtime_provider.cpp)
target_compile_features(aether_system3_runtime PRIVATE cxx_std_17)
target_include_directories(aether_system3_runtime PUBLIC "${CMAKE_CURRENT_LIST_DIR}/include"
    PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../abi/include" "${core}/src")
target_link_libraries(aether_system3_runtime PRIVATE aether_system3_core Threads::Threads
    $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>)
set_target_properties(aether_system3_runtime PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(TARGET engine_api)
    target_link_libraries(aether_system3_runtime PRIVATE engine_api)
endif()
