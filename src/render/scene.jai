// ----------------------------------------------------------------------------: Scene rendering, independent of game rules

Render_Geometry :: enum u32 { CUBE; MODEL; }
Render_Surface :: enum u32 { LIT; CRYSTAL; UNLIT; }

Render_Item :: struct {
    geometry: Render_Geometry;
    model_id: u32;
    skinning: [] Matrix4;
    transform: Matrix4 = Matrix4_Identity;
    color: Vector4 = #run color_rgb(0xffffff);
    surface: Render_Surface;
    rim_color: Vector3 = #run color_rgb(0xffffff).xyz;
    emissive: float;
    outline_width: float; // Logical pixels; the host supplies framebuffer scale.
    outline_distance: float = 6; // Full thickness nearby, smoothly thinner in distant game views.
    outline_color: Vector4 = #run color_rgb(0x010102);
}

Scene_Renderer :: struct {
    models: [..] Scene_Model;
    cube: Scene_Mesh;
    textures: [..] Scene_Texture;
    sampler: Gpu_Sampler;
    pipeline, outline_pipeline: Gpu_Pipeline;
    format: Format = .UNDEFINED;
    vertex_spv, pixel_spv: [] u8;
    depth: Gpu_Texture;
    depth_view: Gpu_Texture_View;
    width, height: u32;
    timeline: Gpu_Semaphore;
    submitted_value: u64;
    frames: [3] Scene_Frame;
    frame_cursor: int;
    draw_count, triangle_count: u32;
}

scene_init :: (renderer: *Scene_Renderer) {
    #assert(size_of(Scene_Vertex_Parameters) == 240);
    #assert(size_of(Scene_Pixel_Parameters) == 64);
    #assert(size_of(Scene_Draw_Parameters) == 304);
    #assert(size_of(Scene_Instance) == 144);
    success: bool;
    success, renderer.vertex_spv = compile_shader("assets/shaders/scene_vs.slang");
    assert(success, "Failed to compile the scene vertex shader.");
    success, renderer.pixel_spv = compile_shader("assets/shaders/scene_ps.slang");
    assert(success, "Failed to compile the scene pixel shader.");
    renderer.timeline = gpu_create_semaphore(0);
    renderer.sampler = gpu_create_sampler(.{mip_lod_bias = 0, max_lod = 0}, "Scene sampler");
    assert(renderer.timeline != 0 && renderer.sampler != 0);
    renderer.cube = scene_make_cube();
}

// CPU assets must outlive the renderer. Static and skinned models share the same upload path.
scene_add_model :: (renderer: *Scene_Renderer, model: *Model_Asset, asset_directory: string) -> u32 {
    uploaded := Scene_Model.{asset = model, mesh = scene_upload_mesh(model.vertices, model.indices),
                             part_views = NewArray(model.parts.count, Gpu_Texture_View)};
    for part: model.parts {
        if !part.texture_path then continue;
        path := tprint("%/%", asset_directory, part.texture_path);
        view: Gpu_Texture_View;
        for texture: renderer.textures {
            if texture.path == path { view = texture.view; break; }
        }
        if view == 0 {
            texture := scene_load_texture(path);
            texture.path = copy_string(path);
            view = texture.view;
            array_add(*renderer.textures, texture);
        }
        uploaded.part_views[it_index] = view;
    }
    id := cast(u32) renderer.models.count;
    array_add(*renderer.models, uploaded);
    return id;
}

// Call before command recording: changing attachment size or format retires the old resources.
scene_prepare_target :: (renderer: *Scene_Renderer, target: Gpu_Texture_View) {
    found, desc := gpu_texture_desc(target);
    assert(found);
    if renderer.pipeline == 0 || renderer.format != desc.format {
        gpu_wait_idle();
        if renderer.pipeline != 0 then gpu_free_pipeline(renderer.pipeline);
        if renderer.outline_pipeline != 0 then gpu_free_pipeline(renderer.outline_pipeline);
        blend: Gpu_Blend_Desc;
        renderer.pipeline = gpu_create_graphics_pipeline(renderer.vertex_spv, renderer.pixel_spv, .{
            cull = .NONE,
            depth_format = .D32_SFLOAT,
            color_targets = .[.{format = desc.format}],
            blend_state = *blend,
        }, "Scene");
        renderer.outline_pipeline = gpu_create_graphics_pipeline(renderer.vertex_spv, renderer.pixel_spv, .{
            cull = .CCW, // SGPU maps CCW to Vulkan front-face culling.
            depth_format = .D32_SFLOAT,
            color_targets = .[.{format = desc.format}],
            blend_state = *blend,
        }, "Scene outlines");
        assert(renderer.pipeline != 0 && renderer.outline_pipeline != 0);
        renderer.format = desc.format;
    }
    if renderer.width != desc.dimensions[0] || renderer.height != desc.dimensions[1] {
        gpu_wait_idle();
        if renderer.depth != 0 then gpu_free(renderer.depth);
        result: Gpu_Result;
        result, renderer.depth = gpu_create_texture(.{
            dimensions = .[desc.dimensions[0], desc.dimensions[1], 1],
            format = .D32_SFLOAT,
            usage = .DEPTH_STENCIL_ATTACHMENT,
        }, label = "Scene depth");
        assert(result == .SUCCESS && renderer.depth != 0);
        renderer.depth_view = gpu_texture_view(renderer.depth);
        renderer.width = desc.dimensions[0];
        renderer.height = desc.dimensions[1];
    }
}

