// Included inside the GPU bridge's anonymous namespace. MAGES commands use
// the same ordered texture queue and the same RenderingDevice as presentation.
#if defined(AETHERKIRI_WITH_MAGES)
struct MagesGpuPipeline { RID shader; RID pipeline; };
std::unordered_map<std::string, MagesGpuPipeline> g_mages_pipelines;
std::unordered_map<uint64_t, RID> g_mages_depth;

bool ExecuteMagesGpuDraw(RenderingDevice* rd, const std::shared_ptr<GodotGpuOp>& op) {
    if (rd == nullptr || op == nullptr || op->mages_draw == nullptr) {
        LogMagesGpu("draw_rejected", "null RenderingDevice, operation, or draw request");
        return false;
    }
    const auto& request = *op->mages_draw;
    if (ShouldLogMagesGpu("draw_begin")) {
        std::ostringstream start_log;
        start_log << "target_rid=" << op->dst.get_id()
              << " target=" << request.width << "x" << request.height
              << " vertices=" << request.vertex_count
              << " vertex_bytes=" << op->data.size()
              << " uniforms=" << request.uniforms.size()
              << " blend=" << request.blend
              << " depth_test=" << (request.depth_test ? 1 : 0)
              << " depth_write=" << (request.depth_write ? 1 : 0)
              << " cull=" << request.cull
              << " clip=" << request.clip[0] << "," << request.clip[1]
              << "," << request.clip[2] << "," << request.clip[3];
        LogMagesGpu("draw_begin", start_log.str());
    }
    if (!op->dst.is_valid() || request.vertex_count == 0 ||
        request.width == 0 || request.height == 0 || op->data.is_empty()) {
        LogMagesGpu("draw_rejected", "invalid request or RenderingDevice");
        return false;
    }
    std::vector<RID> transient;
    auto own = [&](RID rid) { if(rid.is_valid()) transient.push_back(rid); return rid; };
    struct Cleanup {
        RenderingDevice* rd;
        std::vector<RID>& resources;
        ~Cleanup() {
            for(auto it = resources.rbegin(); it != resources.rend(); ++it) {
                // Godot defers physical disposal until recorded GPU work has
                // completed, including resources from failed submissions.
                rd->free_rid(*it);
            }
        }
    } cleanup{rd, transient};
    TypedArray<RID> attachments;
    attachments.push_back(op->dst);
    if(request.depth_test) {
        auto& depth = g_mages_depth[op->dst.get_id()];
        if(!depth.is_valid()) {
            Ref<RDTextureFormat> format; format.instantiate();
            format->set_format(RenderingDevice::DATA_FORMAT_D32_SFLOAT);
            format->set_width(request.width); format->set_height(request.height);
            format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
            Ref<RDTextureView> view; view.instantiate();
            depth = rd->texture_create(format,view);
        }
        if(!depth.is_valid()) return false;
        attachments.push_back(depth);
    }
    RID framebuffer = own(rd->framebuffer_create(attachments));
    if(!framebuffer.is_valid()) {
        LogMagesGpu("framebuffer_failed", "framebuffer_create returned invalid RID");
        return false;
    }
    std::string key = request.vertex_source + request.fragment_source +
        std::to_string(request.blend) + ":" + std::to_string(request.cull) + ":" +
        std::to_string(request.depth_write) + ":" + std::to_string(rd->framebuffer_get_format(framebuffer));
    auto cached = g_mages_pipelines.find(key);
    MagesGpuPipeline program;
    if(cached != g_mages_pipelines.end()) {
        program = cached->second;
    } else {
        Ref<RDShaderSource> source;
        source.instantiate();
        source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
        source->set_stage_source(RenderingDevice::SHADER_STAGE_VERTEX, String(request.vertex_source.c_str()));
        source->set_stage_source(RenderingDevice::SHADER_STAGE_FRAGMENT, String(request.fragment_source.c_str()));
        Ref<RDShaderSPIRV> spirv = rd->shader_compile_spirv_from_source(source);
        for(auto stage : {RenderingDevice::SHADER_STAGE_VERTEX, RenderingDevice::SHADER_STAGE_FRAGMENT}) {
            if(spirv.is_null() || !spirv->get_stage_compile_error(stage).is_empty()) {
                if(spirv.is_valid()) {
                    const std::string error = spirv->get_stage_compile_error(stage).utf8().get_data();
                    LogMagesGpu("shader_compile_failed", error);
                    UtilityFunctions::push_error("MAGES GPU shader: ", spirv->get_stage_compile_error(stage));
                }
                return false;
            }
        }
        program.shader = rd->shader_create_from_spirv(spirv, "AetherMages");
        if(!program.shader.is_valid()) return false;
        Ref<RDPipelineRasterizationState> raster;
        raster.instantiate(); raster->set_cull_mode(request.cull == 1 ? RenderingDevice::POLYGON_CULL_BACK :
            request.cull == 2 ? RenderingDevice::POLYGON_CULL_FRONT : RenderingDevice::POLYGON_CULL_DISABLED);
        raster->set_front_face(RenderingDevice::POLYGON_FRONT_FACE_COUNTER_CLOCKWISE);
        Ref<RDPipelineMultisampleState> multisample; multisample.instantiate();
        Ref<RDPipelineDepthStencilState> depth; depth.instantiate();
        depth->set_enable_depth_test(request.depth_test);
        depth->set_enable_depth_write(request.depth_write);
        depth->set_depth_compare_operator(RenderingDevice::COMPARE_OP_LESS);
        Ref<RDPipelineColorBlendStateAttachment> blend; blend.instantiate();
        blend->set_enable_blend(request.blend != 3);
        blend->set_src_color_blend_factor(request.blend == 2
            ? RenderingDevice::BLEND_FACTOR_ONE : RenderingDevice::BLEND_FACTOR_SRC_ALPHA);
        blend->set_dst_color_blend_factor(request.blend == 1
            ? RenderingDevice::BLEND_FACTOR_ONE : RenderingDevice::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
        blend->set_color_blend_op(RenderingDevice::BLEND_OP_ADD);
        blend->set_src_alpha_blend_factor(RenderingDevice::BLEND_FACTOR_ONE);
        blend->set_dst_alpha_blend_factor(request.blend == 2 || request.blend == 4
            ? RenderingDevice::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : RenderingDevice::BLEND_FACTOR_ONE);
        blend->set_alpha_blend_op(RenderingDevice::BLEND_OP_ADD);
        blend->set_write_r(true); blend->set_write_g(true); blend->set_write_b(true); blend->set_write_a(true);
        TypedArray<Ref<RDPipelineColorBlendStateAttachment>> blend_attachments;
        blend_attachments.push_back(blend);
        Ref<RDPipelineColorBlendState> color; color.instantiate(); color->set_attachments(blend_attachments);
        program.pipeline = rd->render_pipeline_create(program.shader, rd->framebuffer_get_format(framebuffer), -1,
            RenderingDevice::RENDER_PRIMITIVE_TRIANGLES, raster, multisample, depth, color);
        if(!program.pipeline.is_valid()) {
            LogMagesGpu("pipeline_failed", "render_pipeline_create returned invalid RID");
            rd->free_rid(program.shader);
            return false;
        }
        g_mages_pipelines.emplace(std::move(key), program);
    }
    RID vertices = own(rd->storage_buffer_create(uint32_t(op->data.size()), op->data));
    RID params = own(rd->uniform_buffer_create(uint32_t(request.uniforms.size()), request.uniforms));
    if(!vertices.is_valid() || !params.is_valid()) {
        LogMagesGpu("buffer_failed", "vertex or parameter buffer creation failed");
        return false;
    }
    TypedArray<RDUniform> uniforms;
    auto bind = [&](int binding, RenderingDevice::UniformType type, RID resource, RID texture = RID()) {
        Ref<RDUniform> uniform; uniform.instantiate();
        uniform->set_binding(binding); uniform->set_uniform_type(type); uniform->add_id(resource);
        if(texture.is_valid()) uniform->add_id(texture);
        uniforms.push_back(uniform);
    };
    bind(0, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, vertices);
    bind(1, RenderingDevice::UNIFORM_TYPE_UNIFORM_BUFFER, params);
    Ref<RDSamplerState> state; state.instantiate();
    state->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    state->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    state->set_repeat_u(request.repeat ? RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT : RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    state->set_repeat_v(request.repeat ? RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT : RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    RID sampler = own(rd->sampler_create(state));
    if(!sampler.is_valid()) {
        LogMagesGpu("sampler_failed", "sampler_create returned invalid RID");
        return false;
    }
    for(int i = 0; i < 4; ++i) {
        std::string declaration = "binding=" + std::to_string(i+2) + ")";
        if(request.fragment_source.find(declaration) == std::string::npos) continue;
        RID texture = request.textures[i];
        if (ShouldLogMagesGpu("bind_texture")) {
            std::ostringstream texture_log;
            texture_log << "slot=" << i << " binding=" << (i + 2)
                        << " texture_rid=" << texture.get_id()
                        << " alias_target=" << (texture == op->dst ? 1 : 0)
                        << " declaration=" << declaration;
            LogMagesGpu("bind_texture", texture_log.str());
        }
        if(texture == op->dst) {
            Ref<RDTextureView> view; view.instantiate();
            TypedArray<PackedByteArray> initial;
            RID copy = own(rd->texture_create(MakeRgbaTextureFormat(request.width,request.height), view, initial));
            if(!copy.is_valid() || rd->texture_copy(texture,copy,Vector3(),Vector3(),
                Vector3(request.width,request.height,1),0,0,0,0) != OK) {
                LogMagesGpu("alias_copy_failed", "texture_copy failed for read/write alias");
                return false;
            }
            texture = copy;
        }
        bind(i+2, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, sampler, texture);
    }
    RID uniform_set = own(rd->uniform_set_create(uniforms, program.shader, 0));
    if(!uniform_set.is_valid()) {
        LogMagesGpu("uniform_set_failed", "uniform_set_create returned invalid RID");
        return false;
    }
    int64_t list = rd->draw_list_begin(framebuffer,
        request.clear_depth ? RenderingDevice::DRAW_CLEAR_DEPTH : RenderingDevice::DRAW_DEFAULT_ALL,
        PackedColorArray(), 1.0f);
    if(list < 0) {
        LogMagesGpu("draw_list_failed", "draw_list_begin returned invalid list");
        return false;
    }
    rd->draw_list_bind_render_pipeline(list,program.pipeline);
    rd->draw_list_bind_uniform_set(list,uniform_set,0);
    rd->draw_list_enable_scissor(list, Rect2(request.clip[0],request.clip[1],
        request.clip[2]-request.clip[0],request.clip[3]-request.clip[1]));
    rd->draw_list_draw(list,false,1,request.vertex_count);
    rd->draw_list_end();
    ApplyGodotGpuBarrier(rd);
    if (ShouldLogMagesGpu("draw_submitted")) {
        LogMagesGpu("draw_submitted", "draw_list_end completed");
    }
    return true;
}
#endif
