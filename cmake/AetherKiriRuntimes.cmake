# The normal product keeps every currently supported runtime enabled. A fresh
# selective build can turn the default off and opt into individual runtimes;
# explicit per-runtime cache settings always take precedence.
option(AETHERKIRI_RUNTIMES_DEFAULT "Enable supported runtimes by default" ON)
foreach(_aetherkiri_runtime IN ITEMS
        KRKR2 ARTEMIS_RUNTIME CATSYSTEM2 WA2 ONSCRIPTER SYSTEM3 XSYSTEM35
        XSYSTEM4 SIGLUS MAGES CMVS MINORI ENTISGLS BGI SYSTEMC ESCUDE YURIS ADVHD
        EXHIBIT FLASH TYRANO RENPY)
    option(AETHERKIRI_ENABLE_${_aetherkiri_runtime}
        "Enable the ${_aetherkiri_runtime} runtime" ${AETHERKIRI_RUNTIMES_DEFAULT})
endforeach()
# NativeAOT supplies desktop and mobile hosts. Web has no supported host.
set(_aetherkiri_n2system_default ${AETHERKIRI_RUNTIMES_DEFAULT})
if(WEB OR EMSCRIPTEN)
    set(_aetherkiri_n2system_default OFF)
endif()
option(AETHERKIRI_ENABLE_N2SYSTEM "Enable the N2System NativeAOT runtime" ${_aetherkiri_n2system_default})
unset(_aetherkiri_n2system_default)

# These providers were opt-in before runtime selection was introduced.
option(AETHERKIRI_ENABLE_RFVP "Enable the experimental RFVP runtime" OFF)
option(AETHERKIRI_ENABLE_SOFTPAL_RUNTIME "Enable the SoftPal runtime" OFF)

# QLIE is available on native product builds with the private package.
set(_aetherkiri_qlie_default OFF)
if(AETHERKIRI_RUNTIMES_DEFAULT AND BUILD_GODOT_EXTENSION AND NOT (WEB OR EMSCRIPTEN))
    if(EXISTS "${AETHERKIRI_ELIQ_DIR}/cmake/AetherELIQConfig.cmake")
        set(_aetherkiri_qlie_default ON)
    endif()
endif()
if(NOT "$ENV{AETHERKIRI_ENABLE_QLIE}" STREQUAL "")
    set(_aetherkiri_qlie_default "$ENV{AETHERKIRI_ENABLE_QLIE}")
endif()
option(AETHERKIRI_ENABLE_QLIE "Enable the AetherELIQ QLIE runtime" ${_aetherkiri_qlie_default})
unset(_aetherkiri_qlie_default)
if(AETHERKIRI_ENABLE_QLIE AND (WEB OR EMSCRIPTEN))
    message(FATAL_ERROR "QLIE requires a native target. Disable AETHERKIRI_ENABLE_QLIE for Web.")
endif()

# WA2 has an independent provider target and does not require KiriKiri.
foreach(_aetherkiri_runtime IN ITEMS ARTEMIS_RUNTIME CATSYSTEM2)
    if(AETHERKIRI_ENABLE_${_aetherkiri_runtime} AND NOT AETHERKIRI_ENABLE_KRKR2)
        message(FATAL_ERROR
            "${_aetherkiri_runtime} requires KRKR2; disable it or enable KRKR2")
    endif()
endforeach()

set(_aetherkiri_enabled_runtimes "")
foreach(_aetherkiri_runtime IN ITEMS
        KRKR2 ARTEMIS_RUNTIME CATSYSTEM2 WA2 ONSCRIPTER SYSTEM3 XSYSTEM35
        XSYSTEM4 SIGLUS MAGES CMVS MINORI ENTISGLS BGI SYSTEMC ESCUDE YURIS ADVHD
        EXHIBIT FLASH TYRANO RENPY N2SYSTEM RFVP SOFTPAL_RUNTIME QLIE)
    if(AETHERKIRI_ENABLE_${_aetherkiri_runtime})
        list(APPEND _aetherkiri_enabled_runtimes ${_aetherkiri_runtime})
    endif()
endforeach()
message(STATUS "Enabled runtimes: ${_aetherkiri_enabled_runtimes}")
unset(_aetherkiri_enabled_runtimes)
unset(_aetherkiri_runtime)