// Records a complete depth-tested pass. Signal its completion with the final frame submission.
scene_render :: (renderer: *Scene_Renderer, cmd: Gpu_Command_Buffer, target: Gpu_Texture_View,
                 camera: *Camera, items: [] Render_Item, background: Vector4,
                 pixel_scale: float = 1, batch_cubes: bool = true) -> Gpu_Timeline_Pair {
    assert(renderer.depth != 0 && pixel_scale > 0);
    renderer.submitted_value += 1;
    completion := Gpu_Timeline_Pair.{renderer.timeline, renderer.submitted_value};
    frame := *renderer.frames[renderer.frame_cursor];
    renderer.frame_cursor = (renderer.frame_cursor + 1) % renderer.frames.count;
    if frame.completion_value != 0 then gpu_wait_semaphore(.{renderer.timeline, frame.completion_value});

    draw_count, joint_count, instance_count: s64;
    previous_cube: bool;
    for item: items {
        passes := ifx item.outline_width > 0 then 2 else 1;
        batched := batch_cubes && scene_batchable_cube(item);
        if item.geometry == .MODEL {
            assert(item.model_id < renderer.models.count);
            model := renderer.models[item.model_id].asset;
            assert(item.skinning.count == 0 || item.skinning.count == model.joints.count);
            for part: model.parts if !part.optional then draw_count += passes;
        } else {
            assert(item.skinning.count == 0);
            if batched {
                instance_count += 1;
                if !previous_cube then draw_count += 1;
            } else draw_count += passes;
        }
        previous_cube = batched;
        joint_count += item.skinning.count;
    }
    instances_offset := align_forward(joint_count * size_of(Matrix4), 16);
    parameters_offset := align_forward(instances_offset + instance_count * size_of(Scene_Instance), 16);
    required_size := max(16, parameters_offset + draw_count * size_of(Scene_Draw_Parameters));
    if frame.capacity < required_size {
        if frame.cpu != null then gpu_free(frame.cpu);
        frame.capacity = max(required_size, max(frame.capacity * 2, 64 * 1024));
        cpu, gpu := gpu_malloc(frame.capacity);
        assert(cpu != null && gpu != 0);
        frame.cpu = cpu;
        frame.gpu = gpu;
    }
    frame.completion_value = completion.value;
    palette_offset, instance_cursor: s64;
    instances := cast(*Scene_Instance) (frame.cpu + instances_offset);
    for item: items {
        bytes := item.skinning.count * size_of(Matrix4);
        if bytes > 0 then memcpy(frame.cpu + palette_offset, item.skinning.data, bytes);
        palette_offset += bytes;
        if batch_cubes && scene_batchable_cube(item) {
            ok, inverse_transform := inverse(item.transform);
            assert(ok);
            instances[instance_cursor] = .{item.transform, transpose(inverse_transform), item.color};
            instance_cursor += 1;
        }
    }
    parameters := cast(*Scene_Draw_Parameters) (frame.cpu + parameters_offset);
    view_projection := camera_view_projection(camera, renderer.width.(float) / renderer.height);
    renderer.draw_count = 0;
    renderer.triangle_count = 0;

    // The depth attachment is shared by queued frames on the same graphics queue.
    gpu_barrier(cmd, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS | .COLOR_ATTACHMENT_OUTPUT,
                    .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS | .COLOR_ATTACHMENT_OUTPUT);
    result := gpu_begin_render_pass(cmd, .{
        color_targets = .[.{view = target, load_op = .CLEAR, store_op = .STORE,
                           clear_color._float = background.component}],
        depth_target = .{view = renderer.depth_view, load_op = .CLEAR, store_op = .STORE, clear_value.depth = 1},
    });
    assert(result == .SUCCESS);
    // Finish opaque depth first, so hulls stay behind walls and other objects in either draw order.
    for pass: 0..1 {
        outline := pass == 1;
        assert(gpu_set_pipeline(cmd, ifx outline then renderer.outline_pipeline else renderer.pipeline) == .SUCCESS);
        gpu_set_depth_stencil_state(cmd, .{depth_test = ifx outline then .LESS_OR_EQUAL else .LESS,
                                          depth_mode = ifx outline then .READ else .WRITE,
                                          stencil_front.test = .NEVER, stencil_back.test = .NEVER});
        palette_offset = 0;
        instance_cursor = 0;
        item_index: s64;
        while item_index < items.count {
            item := items[item_index];
            item_index += 1;
            palette := frame.gpu + cast(Gpu_Ptr) palette_offset;
            palette_offset += item.skinning.count * size_of(Matrix4);
            if outline && item.outline_width <= 0 then continue;
            instance_data: Gpu_Ptr;
            draw_instances: u32 = 1;
            if !outline && batch_cubes && scene_batchable_cube(item) {
                instance_data = frame.gpu + cast(Gpu_Ptr) (instances_offset + instance_cursor * size_of(Scene_Instance));
                // Batch consecutive compatible cubes, preserving scene and depth-test order.
                while item_index < items.count && scene_batchable_cube(items[item_index]) {
                    draw_instances += 1;
                    item_index += 1;
                }
                instance_cursor += draw_instances;
            }
            mesh := *renderer.cube;
            uploaded: *Scene_Model;
            if item.geometry == .MODEL {
                uploaded = *renderer.models[item.model_id];
                mesh = *uploaded.mesh;
            }
            normal_transform := Matrix4_Identity;
            if instance_data == 0 {
                ok, inverse_transform := inverse(item.transform);
                assert(ok);
                normal_transform = transpose(inverse_transform);
            }
            base: Scene_Draw_Parameters;
            base.vertex = .{mesh.vertices, palette, instance_data, view_projection, item.transform, normal_transform,
                            cast(u32) (item.skinning.count > 0),
                            ifx outline then item.outline_width * pixel_scale else 0,
                            .{1.0 / renderer.width, 1.0 / renderer.height}, item.outline_distance,
                            cast(u32) (instance_data != 0)};
            base.pixel = .{color = item.color, eye = camera.position, sampler = renderer.sampler,
                           surface = item.surface, rim_color = item.rim_color, emissive = item.emissive};
            if instance_data != 0 then base.pixel.color = color_rgb(0xffffff);
            if outline { base.pixel.color = item.outline_color; base.pixel.surface = .UNLIT; }
            if uploaded != null {
                for part: uploaded.asset.parts {
                    if part.optional then continue;
                    p := base;
                    if !outline {
                        for 0..3 { p.pixel.color.component[it] *= part.color.component[it]; }
                        p.pixel.texture = uploaded.part_views[it_index];
                        p.pixel.textured = cast(u32) (p.pixel.texture != 0);
                    }
                    scene_draw(renderer, cmd, frame, parameters, parameters_offset, p,
                               mesh.indices + cast(Gpu_Ptr) (part.first_index * size_of(u32)), part.index_count);
                }
            } else {
                scene_draw(renderer, cmd, frame, parameters, parameters_offset, base,
                           mesh.indices, mesh.index_count, draw_instances);
            }
        }
    }
    gpu_end_render_pass(cmd);
    gpu_barrier(cmd, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_OUTPUT);
    return completion;
}

