# Run after Cargo has resolved and built the embedded Android runtime. Its
# PCM backend uses the host audio device; a second device backend can bring
# an ABI-incompatible Oboe into the same native extension as KiriKiri.
execute_process(
    COMMAND "${CARGO_EXECUTABLE}" tree --locked --offline
        --manifest-path "${SIGLUS_RS_MANIFEST}"
        --target "${SIGLUS_RUST_TARGET}"
        --package siglus_scene_vm --edges normal,build --prefix none
    RESULT_VARIABLE tree_result
    OUTPUT_VARIABLE dependency_tree
    ERROR_VARIABLE tree_error)
if(NOT tree_result EQUAL 0)
    message(FATAL_ERROR "Could not verify Siglus Android audio dependencies: ${tree_error}")
endif()
if(dependency_tree MATCHES "(^|\n)(cpal|oboe|oboe-sys) v")
    message(FATAL_ERROR
        "Siglus Android runtime includes ${CMAKE_MATCH_2}. Its embedded PCM "
        "backend must use the host audio device without a second Oboe library.")
endif()
message(STATUS "Siglus Android audio dependencies: host PCM backend only")
