// ----------------------------------------------------------------------------: Renderer
//
// 一个带深度测试的 PBR pass。应用把要画的东西列成 Draw 数组交给 renderer_render，
// 渲染器负责管线、深度缓冲、每帧参数上传。每帧数据放在三槽的 GPU arena 环里，
// 重用某槽前先等时间线信号量，确认 GPU 已跑完上次用它的那帧。
//
// 着色器参数是 GPU 指针（push constant），Jai 结构必须与 pbr_vs.slang / pbr_ps.slang 逐字节一致。

// 与 pbr_vs.slang 的 Vertex 一致。静态网格 weights 全零、joints 全 0xffffffff。
Vertex :: struct {
    position: Vector3;
    normal:   Vector3;
    uv:       Vector2;
    tangent:  Vector4 = .{1, 0, 0, 1};
    weights:  Vector4;
    joints:   [4] u32 = .[0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff];
}

Instance :: struct {
    model: Matrix4;
    color: Vector4;
}

Point_Light :: struct {
    position: Vector3;
    radius: float = 10;
    color := Vector3.{1, 1, 1};
    intensity: float = 10;
}

Tone_Mapping :: enum u32 { NONE; REINHARD; ACES; }
Debug_View :: enum u32 { NONE; NORMAL; BASE_COLOR; METALLIC; ROUGHNESS; OCCLUSION; EMISSIVE; UV; }

// 场景级光照参数，应用直接修改 `lighting`。
Scene_Params :: struct {
    view_projection: Matrix4;
    camera_position: Vector3;
    point_light_count: u32;
    sun_direction := Vector3.{0.4, 0.8, 0.5};   // 指向光源
    sun_intensity: float = 3;
    sun_color := Vector3.{1, 0.96, 0.9};
    ambient_intensity: float = 0.25;
    ambient_color := Vector3.{0.6, 0.7, 0.9};
    exposure: float = 1;
    point_lights: [4] Point_Light;
    tone_mapping: Tone_Mapping = .ACES;
    debug_view: Debug_View = .NONE;
    padding: [2] u32;
}

Vertex_Params :: struct {
    scene: Gpu_Ptr;
    vertices: Gpu_Ptr;
    skinning: Gpu_Ptr;
    instances: Gpu_Ptr;
    model: Matrix4;
    normal_matrix: Matrix4;
    skinned: u32;
    instanced: u32;
    padding: [2] u32;
}

Material_Flags :: enum_flags u32 {
    HAS_BASE_COLOR_MAP         :: 1 << 0;
    HAS_METALLIC_ROUGHNESS_MAP :: 1 << 1;
    HAS_NORMAL_MAP             :: 1 << 2;
    HAS_OCCLUSION_MAP          :: 1 << 3;
    HAS_EMISSIVE_MAP           :: 1 << 4;
    UNLIT                      :: 1 << 5;
    DOUBLE_SIDED               :: 1 << 6;
}

// 直接推给着色器的材质。贴图是 bindless 句柄，缺失时对应 flag 不设即可。
Material :: struct {
    base_color := Vector4.{1, 1, 1, 1};
    emissive: Vector3;
    emissive_strength: float = 1;
    metallic: float = 0;
    roughness: float = 0.5;
    normal_scale: float = 1;
    occlusion_strength: float = 1;
    base_color_map: Gpu_Texture_View;
    metallic_roughness_map: Gpu_Texture_View;
    normal_map: Gpu_Texture_View;
    occlusion_map: Gpu_Texture_View;
    emissive_map: Gpu_Texture_View;
    sampler: Gpu_Sampler;
    flags: Material_Flags;
    padding: u32;
}

Pixel_Params :: struct {
    scene: Gpu_Ptr;
    material: Material;
}

// 已上传到 GPU 的网格。
Mesh :: struct {
    memory: *void;           // 一块 host-visible 内存：先顶点，后索引
    vertices_gpu: Gpu_Ptr;
    indices_gpu: Gpu_Ptr;
    vertex_count: u32;
    index_count: u32;
    bounds_min, bounds_max: Vector3;
}

Texture :: struct {
    texture: Gpu_Texture;
    view: Gpu_Texture_View;
}

