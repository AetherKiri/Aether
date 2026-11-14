# The normal product keeps every currently supported runtime enabled. A fresh
# selective build can turn the default off and opt into individual runtimes;
# explicit per-runtime cache settings always take precedence.
option(AETHERKIRI_RUNTIMES_DEFAULT "Enable supported runtimes by default" ON)
foreach(_aetherkiri_runtime IN ITEMS
        KRKR2 ARTEMIS_RUNTIME CATSYSTEM2 WA2 ONSCRIPTER SYSTEM3 XSYSTEM35
        XSYSTEM4 SIGLUS MAGES MINORI ENTISGLS BGI SYSTEMC ESCUDE YURIS ADVHD
        FLASH TYRANO RENPY)
    option(AETHERKIRI_ENABLE_${_aetherkiri_runtime}
        "Enable the ${_aetherkiri_runtime} runtime" ${AETHERKIRI_RUNTIMES_DEFAULT})
endforeach()
# NativeAOT embeds the desktop CLR runtime. Mobile and Web targets have no
# supported host yet, so their default remains off even in full product builds.
set(_aetherkiri_n2system_default ${AETHERKIRI_RUNTIMES_DEFAULT})
if(IOS OR ANDROID OR WEB OR EMSCRIPTEN)
    set(_aetherkiri_n2system_default OFF)
endif()
option(AETHERKIRI_ENABLE_N2SYSTEM "Enable the desktop N2System NativeAOT runtime" ${_aetherkiri_n2system_default})
unset(_aetherkiri_n2system_default)

# These providers were opt-in before runtime selection was introduced.
option(AETHERKIRI_ENABLE_RFVP "Enable the experimental RFVP runtime" OFF)
option(AETHERKIRI_ENABLE_SOFTPAL_RUNTIME "Enable the SoftPal runtime" OFF)

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
        XSYSTEM4 SIGLUS MAGES MINORI ENTISGLS BGI SYSTEMC ESCUDE YURIS ADVHD
        FLASH TYRANO RENPY N2SYSTEM RFVP SOFTPAL_RUNTIME)
    if(AETHERKIRI_ENABLE_${_aetherkiri_runtime})
        list(APPEND _aetherkiri_enabled_runtimes ${_aetherkiri_runtime})
    endif()
endforeach()
message(STATUS "Enabled runtimes: ${_aetherkiri_enabled_runtimes}")
unset(_aetherkiri_enabled_runtimes)
unset(_aetherkiri_runtime)