scene_shutdown :: (renderer: *Scene_Renderer) {
    gpu_wait_idle();
    for renderer.frames if it.cpu != null then gpu_free(it.cpu);
    for renderer.textures { gpu_free(it.texture); free(it.path); }
    array_free(renderer.textures);
    for renderer.models { gpu_free(it.mesh.cpu); free(it.part_views.data); }
    array_free(renderer.models);
    gpu_free(renderer.cube.cpu);
    if renderer.depth != 0 then gpu_free(renderer.depth);
    if renderer.pipeline != 0 then gpu_free_pipeline(renderer.pipeline);
    if renderer.outline_pipeline != 0 then gpu_free_pipeline(renderer.outline_pipeline);
    gpu_free(renderer.sampler);
    gpu_destroy_semaphore(renderer.timeline);
    free(renderer.vertex_spv.data);
    free(renderer.pixel_spv.data);
    renderer.* = .{};
}

#scope_file

Scene_Mesh :: struct { cpu: *u8; vertices, indices: Gpu_Ptr; index_count: u32; }
Scene_Model :: struct { asset: *Model_Asset; mesh: Scene_Mesh; part_views: [] Gpu_Texture_View; }
Scene_Texture :: struct { path: string; texture: Gpu_Texture; view: Gpu_Texture_View; }
Scene_Frame :: struct { cpu: *u8; gpu: Gpu_Ptr; capacity: s64; completion_value: u64; }
Scene_Instance :: struct { transform, normal_transform: Matrix4; color: Vector4; }