// 一次绘制：网格的一段索引，用一个材质和一个模型矩阵画。
// skinning 非空时做蒙皮；instances 非空时做实例化（忽略 model）。
Draw :: struct {
    mesh: *Mesh;
    first_index: u32;
    index_count: u32;         // 0 表示整个网格
    material: Material;
    model: Matrix4 = Matrix4_Identity;
    skinning: [] Matrix4;
    instances: [] Instance;
}

lighting: Scene_Params;
background := Vector3.{0.05, 0.06, 0.08};
default_sampler: Gpu_Sampler;

// 统计，UI 显示用。
frame_draw_count, frame_triangle_count: u32;

// 排查用开关：关掉某个特性看问题是否消失。
debug_disable_skinning := false;
debug_disable_instancing := false;
debug_disable_textures := false;   // 所有贴图槽位换成 1x1 白图

DEPTH_FORMAT :: Format.D32_SFLOAT;

renderer_init :: () {
    #assert(size_of(Vertex) == 80);
    #assert(size_of(Instance) == 80);
    #assert(size_of(Point_Light) == 32);
    #assert(size_of(Scene_Params) == 272);
    #assert(size_of(Vertex_Params) == 176);
    #assert(size_of(Material) == 80);
    #assert(size_of(Pixel_Params) == 88);

    success: bool;
    success, vertex_spv = compile_shader("assets/shaders/pbr_vs.slang");
    assert(success, "Failed to compile pbr_vs.slang");
    success, pixel_spv = compile_shader("assets/shaders/pbr_ps.slang");
    assert(success, "Failed to compile pbr_ps.slang");

    timeline = gpu_create_semaphore(0);
    for * slots it.arena = gpu_make_arena(1024 * 1024);

    default_sampler = gpu_create_sampler(.{
        address_mode_u = .REPEAT, address_mode_v = .REPEAT, address_mode_w = .REPEAT,
        mip_lod_bias = 0,     // SGPU 没启用 samplerAnisotropy，这里不用各向异性
        compare_op = .NEVER,  // SGPU 默认 ALWAYS 会把采样器建成比较采样器，那只能用于深度纹理
    }, "Default sampler");

    // 1x1 白色贴图：材质没有贴图时也能给个合法句柄（着色器靠 flags 决定是否采样）。
    white := u8.[255, 255, 255, 255];
    white_texture = create_texture_rgba8(white.data, 1, 1, srgb = false, mipmaps = false);
}

renderer_shutdown :: () {
    gpu_wait_idle();
    for slots gpu_free_arena(it.arena);
    for pipelines if it != 0 then gpu_free_pipeline(it);
    if depth != 0 then gpu_free(depth);
    free_texture(*white_texture);
    gpu_free(default_sampler);
    gpu_destroy_semaphore(timeline);
    free(vertex_spv.data);
    free(pixel_spv.data);
}

white_texture: Texture;

// 把 CPU 网格拷到 GPU 可见内存。
upload_mesh :: (vertices: [] Vertex, indices: [] u32) -> Mesh {
    vertex_bytes := vertices.count * size_of(Vertex);
    index_offset := align_forward(vertex_bytes, 16);
    index_bytes := indices.count * size_of(u32);

    mesh: Mesh;
    cpu, gpu := gpu_malloc(index_offset + index_bytes);
    assert(cpu != null && gpu != 0);
    memcpy(cpu, vertices.data, vertex_bytes);
    memcpy(cpu + index_offset, indices.data, index_bytes);
    mesh.memory = cpu;
    mesh.vertices_gpu = gpu;
    mesh.indices_gpu = gpu + cast(Gpu_Ptr) index_offset;
    mesh.vertex_count = cast(u32) vertices.count;
    mesh.index_count = cast(u32) indices.count;

    mesh.bounds_min = .{ FLOAT32_MAX,  FLOAT32_MAX,  FLOAT32_MAX};
    mesh.bounds_max = .{-FLOAT32_MAX, -FLOAT32_MAX, -FLOAT32_MAX};
    for vertices {
        mesh.bounds_min = .{min(mesh.bounds_min.x, it.position.x), min(mesh.bounds_min.y, it.position.y), min(mesh.bounds_min.z, it.position.z)};
        mesh.bounds_max = .{max(mesh.bounds_max.x, it.position.x), max(mesh.bounds_max.y, it.position.y), max(mesh.bounds_max.z, it.position.z)};
    }
    if vertices.count == 0 { mesh.bounds_min = .{}; mesh.bounds_max = .{}; }
    return mesh;
}

