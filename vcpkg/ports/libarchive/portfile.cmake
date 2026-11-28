vcpkg_download_distfile(ARCHIVE
    URLS
        "https://github.com/libarchive/libarchive/releases/download/v${VERSION}/libarchive-${VERSION}.tar.xz"
        "https://libarchive.org/downloads/libarchive-${VERSION}.tar.xz"
    FILENAME "libarchive-${VERSION}.tar.xz"
    SHA512 7e9145c51d389ae5fa4e64c9a791dcbe4960ae064ebefa40d73d6079180af17795d7d0f9dffc939f9d050b9be2669f45115bb89a9466f43617e731edab57ccf1
)

# Keep one libarchive implementation in the application, including the static iOS link.
# Patch set from the AetherUnzip gitlink 01feda8. Bump the port revision when it changes.
set(archive_patches)
set(archive_crypto OFF)
if("aether-unzip" IN_LIST FEATURES)
    set(patch_dir "${CURRENT_PORT_DIR}/../../../packages/AetherUnzip/cmake/patches")
    foreach(name IN ITEMS split-zip gzip-trailer 7z-aes rar5-aes)
        list(APPEND archive_patches "${patch_dir}/libarchive-${name}.patch")
    endforeach()
    # Avoid opportunistically linking desktop XML/regex libraries from a cross build host.
    foreach(feature IN ITEMS LIBXML2 BSDXML EXPAT PCREPOSIX PCRE2POSIX MD LIBB2)
        list(APPEND archive_codec_options "-DENABLE_${feature}=OFF")
    endforeach()
    if(VCPKG_TARGET_IS_ANDROID)
        # Bionic uses UTF-8 paths. GNU libcharset otherwise reports ASCII
        # under Android's process locale even inside a UTF-8 worker locale.
        list(APPEND archive_codec_options -DHAVE_LOCALE_CHARSET=0 -DHAVE_NL_LANGINFO=0)
        set(archive_crypto ON)
    endif()
endif()

vcpkg_extract_source_archive(
    SOURCE_PATH
    ARCHIVE "${ARCHIVE}"
    PATCHES ${archive_patches}
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        ${archive_codec_options}
        -DENABLE_OPENSSL=${archive_crypto}
        -DENABLE_TEST=OFF
        -DENABLE_TAR=OFF
        -DENABLE_CAT=OFF
        -DENABLE_CPIO=OFF
        -DENABLE_UNZIP=OFF
)

vcpkg_cmake_install()

vcpkg_fixup_pkgconfig()

vcpkg_copy_pdbs()

file(REMOVE_RECURSE
      "${CURRENT_PACKAGES_DIR}/debug/include"
      "${CURRENT_PACKAGES_DIR}/debug/share"
      "${CURRENT_PACKAGES_DIR}/share/man"
)

foreach(header "include/archive.h" "include/archive_entry.h")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/${header}" "(!defined LIBARCHIVE_STATIC)" "0")
endforeach()

file(INSTALL "${CURRENT_PORT_DIR}/usage" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}")
file(INSTALL "${SOURCE_PATH}/COPYING" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}" RENAME copyright)
