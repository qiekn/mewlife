// ----------------------------------------------------------------------------: ImGui SGPU renderer

Renderer :: struct {
    font_texture: Gpu_Texture;
    font_view: Gpu_Texture_View;
    sampler: Gpu_Sampler;
    pipeline: Gpu_Pipeline;
    format: Format = .UNDEFINED;
    vertex_spv: [] u8;
    pixel_spv: [] u8;

    timeline: Gpu_Semaphore;
    submitted_value: u64;
    frame_cursor: int;
    frames: [3] Frame;
}

renderer_init :: (renderer: *Renderer) {
    #assert(size_of(ImGui.ImDrawVert) == 20);
    #assert(size_of(ImGui.ImDrawIdx) == 2);
    #assert(size_of(ImGui.ImDrawCallback) == size_of(s64));
    #assert(size_of(Vertex_Parameters) == 24);
    #assert(size_of(Draw_Parameters) == 32);

    io := ImGui.GetIO();
    assert(io.BackendRendererUserData == null);
    io.BackendRendererName = "imgui_sgpu";
    io.BackendRendererUserData = renderer;
    io.BackendFlags_ |= .RendererHasVtxOffset;

    success, vertex_spv := compile_shader("assets/shaders/imgui_vs.slang");
    assert(success, "Failed to compile the ImGui vertex shader.");
    renderer.vertex_spv = vertex_spv;
    success=, pixel_spv := compile_shader("assets/shaders/imgui_ps.slang");
    assert(success, "Failed to compile the ImGui pixel shader.");
    renderer.pixel_spv = pixel_spv;

    renderer.timeline = gpu_create_semaphore(0);
    assert(renderer.timeline != 0);
    renderer.sampler = gpu_create_sampler(.{mip_lod_bias = 0, max_lod = 0}, "ImGui sampler");
    assert(renderer.sampler != 0);

    upload_font_atlas(renderer);
}

upload_font_atlas :: (renderer: *Renderer) {
    // DPI changes replace the atlas. Previous frames must stop sampling the old image first.
    gpu_wait_idle();
    if renderer.font_texture != 0 then gpu_free(renderer.font_texture);
    io := ImGui.GetIO();

    pixels: *u8;
    width, height: s32;
    io.Fonts.GetTexDataAsRGBA32(io.Fonts, *pixels, *width, *height);
    assert(pixels != null && width > 0 && height > 0);

    result, texture := gpu_create_texture(.{
        dimensions = .[xx width, xx height, 1],
        format = .R8G8B8A8_UNORM,
        usage = .SAMPLED | .TRANSFER_DST,
    }, label = "ImGui font atlas");
    assert(result == .SUCCESS && texture != 0);
    renderer.font_texture = texture;
    renderer.font_view = gpu_texture_view(texture);
    assert(renderer.font_view != 0);

    size := width.(s64) * height * 4;
    staging, staging_gpu := gpu_malloc(size);
    assert(staging != null && staging_gpu != 0);
    defer gpu_free(staging);
    memcpy(staging, pixels, size);

    queue := gpu_get_queue(.MAIN, 0);
    // Finish the initial layout transition before uploading on the same queue.
    gpu_queue_wait_idle(queue);
    result=, cmd := gpu_start_command_recording(queue);
    assert(result == .SUCCESS);
    result = gpu_copy_to_texture(cmd, texture, staging_gpu);
    assert(result == .SUCCESS);
    gpu_barrier(cmd, .TRANSFER, .PIXEL_SHADER);
    gpu_submit(cmd);
    gpu_queue_wait_idle(queue);

    io.Fonts.TexID = texture_id(renderer.font_view);
}

// Texture IDs are SGPU texture views. Images share the renderer's linear sampler.
// The caller keeps user textures alive until submissions using them have completed.
texture_id :: (view: Gpu_Texture_View) -> ImGui.ImTextureID {
    return cast(ImGui.ImTextureID) view.(u64);
}