free_mesh :: (mesh: *Mesh) {
    if mesh.memory != null then gpu_free(mesh.memory);
    mesh.* = .{};
}

// 上传 RGBA8 像素为纹理，可选生成 mipmap。阻塞到上传完成。
// srgb 为真时按 R8G8B8A8_SRGB 创建，采样自动转线性；法线/金属粗糙度这类数据贴图必须用线性格式。
create_texture_rgba8 :: (pixels: *u8, width: s32, height: s32, srgb: bool, mipmaps := true, label := "") -> Texture {
    assert(pixels != null && width > 0 && height > 0);
    mip_count: u8 = 1;
    if mipmaps {
        size := max(width, height);
        while size > 1 { size /= 2; mip_count += 1; }
    }

    result, texture := gpu_create_texture(.{
        dimensions = .[xx width, xx height, 1],
        mip_count = mip_count,
        format = ifx srgb then Format.R8G8B8A8_SRGB else Format.R8G8B8A8_UNORM,
        usage = .SAMPLED | .TRANSFER_DST | .TRANSFER_SRC,
    }, label = label);
    assert(result == .SUCCESS && texture != 0);

    size := width.(s64) * height * 4;
    staging, staging_gpu := gpu_malloc(size);
    memcpy(staging, pixels, size);

    queue := gpu_get_queue(.MAIN, 0);
    gpu_queue_wait_idle(queue);   // 创建纹理时排队了一次布局转换，先让它完成
    result=, cmd := gpu_start_command_recording(queue);
    assert(result == .SUCCESS);
    gpu_enqueue_destroy(cmd, staging_gpu);
    gpu_copy_to_texture(cmd, texture, staging_gpu);
    // 逐级 blit 生成 mipmap：每级都是上一级的一半。
    for mip: 1..mip_count - 1 {
        gpu_barrier(cmd, .TRANSFER, .TRANSFER);
        gpu_blit_image(cmd, texture, texture, src_mip = xx (mip - 1), dst_mip = xx mip);
    }
    gpu_barrier(cmd, .TRANSFER, .PIXEL_SHADER);
    gpu_submit(cmd);
    gpu_queue_wait_idle(queue);

    return .{texture, gpu_texture_view(texture)};
}

// 从图片文件加载。flip 为真时上下翻转（OBJ 的 uv 原点在左下角）。
load_texture_file :: (path: string, srgb: bool, flip := false) -> Texture, bool {
    stbi_set_flip_vertically_on_load(xx flip);
    width, height, channels: s32;
    pixels := stbi_load(temp_c_string(path), *width, *height, *channels, 4);
    if pixels == null { log_error("Failed to load texture '%'.", path); return .{}, false; }
    defer stbi_image_free(pixels);
    return create_texture_rgba8(pixels, width, height, srgb, label = path), true;
}

free_texture :: (texture: *Texture) {
    if texture.texture != 0 then gpu_free(texture.texture);
    texture.* = .{};
}

