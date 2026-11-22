cmake_minimum_required(VERSION 3.28)
project(libgdiplus VERSION 5.6.1 LANGUAGES C)

# 配置选项
option(WITH_PANGO "Use Pango for text rendering" ON)
option(WITH_LIBEXIF "Enable EXIF support" ON)
option(WITH_X11 "Enable X11 support" OFF)

add_library(${PROJECT_NAME})

add_definitions(-DHAVE_CONFIG_H -DVERSION="${PROJECT_VERSION}")
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN 1)

# 检查系统字节序
include(TestBigEndian)
test_big_endian(WORDS_BIGENDIAN)
if(WORDS_BIGENDIAN)
    add_definitions(-DWORDS_BIGENDIAN=1)
endif()

# 查找核心依赖
find_package(PkgConfig REQUIRED)

pkg_check_modules(GDIPLUS_GLIB REQUIRED IMPORTED_TARGET glib-2.0>=2.2.3)
pkg_check_modules(GDIPLUS_CAIRO REQUIRED IMPORTED_TARGET cairo>=1.6.4)
pkg_check_modules(GDIPLUS_FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
pkg_check_modules(GDIPLUS_FREETYPE REQUIRED IMPORTED_TARGET freetype2)

include(CMakePushCheckState)
include(CheckSymbolExists)
cmake_push_check_state(RESET)
set(CMAKE_REQUIRED_LIBRARIES PkgConfig::GDIPLUS_FONTCONFIG)
check_symbol_exists(FcFini "fontconfig/fontconfig.h" HAVE_FCFINI)
cmake_pop_check_state()

# Pango可选支持
if(WITH_PANGO)
    pkg_check_modules(GDIPLUS_PANGO REQUIRED IMPORTED_TARGET pango>=1.10 pangocairo>=1.10)
    set(USE_PANGO_RENDERING ON)
    list(APPEND GDIPLUS_LIBS PkgConfig::GDIPLUS_PANGO)
endif()

# 图像编解码库
## JPEG
find_package(JPEG)
if(JPEG_FOUND)
    set(HAVE_LIBJPEG ON)
    list(APPEND GDIPLUS_LIBS JPEG::JPEG)
else()
    message(WARNING "JPEG support disabled")
endif()

## TIFF
find_package(TIFF)
if(TIFF_FOUND)
    set(HAVE_LIBTIFF ON)
    list(APPEND GDIPLUS_LIBS TIFF::TIFF)
else()
    message(WARNING "TIFF support disabled")
endif()

## GIF
#find_library(GIF_LIBRARY NAMES gif ungif)
#find_path(GIF_INCLUDE_DIR gif_lib.h)
#if(GIF_LIBRARY AND GIF_INCLUDE_DIR)
#    set(HAVE_LIBGIF ON)
#    list(APPEND GDIPLUS_LIBS ${GIF_LIBRARY})
#    target_include_directories(${PROJECT_NAME} PUBLIC ${GIF_INCLUDE_DIR})
#else()
#    message(WARNING "GIF support disabled")
#endif()

## PNG
find_package(PNG REQUIRED)
set(HAVE_LIBPNG ON)
list(APPEND GDIPLUS_LIBS PNG::PNG)

# X11支持
if(WITH_X11)
    # X11/Xrender are host-system dependencies. vcpkg isolates pkg-config's
    # search path, so system xrender.pc is not visible there on Linux.
    find_package(X11 REQUIRED COMPONENTS Xrender)
    set(HAVE_X11 ON)
    list(APPEND GDIPLUS_LIBS X11::X11 X11::Xrender)
endif()

# libexif支持
if(WITH_LIBEXIF)
    pkg_check_modules(GDIPLUS_LIBEXIF IMPORTED_TARGET libexif)
    if(GDIPLUS_LIBEXIF_FOUND)
        set(HAVE_LIBEXIF ON)
        list(APPEND GDIPLUS_LIBS PkgConfig::GDIPLUS_LIBEXIF)
    else()
        message(WARNING "EXIF support disabled")
    endif()
endif()

# 平台特定设置
if(WINDOWS)
    add_definitions(-DWIN32=1)
    find_library(INTL_LIBRARY NAMES intl)
    list(APPEND GDIPLUS_LIBS ${INTL_LIBRARY})
elseif(APPLE)
    add_definitions(-DOSX=1)
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -no-cpp-precomp")
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -flat_namespace -undefined suppress")
        list(APPEND GDIPLUS_LIBS "-framework IOKit")
    endif()
#elseif(LINUX)
#    find_package(Threads REQUIRED)
#    list(APPEND GDIPLUS_LIBS Threads::Threads)
endif()

target_sources(${PROJECT_NAME}
    PRIVATE
        src/adjustablearrowcap.c
        src/bitmap.c
        src/brush.c
        $<$<PLATFORM_ID:Darwin>:src/carbon-private.c>
        src/customlinecap.c
        src/dstream.c
        src/font.c
        src/gdi32.c
        src/general.c
        src/graphics.c
        src/graphics-cairo.c
        src/graphics-metafile.c
        src/graphics-path.c
        src/graphics-pathiterator.c
        src/hatchbrush.c
        src/icocodec.c
        src/image.c
        src/imageattributes.c
        src/lineargradientbrush.c
        src/matrix.c
        src/metafile.c
        src/pathgradientbrush.c
        src/pen.c
        src/print.c
        src/region.c
        src/region-bitmap.c
        src/region-path-tree.c
        src/solidbrush.c
        src/stringformat.c
        src/text.c
        src/text-cairo.c
        src/text-pango.c
        src/text-metafile.c
        src/texturebrush.c
        src/bmpcodec.c
        src/emfcodec.c
        src/emfplus.c
        src/gifcodec.c
        src/jpegcodec.c
        src/pngcodec.c
        src/tiffcodec.c
        src/wmfcodec.c
)

# Export dependency targets, not paths into the vcpkg tree used to build this package.
target_link_libraries(${PROJECT_NAME} PUBLIC
    PkgConfig::GDIPLUS_GLIB
    PkgConfig::GDIPLUS_CAIRO
    PkgConfig::GDIPLUS_FONTCONFIG
    PkgConfig::GDIPLUS_FREETYPE
    ${GDIPLUS_LIBS}
)

target_include_directories(${PROJECT_NAME}
    PRIVATE
        $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}>
    INTERFACE
        $<INSTALL_INTERFACE:include>
)

configure_file(config.h.in config.h)

install(DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/src/"
    DESTINATION "include/libgdiplus"
    FILES_MATCHING PATTERN "*.h" PATTERN "*.inc"
)

install(
    TARGETS libgdiplus
    EXPORT libgdiplus-targets
    ARCHIVE DESTINATION lib
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)

install(
    EXPORT libgdiplus-targets
    FILE libgdiplus-targets.cmake
    DESTINATION share/libgdiplus
    NAMESPACE libgdiplus::
)

include(CMakePackageConfigHelpers)
configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/libgdiplus-config.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/libgdiplus-config.cmake"
    INSTALL_DESTINATION share/libgdiplus
)
install(
    FILES "${CMAKE_CURRENT_BINARY_DIR}/libgdiplus-config.cmake"
    DESTINATION share/libgdiplus
)
