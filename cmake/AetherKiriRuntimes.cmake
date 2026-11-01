# Defaults preserve the full product. Disable the default to opt into only
# selected runtimes; explicit per-runtime cache options still take precedence.
option(AETHERKIRI_RUNTIMES_DEFAULT "Enable runtimes by default" ON)
foreach(_runtime KRKR2 ARTEMIS_RUNTIME CATSYSTEM2 WA2 QLIE ONSCRIPTER
                 SYSTEM3 XSYSTEM35 XSYSTEM4 SIGLUS MAGES MINORI ENTISGLS BGI YURIS ADVHD FLASH
                 TYRANO RENPY)
    option(AETHERKIRI_ENABLE_${_runtime} "Enable the ${_runtime} runtime"
        ${AETHERKIRI_RUNTIMES_DEFAULT})
endforeach()
option(AETHERKIRI_ENABLE_RFVP "Enable the experimental RFVP runtime" OFF)
option(AETHERKIRI_ENABLE_SOFTPAL_RUNTIME "Enable the SoftPal runtime" OFF)
foreach(_runtime ARTEMIS_RUNTIME CATSYSTEM2 WA2)
    if(AETHERKIRI_ENABLE_${_runtime} AND NOT AETHERKIRI_ENABLE_KRKR2)
        message(FATAL_ERROR "${_runtime} currently requires KRKR2; disable it or enable KRKR2")
    endif()
endforeach()
set(_aetherkiri_enabled_runtimes "")
foreach(_runtime KRKR2 ARTEMIS_RUNTIME CATSYSTEM2 WA2 QLIE ONSCRIPTER
                 SYSTEM3 XSYSTEM35 XSYSTEM4 SIGLUS MAGES MINORI ENTISGLS BGI YURIS ADVHD FLASH
                 TYRANO RENPY RFVP SOFTPAL_RUNTIME)
    if(AETHERKIRI_ENABLE_${_runtime})
        list(APPEND _aetherkiri_enabled_runtimes ${_runtime})
    endif()
endforeach()
message(STATUS "Enabled runtimes: ${_aetherkiri_enabled_runtimes}")