// 往 cmd 里录一整个 pass。返回的时间线对必须由包含 cmd 的提交去 signal，帧槽才能安全重用。
renderer_render :: (cmd: Gpu_Command_Buffer, target: Gpu_Texture_View, draws: [] Draw) -> Gpu_Timeline_Pair {
    prepare_target(target);

    slot := *slots[cursor];
    cursor = (cursor + 1) % slots.count;
    if slot.completion != 0 then gpu_wait_semaphore(.{timeline, slot.completion});
    submitted += 1;
    slot.completion = submitted;
    gpu_reset_arena(*slot.arena);

    aspect := width.(float) / max(height, 1).(float);
    lighting.view_projection = view_projection(aspect);
    lighting.camera_position = camera.position;
    scene_params, scene_gpu := gpu_arena_alloc(*slot.arena, Scene_Params);
    scene_params.* = lighting;

    // 深度纹理被排队中的各帧共用：让上一帧的深度/颜色写入先完成，再开始这一帧的 pass。
    gpu_barrier(cmd, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS | .COLOR_ATTACHMENT_OUTPUT,
                     .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS | .COLOR_ATTACHMENT_OUTPUT);
    result := gpu_begin_render_pass(cmd, .{
        color_targets = .[.{
            view = target, load_op = .CLEAR, store_op = .STORE,
            clear_color._float = .[background.x, background.y, background.z, 1],
        }],
        depth_target = .{view = depth_view, load_op = .CLEAR, store_op = .STORE, clear_value.depth = 1},
    });
    assert(result == .SUCCESS);

    gpu_set_viewport(cmd, .{width = xx width, height = xx height, max_depth = 1});
    gpu_set_scissor(cmd, .{0, 0, width, height});

    frame_draw_count = 0;
    frame_triangle_count = 0;
    bound_pipeline: Gpu_Pipeline = 0;
    last_skinning: [] Matrix4;
    last_skinning_gpu: Gpu_Ptr;

    for draw: draws {
        if draw.mesh == null continue;
        // 双面材质关闭剔除；其余剔除背面（OBJ/glTF 正面都是逆时针）。
        cull := ifx draw.material.flags & .DOUBLE_SIDED then Cull.NONE else Cull.CW;
        pipeline := pipelines[cull];
        if pipeline != bound_pipeline {
            gpu_set_pipeline(cmd, pipeline);
            // 管线没有模板附件，显式关掉模板测试（SGPU 默认 ALWAYS 会打开它）。
            gpu_set_depth_stencil_state(cmd, .{depth_test = .LESS, depth_mode = .READ | .WRITE,
                                              stencil_front.test = .NEVER, stencil_back.test = .NEVER});
            bound_pipeline = pipeline;
        }

        // arena 内存不清零：先整体置零，否则 skinned / instanced 和指针字段会残留上一帧的脏数据，
        // 着色器就会顺着垃圾指针读显存，表现为画面闪烁直到设备丢失。
        vertex_params, vertex_params_gpu := gpu_arena_alloc(*slot.arena, Vertex_Params);
        vertex_params.* = .{};
        vertex_params.scene = scene_gpu;
        vertex_params.vertices = draw.mesh.vertices_gpu;
        vertex_params.model = draw.model;
        ok, inverse_model := inverse(draw.model);
        vertex_params.normal_matrix = ifx ok then transpose(inverse_model) else Matrix4_Identity;

        instance_count: u32 = 1;
        if draw.skinning.count && !debug_disable_skinning {
            // 同一角色的多个部件共用一份蒙皮矩阵，只上传一次。
            if draw.skinning.data != last_skinning.data || draw.skinning.count != last_skinning.count {
                palette, palette_gpu := gpu_arena_array_alloc(*slot.arena, Matrix4, draw.skinning.count);
                memcpy(palette.data, draw.skinning.data, draw.skinning.count * size_of(Matrix4));
                last_skinning = draw.skinning;
                last_skinning_gpu = palette_gpu;
            }
            vertex_params.skinning = last_skinning_gpu;
            vertex_params.skinned = 1;
        }
        if draw.instances.count {
            if debug_disable_instancing {
                // 只画第一个实例，走普通路径。
                vertex_params.model = draw.instances[0].model;
                ok, inverse_model = inverse(vertex_params.model);
                vertex_params.normal_matrix = ifx ok then transpose(inverse_model) else Matrix4_Identity;
            } else {
                instances, instances_gpu := gpu_arena_array_alloc(*slot.arena, Instance, draw.instances.count);
                memcpy(instances.data, draw.instances.data, draw.instances.count * size_of(Instance));
                vertex_params.instances = instances_gpu;
                vertex_params.instanced = 1;
                instance_count = cast(u32) draw.instances.count;
            }
        }

        pixel_params, pixel_params_gpu := gpu_arena_alloc(*slot.arena, Pixel_Params);
        pixel_params.* = .{};
        pixel_params.scene = scene_gpu;
        pixel_params.material = draw.material;
        if debug_disable_textures {
            pixel_params.material.flags &= ~(Material_Flags.HAS_BASE_COLOR_MAP | .HAS_METALLIC_ROUGHNESS_MAP
                                             | .HAS_NORMAL_MAP | .HAS_OCCLUSION_MAP | .HAS_EMISSIVE_MAP);
            pixel_params.material.base_color_map = 0;
            pixel_params.material.metallic_roughness_map = 0;
            pixel_params.material.normal_map = 0;
            pixel_params.material.occlusion_map = 0;
            pixel_params.material.emissive_map = 0;
        }
        if pixel_params.material.sampler == 0 then pixel_params.material.sampler = default_sampler;
        // 没有贴图的槽位指向白图，保证句柄合法。
        if pixel_params.material.base_color_map == 0 then pixel_params.material.base_color_map = white_texture.view;
        if pixel_params.material.metallic_roughness_map == 0 then pixel_params.material.metallic_roughness_map = white_texture.view;
        if pixel_params.material.normal_map == 0 then pixel_params.material.normal_map = white_texture.view;
        if pixel_params.material.occlusion_map == 0 then pixel_params.material.occlusion_map = white_texture.view;
        if pixel_params.material.emissive_map == 0 then pixel_params.material.emissive_map = white_texture.view;

        index_count := ifx draw.index_count then draw.index_count else draw.mesh.index_count;
        indices := draw.mesh.indices_gpu + cast(Gpu_Ptr) (draw.first_index * size_of(u32));
        gpu_draw_indexed_instanced(cmd, vertex_params_gpu, pixel_params_gpu, indices, index_count, instance_count);
        frame_draw_count += 1;
        frame_triangle_count += index_count / 3 * instance_count;
    }

    gpu_end_render_pass(cmd);
    // 后面的 ImGui pass 以 LOAD 方式读同一张颜色附件，先等这里的颜色写入落地。
    gpu_barrier(cmd, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_OUTPUT);
    return .{timeline, slot.completion};
}