// Call inside a render pass, after scene rendering. Signal the returned timeline
// in the submission containing cmd, including frames with no UI geometry.
render :: (renderer: *Renderer, cmd: Gpu_Command_Buffer,
                      target: Gpu_Texture_View, data: *ImGui.ImDrawData) -> Gpu_Timeline_Pair {
    renderer.submitted_value += 1;
    completion := Gpu_Timeline_Pair.{renderer.timeline, renderer.submitted_value};
    assert(data != null && data.Valid);

    if data.DisplaySize.x <= 0 || data.DisplaySize.y <= 0 || data.TotalVtxCount == 0 {
        return completion;
    }

    found, desc := gpu_texture_desc(target);
    assert(found);
    // Use the actual attachment size to avoid losing a pixel to fractional-DPI rounding.
    framebuffer_width := desc.dimensions[0].(s32);
    framebuffer_height := desc.dimensions[1].(s32);
    ensure_pipeline(renderer, desc.format);

    frame := *renderer.frames[renderer.frame_cursor];
    renderer.frame_cursor = (renderer.frame_cursor + 1) % renderer.frames.count;
    if frame.completion_value != 0 {
        gpu_wait_semaphore(.{renderer.timeline, frame.completion_value});
    }

    command_count: s64;
    for list_index: 0..data.CmdListsCount - 1 {
        command_count += data.CmdLists[list_index].CmdBuffer.Size;
    }

    vertex_bytes := data.TotalVtxCount.(s64) * size_of(ImGui.ImDrawVert);
    index_bytes := data.TotalIdxCount.(s64) * size_of(ImGui.ImDrawIdx);
    index_offset := align_forward(vertex_bytes, 16);
    parameters_offset := align_forward(index_offset + index_bytes, 16);
    required_size := parameters_offset + command_count * size_of(Draw_Parameters);
    if required_size > frame.capacity {
        if frame.cpu != null then gpu_free(frame.cpu);
        frame.capacity = max(required_size, max(frame.capacity * 2, 64 * 1024));
        cpu, gpu := gpu_malloc(frame.capacity);
        assert(cpu != null && gpu != 0, "Failed to allocate ImGui frame data.");
        frame.cpu = cpu;
        frame.gpu = gpu;
    }
    frame.completion_value = completion.value;

    set_render_state(renderer, cmd, framebuffer_width, framebuffer_height);

    // SGPU compiles Slang with VulkanInvertY, so the pre-inversion Y axis points up.
    scale := Vector2.{2.0 / data.DisplaySize.x, -2.0 / data.DisplaySize.y};
    translate := Vector2.{-1.0 - data.DisplayPos.x * scale.x, 1.0 - data.DisplayPos.y * scale.y};
    parameters := cast(*Draw_Parameters) (frame.cpu + parameters_offset);
    global_vertex_offset: s64;
    global_index_offset: s64;
    command_index: s64;

    for list_index: 0..data.CmdListsCount - 1 {
        list := data.CmdLists[list_index];
        memcpy(frame.cpu + global_vertex_offset * size_of(ImGui.ImDrawVert),
               list.VtxBuffer.Data, list.VtxBuffer.Size.(s64) * size_of(ImGui.ImDrawVert));
        memcpy(frame.cpu + index_offset + global_index_offset * size_of(ImGui.ImDrawIdx),
               list.IdxBuffer.Data, list.IdxBuffer.Size.(s64) * size_of(ImGui.ImDrawIdx));

        for draw_index: 0..list.CmdBuffer.Size - 1 {
            draw := *list.CmdBuffer.Data[draw_index];
            if draw.UserCallback != null {
                // ImDrawCallback_ResetRenderState is the sentinel pointer -8 in ImGui 1.89.6.
                if (cast(*s64) *draw.UserCallback).* == -8 {
                    set_render_state(renderer, cmd, framebuffer_width, framebuffer_height);
                } else {
                    draw.UserCallback(list, draw);
                }
                continue;
            }

            clip := draw.ClipRect;
            x0 := clamp((clip.x - data.DisplayPos.x) * data.FramebufferScale.x, 0.0, framebuffer_width.(float));
            y0 := clamp((clip.y - data.DisplayPos.y) * data.FramebufferScale.y, 0.0, framebuffer_height.(float));
            x1 := clamp((clip.z - data.DisplayPos.x) * data.FramebufferScale.x, 0.0, framebuffer_width.(float));
            y1 := clamp((clip.w - data.DisplayPos.y) * data.FramebufferScale.y, 0.0, framebuffer_height.(float));
            if x1 <= x0 || y1 <= y0 || draw.ElemCount == 0 then continue;

            gpu_set_scissor(cmd, .{xx x0, xx y0, cast(u32) x1 - cast(u32) x0, cast(u32) y1 - cast(u32) y0});

            vertex_offset := (global_vertex_offset + draw.VtxOffset) * size_of(ImGui.ImDrawVert);
            parameters[command_index] = .{
                vertex = .{frame.gpu + vertex_offset.(Gpu_Ptr), scale, translate},
                pixel = .{cast(Gpu_Texture_View) draw.TextureId.(u64), renderer.sampler},
            };
            vertex_parameters := frame.gpu + cast(Gpu_Ptr) (parameters_offset + command_index * size_of(Draw_Parameters));
            pixel_parameters := vertex_parameters + cast(Gpu_Ptr) size_of(Vertex_Parameters);
            indices := frame.gpu + cast(Gpu_Ptr) (index_offset + (global_index_offset + draw.IdxOffset) * size_of(ImGui.ImDrawIdx));
            result := gpu_draw_indexed_instanced(cmd, vertex_parameters, pixel_parameters, indices,
                                                draw.ElemCount, 1, index_size = size_of(ImGui.ImDrawIdx));
            assert(result == .SUCCESS);
            command_index += 1;
        }
        global_vertex_offset += list.VtxBuffer.Size;
        global_index_offset += list.IdxBuffer.Size;
    }

    gpu_set_scissor(cmd, .{0, 0, xx framebuffer_width, xx framebuffer_height});
    return completion;
}

