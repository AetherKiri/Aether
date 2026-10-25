# The pinned MPL-2.0 sources remain untouched. Host-specific adaptations live
# here and in rust/aetherkiri_host.rs and are applied to a build-tree copy.
function(rfvp_replace file before after)
    file(READ "${file}" content)
    string(FIND "${content}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "rfvp overlay no longer matches ${file}: ${before}")
    endif()
    string(REPLACE "${before}" "${after}" content "${content}")
    file(WRITE "${file}" "${content}")
endfunction()

function(aetherkiri_prepare_rfvp root rfvp_dir output)
    # This directory contains only generated copies, never the git submodule.
    if(NOT output STREQUAL "${CMAKE_CURRENT_BINARY_DIR}/prepared")
        message(FATAL_ERROR "Refusing to refresh rfvp sources outside its build directory")
    endif()
    file(REMOVE_RECURSE "${output}/crates")
    foreach(crate rfvp rfvp-bitmap na_wmv_player na_mpeg2_decoder anzu-hal)
        file(COPY "${rfvp_dir}/crates/${crate}"
             DESTINATION "${output}/crates"
             PATTERN "target" EXCLUDE PATTERN "fonts" EXCLUDE)
    endforeach()
    file(COPY "${rfvp_dir}/LICENSE" "${rfvp_dir}/README.md"
         DESTINATION "${output}")
    file(WRITE "${output}/Cargo.toml"
        "[workspace]\nresolver = \"3\"\nmembers = [\"crates/*\"]\n[profile.dev]\ndebug = 0\nopt-level = 1\nincremental = false\n[profile.dev.package.rfvp]\nopt-level = 3\n[profile.release]\ndebug = 0\nlto = \"thin\"\ncodegen-units = 1\n")
    configure_file("${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../Cargo.lock" "${output}/Cargo.lock" COPYONLY)
    # Keep the decoder exports compatible with the coexistence contract in #334.
    # Upstream now uses Rust 2024's unsafe attribute spelling.
    foreach(symbol create destroy decode get_frame)
        rfvp_replace("${output}/crates/na_wmv_player/src/ffi.rs"
            "#[unsafe(no_mangle)]\npub unsafe extern \"C\" fn wmv2_decoder_${symbol}"
            "#[unsafe(export_name = \"aether_rfvp_wmv2_decoder_${symbol}\")]\npub unsafe extern \"C\" fn wmv2_decoder_${symbol}")
    endforeach()
    set(src "${output}/crates/rfvp/src")
    rfvp_replace("${output}/crates/rfvp/Cargo.toml"
        "crate-type = [\"rlib\", \"cdylib\"]" "crate-type = [\"rlib\", \"staticlib\"]")
    file(COPY "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../rust/aetherkiri_host.rs" DESTINATION "${src}")
    file(APPEND "${src}/lib.rs" "\npub mod aetherkiri_host;\n")
    foreach(os ios android)
        rfvp_replace("${src}/lib.rs"
            "#[cfg(all(not(feature = \"no_std\"), target_os = \"${os}\"))]\nmod ${os}_host;"
            "#[cfg(all(feature = \"gpu-render\", target_os = \"${os}\"))]\nmod ${os}_host;")
    endforeach()
    rfvp_replace("${src}/utils/file.rs" "pub fn app_base_path() -> PathBuilder {"
        "pub fn app_base_path() -> PathBuilder {\n    if let Some(root) = crate::aetherkiri_host::game_root() { return PathBuilder { path_buff: root }; }")
    file(APPEND "${src}/utils/file.rs" "\npub fn save_base_path() -> PathBuilder {\n    PathBuilder { path_buff: crate::aetherkiri_host::save_root().expect(\"rfvp save root not installed\") }\n}\n")
    # Core installs an isolated RfvpStorage on SaveManager. Upstream now routes
    # both slot and global saves through that storage instead of app_base_path.
    # V1 drops active motions and text/VM wait linkage on load. Extend new RFVS
    # payloads with a V2 envelope without changing the original V1 wire layout.
    set(motion_src "${src}/subsystem/resources/motion_manager")
    foreach(file alpha normal_move rotation_move s2_move z_move v3d anim snow lip)
        file(READ "${motion_src}/${file}.rs" content)
        string(REGEX REPLACE "#\\[derive\\(([^)]*)\\)\\]"
            "#[derive(\\1, serde::Serialize, serde::Deserialize)]" content "${content}")
        file(WRITE "${motion_src}/${file}.rs" "${content}")
    endforeach()
    foreach(pair "alpha;AlphaMotionContainer" "normal_move;MoveMotionContainer"
            "rotation_move;RotationMotionContainer" "s2_move;ScaleMotionContainer"
            "z_move;ZMotionContainer" "snow;SnowMotionContainer" "lip;LipMotionContainer")
        list(GET pair 0 file)
        list(GET pair 1 type)
        rfvp_replace("${motion_src}/${file}.rs" "pub struct ${type} {"
            "#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]\npub struct ${type} {")
    endforeach()
    # live_end is only a new scan optimization, never part of the saved V2
    # wire format. Rebuild a conservative bound after loading older snapshots.
    foreach(pair "alpha;AlphaMotionContainer" "normal_move;MoveMotionContainer"
            "rotation_move;RotationMotionContainer" "s2_move;ScaleMotionContainer"
            "z_move;ZMotionContainer")
        list(GET pair 0 file)
        list(GET pair 1 type)
        rfvp_replace("${motion_src}/${file}.rs" "    live_end: usize,"
            "    #[serde(skip)]\n    live_end: usize,")
        file(APPEND "${motion_src}/${file}.rs"
            "\nimpl ${type} {\n    pub(crate) fn rebuild_host_motion_bounds(&mut self) {\n        self.live_end = self.motions.len();\n    }\n}\n")
    endforeach()
    rfvp_replace("${motion_src}/anim.rs" "#[derive(Debug, Default,"
        "#[derive(Debug, Default, Clone,")
    foreach(field flakes flake_ptrs)
        rfvp_replace("${motion_src}/snow.rs" "    pub ${field}:"
            "    #[serde(with = \"crate::subsystem::save_state::host_array\")]\n    pub ${field}:")
    endforeach()
    foreach(pair "motion_snapshot;subsystem/resources/motion_manager/mod.rs"
            "text_snapshot;subsystem/resources/text_manager.rs" "save_snapshot;subsystem/save_state.rs"
            "soft_render_host;soft_render/renderer.rs")
        list(GET pair 0 helper)
        list(GET pair 1 target)
        get_filename_component(target_dir "${src}/${target}" DIRECTORY)
        file(COPY "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../rust/${helper}.rs" DESTINATION "${target_dir}")
        file(APPEND "${src}/${target}" "\ninclude!(\"${helper}.rs\");\n")
    endforeach()
    rfvp_replace("${src}/soft_render/renderer.rs"
        "    framebuffer: SoftFramebuffer,\n    stats: SoftRendererStats,"
        "    framebuffer: SoftFramebuffer,\n    stats: SoftRendererStats,\n    host_gpu: Option<HostGpuRenderer>,")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "            stats: SoftRendererStats::default(),\n            additive: false,"
        "            stats: SoftRendererStats::default(),\n            host_gpu: None,\n            additive: false,")
    # Both consumers snapshot the previously displayed frame before the next
    # clear. Read GPU pixels once, and suppress both snapshots on read failure.
    rfvp_replace("${src}/soft_render/renderer.rs"
        "        self.stats = SoftRendererStats::default();"
        "        self.stats = SoftRendererStats::default();\n        let host_snapshot_ready = !(self.wants_prev_frame || self.mask_frame.wants_snapshot(motion))\n            || self.sync_host_gpu_snapshot();")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "if self.mask_frame.wants_snapshot(motion) {"
        "if self.mask_frame.wants_snapshot(motion) && host_snapshot_ready {")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "self.prev_frame = if self.wants_prev_frame {"
        "self.prev_frame = if self.wants_prev_frame && host_snapshot_ready {")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "        self.framebuffer.clear_rgba(0, 0, 0, 255);"
        "        if !self.begin_host_gpu_motion_frame(motion) {\n            self.framebuffer.clear_rgba(0, 0, 0, 255);\n        }")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "        let graphs = motion.graphs();\n        let snow_motions = motion.snow_motions();"
        "        let graphs = motion.graphs();\n        self.prune_host_gpu_graphs(graphs);\n        let snow_motions = motion.snow_motions();")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "        }\n\n        Ok(())\n    }\n\n    fn dissolve_color"
        "        }\n\n        self.finish_host_gpu_frame();\n        Ok(())\n    }\n\n    fn dissolve_color")
    rfvp_replace("${src}/soft_render/renderer.rs"
        "        self.raster_triangle(v0, v1, v2, texture);\n        self.raster_triangle(v2, v1, v3, texture);"
        "        if !self.try_host_gpu_quad(v0, v1, v2, v3, texture) {\n            self.raster_triangle(v0, v1, v2, texture);\n            self.raster_triangle(v2, v1, v3, texture);\n        }")
    # The common axis-aligned case needs one clipped rectangle, not two
    # overlapping triangle scans. Keep rotated/sheared quads on the old path.
    rfvp_replace("${src}/soft_render/renderer.rs"
        "        let p0 = model.transform_point3(vec3(0.0, dst_h, 0.0)).truncate();"
        "        if color.w <= 0.0 { return Ok(()); }\n        let p0 = model.transform_point3(vec3(0.0, dst_h, 0.0)).truncate();")
    rfvp_replace("${src}/soft_render/renderer.rs" "        let v0 = Vertex {"
        "        if self.try_host_axis_quad(p1, p3, p0, uv0, uv1, color, texture) {\n            self.stats.quad_count += 1;\n            self.stats.draw_calls += 1;\n            return Ok(());\n        }\n        let v0 = Vertex {")
    # Console sparse IDs are absent from the historical desktop bincode layout.
    # serde(default) alone still consumes a positional field, so skip them here.
    rfvp_replace("${src}/subsystem/resources/prim.rs"
        "    #[serde(default)]\n    pub ids: Vec<u16>,"
        "    #[serde(skip)]\n    pub ids: Vec<u16>,")
    set(save_state "${src}/subsystem/save_state.rs")
    rfvp_replace("${save_state}" "pub struct SaveStateSnapshotV1 {"
        "pub struct SaveStateSnapshotV1 {\n    #[serde(skip)]\n    pub(crate) host_playback: Option<HostPlaybackSnapshot>,")
    rfvp_replace("${save_state}" "        SaveStateSnapshotV1 {\n            version: 1,"
        "        SaveStateSnapshotV1 {\n            host_playback: Some(HostPlaybackSnapshot::capture(game_data)),\n            version: 1,")
    rfvp_replace("${save_state}" "        tm.apply_snapshot_v1(&self.vm);"
        "        tm.apply_snapshot_v1(&self.vm);\n        if let Some(playback) = &self.host_playback { playback.apply(game_data); }")
    # Preserve Aether's RFVS V1/V2 envelope while upstream shares its codec
    # with no_std builds. The helper retains the bounded desktop bincode layout.
    rfvp_replace("${save_state}" "snapshot_codec::encode(snap)" "encode_host_snapshot(snap)")
    rfvp_replace("${save_state}" "snapshot_codec::decode(payload)" "decode_host_snapshot(payload)")
    # Video extraction is host-owned too; never create caches in the game tree
    # or fall back to the process working directory.
    rfvp_replace("${src}/subsystem/resources/videoplayer/threaded.rs"
        "let preferred = app_base_path()" "let preferred = crate::utils::file::save_base_path()")
    rfvp_replace("${src}/subsystem/resources/videoplayer/threaded.rs"
        "std::env::current_dir()\n        .unwrap_or_else(|_| PathBuf::from(\".\"))"
        "crate::utils::file::save_base_path().get_path().clone()")
    file(APPEND "${src}/subsystem/components/syscalls/legacy.rs" [=[

pub fn reset_host_state() {
    LEGACY_CHR_TABLE.lock().unwrap().clear();
    LEGACY_TEXT_STATE.lock().unwrap().clear();
    *LEGACY_CONFIG_STATE.lock().unwrap() = LegacyConfigState::default();
    *LEGACY_UI_STATE.lock().unwrap() = LegacyUiState::default();
}
]=])
    # Never embed the upstream Microsoft fonts. Reuse AetherKiri's OFL font.
    file(MAKE_DIRECTORY "${src}/subsystem/resources/fonts")
    configure_file("${root}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf"
        "${src}/subsystem/resources/fonts/aetherkiri.otf" COPYONLY)
    foreach(font MSGOTHIC.TTF MSMINCHO.TTF MS-PGothic.ttf MS-PMincho-2.ttf)
        rfvp_replace("${src}/subsystem/resources/text_manager.rs"
            "include_bytes!(\"./fonts/${font}\")" "include_bytes!(\"./fonts/aetherkiri.otf\")")
    endforeach()
    rfvp_replace("${src}/subsystem/resources/text_manager.rs"
        "impl FontEnumerator {\n    pub fn new() -> Self {"
        "impl FontEnumerator {\n    pub fn set_host_font(&mut self, font: Font) {\n        self.default_font = font.clone(); self.sys_ms_gothic = font.clone();\n        self.sys_ms_mincho = font.clone(); self.sys_ms_pgothic = font.clone(); self.sys_ms_pmincho = font;\n    }\n    pub fn new() -> Self {")
    rfvp_replace("${src}/subsystem/resources/input_manager.rs"
        "impl InputManager {\n    pub fn new() -> Self {"
        "impl InputManager {\n    pub fn cancel_host_input(&mut self) {\n        let (mask, x, y, inside) = (self.control_is_masked, self.get_cursor_x(), self.get_cursor_y(), self.get_cursor_in());\n        *self = Self::new(); self.control_is_masked = mask; self.notify_mouse_move(x, y); self.set_mouse_in(inside);\n    }\n    pub fn new() -> Self {")
    set(video_src "${src}/subsystem/resources/videoplayer")
    file(COPY "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../rust/video_host.rs"
        DESTINATION "${video_src}")
    file(APPEND "${video_src}/mod.rs" "\ninclude!(\"video_host.rs\");\n")
    rfvp_replace("${video_src}/mod.rs" "pub trait MovieSource: Send + Sync {"
        "pub trait MovieSource: Send + Sync {\n    fn pause_host(&mut self, paused: bool, elapsed: std::time::Duration);")
    foreach(backend threaded inline)
        set(playbacks Wmv Mpeg)
        if(backend STREQUAL "threaded")
            list(APPEND playbacks Mp4)
        endif()
        foreach(playback IN LISTS playbacks)
            rfvp_replace("${video_src}/${backend}.rs" "impl MovieSource for ${playback}Playback {"
                "impl MovieSource for ${playback}Playback {\n    fn pause_host(&mut self, paused: bool, elapsed: std::time::Duration) {\n        super::resume_host_clock(&mut self.started_at, paused, elapsed);\n    }")
        endforeach()
    endforeach()
    # Keep one mixer track for host pause/resume, including retiring fade-outs
    # whose handles are no longer in the live channel map. Upstream's one-track
    # capacity is sufficient; streamed sounds and its memory savings stay intact.
    rfvp_replace("${src}/rfvp_audio/mod.rs" "pub trait AudioBackend: Send + Sync {"
        "pub trait AudioBackend: Send + Sync {\n    fn pause_host(&self, _paused: bool) {}")
    set(kira_src "${src}/rfvp_audio/kira.rs")
    rfvp_replace("${kira_src}" "    manager: Mutex<KiraAudioManager>,"
        "    manager: Mutex<KiraAudioManager>,\n    host_track: Mutex<kira::track::TrackHandle>,")
    rfvp_replace("${kira_src}" "        let manager = KiraAudioManager::new(settings).expect(\"failed to create Kira AudioManager\");"
        "        let mut manager = KiraAudioManager::new(settings).expect(\"failed to create Kira AudioManager\");\n        let host_track = manager.add_sub_track(kira::track::TrackBuilder::new())\n            .expect(\"failed to create host audio track\");")
    rfvp_replace("${kira_src}" "            manager: Mutex::new(manager),"
        "            manager: Mutex::new(manager),\n            host_track: Mutex::new(host_track),")
    rfvp_replace("${kira_src}" "            self.manager\n                .lock()"
        "            self.host_track\n                .lock()")
    rfvp_replace("${kira_src}" "impl AudioBackend for KiraBackend {" [=[
impl AudioBackend for KiraBackend {
    fn pause_host(&self, paused: bool) {
        let mut track = self.host_track.lock().unwrap_or_else(|poison| poison.into_inner());
        if paused { track.pause(kira::Tween::default()); }
        else { track.resume(kira::Tween::default()); }
    }
]=])

# Keep slot banks heap-backed as in the previous overlay. Although the new
# Channels arrays are smaller than the deleted Kira handle arrays, their large
# temporary copies need not consume the host's small async-startup stack.
    set(channels_src "${src}/audio_player/channels.rs")
    rfvp_replace("${channels_src}" "use alloc::string::String;"
        "use alloc::boxed::Box;\nuse alloc::string::String;")
    foreach(type "Option<SoundSource>" "Option<String>" "Option<i32>" bool f32 f64)
        rfvp_replace("${channels_src}" "[${type}; N]" "Box<[${type}]>")
    endforeach()
    rfvp_replace("${channels_src}" "[(); N].map(|_| None)"
        "(0..N).map(|_| None).collect::<Vec<_>>().into_boxed_slice()")
    foreach(value None false 1.0 0.5)
        rfvp_replace("${channels_src}" "[${value}; N]"
            "alloc::vec![${value}; N].into_boxed_slice()")
    endforeach()

endfunction()