#scope_file

vertex_spv, pixel_spv: [] u8;
pipelines: [3] Gpu_Pipeline;   // 按 Cull 索引
pipeline_format: Format = .UNDEFINED;

depth: Gpu_Texture;
depth_view: Gpu_Texture_View;
width, height: u32;

timeline: Gpu_Semaphore;
submitted: u64;
cursor: int;
slots: [3] struct {
    arena: Gpu_Arena;
    completion: u64;
};

// 交换链格式/尺寸变化时，重建管线和深度缓冲。
prepare_target :: (target: Gpu_Texture_View) {
    found, desc := gpu_texture_desc(target);
    assert(found);

    if pipelines[0] == 0 || pipeline_format != desc.format {
        gpu_wait_idle();
        for pipelines if it != 0 then gpu_free_pipeline(it);
        blend: Gpu_Blend_Desc;
        for cull: Cull.[.NONE, .CCW, .CW] {
            pipelines[cull] = gpu_create_graphics_pipeline(vertex_spv, pixel_spv, .{
                cull = cull,
                depth_format = DEPTH_FORMAT,
                color_targets = .[.{format = desc.format}],
                blend_state = *blend,
            }, "PBR");
            assert(pipelines[cull] != 0);
        }
        pipeline_format = desc.format;
    }

    if width != desc.dimensions[0] || height != desc.dimensions[1] {
        gpu_wait_idle();
        if depth != 0 then gpu_free(depth);
        result: Gpu_Result;
        result, depth = gpu_create_texture(.{
            dimensions = .[desc.dimensions[0], desc.dimensions[1], 1],
            format = DEPTH_FORMAT,
            usage = .DEPTH_STENCIL_ATTACHMENT,
        }, label = "Scene depth");
        assert(result == .SUCCESS && depth != 0);
        gpu_queue_wait_idle(gpu_get_queue(.MAIN, 0));   // 等创建时排队的布局转换完成
        depth_view = gpu_texture_view(depth);
        width = desc.dimensions[0];
        height = desc.dimensions[1];
    }
}