renderer_shutdown :: (renderer: *Renderer) {
    gpu_wait_idle();
    for renderer.frames {
        if it.cpu != null then gpu_free(it.cpu);
    }
    if renderer.pipeline != 0 then gpu_free_pipeline(renderer.pipeline);
    gpu_free(renderer.font_texture);
    gpu_free(renderer.sampler);
    gpu_destroy_semaphore(renderer.timeline);
    free(renderer.vertex_spv.data);
    free(renderer.pixel_spv.data);

    io := ImGui.GetIO();
    io.Fonts.TexID = null;
    io.BackendRendererName = null;
    io.BackendRendererUserData = null;
    io.BackendFlags_ &= ~ImGui.BackendFlags.RendererHasVtxOffset;
    renderer.* = .{};
}

#scope_file

Frame :: struct {
    cpu: *u8;
    gpu: Gpu_Ptr;
    capacity: s64;
    completion_value: u64;
}

Vertex_Parameters :: struct {
    vertices: Gpu_Ptr;
    scale: Vector2;
    translate: Vector2;
}

Draw_Parameters :: struct {
    vertex: Vertex_Parameters;
    pixel: struct {
        texture: Gpu_Texture_View;
        sampler: Gpu_Sampler;
    };
}

ensure_pipeline :: (renderer: *Renderer, format: Format) {
    if renderer.pipeline != 0 && renderer.format == format then return;
    if renderer.pipeline != 0 {
        gpu_wait_idle();
        gpu_free_pipeline(renderer.pipeline);
    }
    blend := Gpu_Blend_Desc.{
        src_color_factor = .SRC_ALPHA,
        dst_color_factor = .ONE_MINUS_SRC_ALPHA,
        src_alpha_factor = .ONE,
        dst_alpha_factor = .ONE_MINUS_SRC_ALPHA,
    };
    renderer.pipeline = gpu_create_graphics_pipeline(renderer.vertex_spv, renderer.pixel_spv, .{
        cull = .NONE,
        color_targets = .[.{format = format}],
        blend_state = *blend,
    }, "ImGui");
    assert(renderer.pipeline != 0);
    renderer.format = format;
}

set_render_state :: (renderer: *Renderer, cmd: Gpu_Command_Buffer, width: s32, height: s32) {
    result := gpu_set_pipeline(cmd, renderer.pipeline);
    assert(result == .SUCCESS);
    gpu_set_depth_stencil_state(cmd, .{
        depth_test = .NEVER,
        depth_mode = .NONE,
        stencil_front.test = .NEVER,
        stencil_back.test = .NEVER,
    });
    gpu_set_viewport(cmd, .{width = xx width, height = xx height, max_depth = 1});
    gpu_set_scissor(cmd, .{0, 0, xx width, xx height});
}

#import "Basic";
#import "Math";