Scene_Vertex_Parameters :: struct {
    vertices, skinning, instances: Gpu_Ptr;
    view_projection, transform, normal_transform: Matrix4;
    skinned: u32;
    outline_width: float;
    inverse_viewport: Vector2;
    outline_distance: float;
    instanced: u32;
}
Scene_Pixel_Parameters :: struct {
    color: Vector4;
    eye: Vector3;
    texture: Gpu_Texture_View;
    sampler: Gpu_Sampler;
    surface: Render_Surface;
    textured, padding: u32;
    rim_color: Vector3;
    emissive: float;
}
Scene_Draw_Parameters :: struct { vertex: Scene_Vertex_Parameters; pixel: Scene_Pixel_Parameters; }

scene_batchable_cube :: (item: Render_Item) -> bool {
    return item.geometry == .CUBE && item.surface == .LIT && item.outline_width <= 0;
}

scene_draw :: (renderer: *Scene_Renderer, cmd: Gpu_Command_Buffer, frame: *Scene_Frame,
               parameters: *Scene_Draw_Parameters, offset: s64, p: Scene_Draw_Parameters,
               indices: Gpu_Ptr, count: u32, instance_count: u32 = 1) {
    parameters[renderer.draw_count] = p;
    vertex_gpu := frame.gpu + cast(Gpu_Ptr) (offset + renderer.draw_count * size_of(Scene_Draw_Parameters));
    pixel_gpu := vertex_gpu + cast(Gpu_Ptr) size_of(Scene_Vertex_Parameters);
    assert(gpu_draw_indexed_instanced(cmd, vertex_gpu, pixel_gpu, indices, count, instance_count) == .SUCCESS);
    renderer.draw_count += 1;
    renderer.triangle_count += count / 3 * instance_count;
}

scene_upload_mesh :: (vertices: [] Model_Vertex, indices: [] u32) -> Scene_Mesh {
    index_offset := align_forward(vertices.count * size_of(Model_Vertex), 16);
    cpu, gpu := gpu_malloc(index_offset + indices.count * size_of(u32));
    assert(cpu != null && gpu != 0);
    memcpy(cpu, vertices.data, vertices.count * size_of(Model_Vertex));
    memcpy(cast(*u8) cpu + index_offset, indices.data, indices.count * size_of(u32));
    return .{cast(*u8) cpu, gpu, gpu + cast(Gpu_Ptr) index_offset, xx indices.count};
}

scene_make_cube :: () -> Scene_Mesh {
    vertices: [24] Model_Vertex;
    indices: [36] u32;
    normals := Vector3.[.{1, 0, 0}, .{-1, 0, 0}, .{0, 1, 0}, .{0, -1, 0}, .{0, 0, 1}, .{0, 0, -1}];
    tangents := Vector3.[.{0, 0, -1}, .{0, 0, 1}, .{1, 0, 0}, .{1, 0, 0}, .{1, 0, 0}, .{-1, 0, 0}];
    corners := Vector2.[.{-1, -1}, .{1, -1}, .{1, 1}, .{-1, 1}];
    for face: 0..5 {
        normal := normals[face];
        tangent := tangents[face];
        up := cross(normal, tangent);
        for corner: 0..3 {
            vertex := *vertices[face * 4 + corner];
            vertex.position = (normal + tangent * corners[corner].x + up * corners[corner].y) * 0.5;
            vertex.normal = normal;
        }
        for index: u32.[0, 1, 2, 0, 2, 3] { indices[face * 6 + it_index] = cast(u32) (face * 4) + index; }
    }
    return scene_upload_mesh(vertices, indices);
}

scene_load_texture :: (path: string) -> Scene_Texture {
    stbi_set_flip_vertically_on_load(0);
    width, height, channels: s32;
    pixels := stbi_load(temp_c_string(path), *width, *height, *channels, 4);
    assert(pixels != null && width > 0 && height > 0, "Cannot load texture: %", path);
    defer stbi_image_free(pixels);
    result, texture := gpu_create_texture(.{dimensions = .[xx width, xx height, 1],
        format = .R8G8B8A8_SRGB, usage = .SAMPLED | .TRANSFER_DST}, label = path);
    assert(result == .SUCCESS && texture != 0);
    size := width.(s64) * height * 4;
    staging, staging_gpu := gpu_malloc(size);
    assert(staging != null && staging_gpu != 0);
    defer gpu_free(staging);
    memcpy(staging, pixels, size);
    queue := gpu_get_queue(.MAIN, 0);
    gpu_queue_wait_idle(queue);
    result=, cmd := gpu_start_command_recording(queue);
    assert(result == .SUCCESS);
    assert(gpu_copy_to_texture(cmd, texture, staging_gpu) == .SUCCESS);
    gpu_barrier(cmd, .TRANSFER, .PIXEL_SHADER);
    gpu_submit(cmd);
    gpu_queue_wait_idle(queue);
    return .{texture = texture, view = gpu_texture_view(texture)};
}

#import "Basic";
#import "Math";
#import "stb_image";
#import "String";
