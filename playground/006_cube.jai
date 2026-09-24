// ----------------------------------------------------------------------------: 006 立方体
//
// 在 005 的基础上迈出三步：
//   1. 顶点从 2D 变成 3D，并用一个 MVP 矩阵把它们投影到屏幕上
//   2. 每帧更新矩阵（旋转），学会"哪块 GPU 内存可以安全地在帧之间重写"
//   3. 加深度缓冲和背面剔除，让前面的面挡住后面的面
//
// 编译运行（在 playground 目录下）：
//     jai 006_cube.jai && ./006_cube.exe

#import,dir "../modules/sgpu"(VALIDATION = true);
#import "Basic";
#import "Input";
#import "Math";

#load "utils/windows.jai";

// 必须与 ../assets/shaders/simple_vs.slang 的 Vertex_Params 逐字节一致：64 + 8 + 8 = 80。
Vertex_Params :: struct {
    mvp: Matrix4;
    positions: Gpu_Ptr;
    colors: Gpu_Ptr;
}
#assert(size_of(Vertex_Params) == 80);

DEPTH_FORMAT :: Format.D32_SFLOAT;

main :: () {
    gpu_init();
    defer gpu_shutdown();

    window := create_native_window(1200, 800, "ck: CUBE");
    window_type: Native_Window_Type;
    #if      OS == .WINDOWS then window_type = .WIN32;
    else #if OS == .LINUX   then window_type = .X11;
    else #if OS == .MACOS   then window_type = .COCOA;
    else assert(false, "Unsupported OS");

    gpu_init_swapchain(window, window_type);
    defer gpu_destroy_swapchain();

    // 着色器放在 assets/shaders，和正式项目共用 common.slang（Slang 的 import 搜索路径是着色器所在目录）。
    success_vs, vertex_spv := compile_shader("../assets/shaders/simple_vs.slang"); assert(success_vs);
    success_ps, pixel_spv  := compile_shader("../assets/shaders/simple_ps.slang");  assert(success_ps);
    defer free(vertex_spv.data);
    defer free(pixel_spv.data);

    // ------------------------------------------------------------------------: 管线
    //
    // 和 004/005 相比多了 depth_format：管线要知道自己会往什么格式的深度附件写。
    // cull = .CW：SGPU 规定逆时针为正面，顺时针的三角形（背面）被丢掉。
    // 立方体是凸的，光靠剔除其实就能画对；深度缓冲是为了以后画多个物体。
    blend_state: Gpu_Blend_Desc;
    pipeline := gpu_create_graphics_pipeline(vertex_spv, pixel_spv, .{
        cull = .CW,
        depth_format = DEPTH_FORMAT,
        color_targets = .[.{format = .B8G8R8A8_UNORM}],
        blend_state = *blend_state,
    });
    assert(pipeline != 0);
    defer gpu_free_pipeline(pipeline);

    // 深度测试：LESS 表示新像素更近才通过；READ | WRITE 表示既比较也更新。
    // 模板测试显式关掉（SGPU 里 Stencil_Desc.test 默认是 ALWAYS，会把它打开）。
    depth_desc := Gpu_Depth_Stencil_Desc.{
        depth_test = .LESS,
        depth_mode = .READ | .WRITE,
        stencil_front.test = .NEVER,
        stencil_back.test = .NEVER,
    };

    // ------------------------------------------------------------------------: 几何数据
    //
    // 每个面 4 个顶点、6 个面共 24 个顶点。为什么不共享 8 个角？因为颜色按面给：
    // 同一个角在三个面上颜色不同，顶点属性不同就必须是不同的顶点。
    // 索引缓冲让每个面的两个三角形复用 4 个顶点（6 个索引指向 4 个顶点）。
    gpu_arena := gpu_make_arena(16 * 1024);
    defer gpu_free_arena(gpu_arena);

    positions, positions_gpu := gpu_arena_alloc(*gpu_arena, [24] Vector3);
    colors,    colors_gpu    := gpu_arena_alloc(*gpu_arena, [24] Vector3);
    indices,   indices_gpu   := gpu_arena_alloc(*gpu_arena, [36] u32);
    build_cube(positions, colors, indices);

    // 顶点着色器参数。每帧只改 mvp，两个指针不变。
    // 为什么每帧直接改写它是安全的？因为 gpu_swapchain_acquire 内部会等上一帧的 GPU 工作全部完成
    // （它等待 SGPU 的帧时间线信号量），所以回到 CPU 这里时，GPU 已经不再读这块内存了。
    // 代价是 CPU 和 GPU 不能并行跑两帧；正式渲染器用三个轮转的 arena 槽位来换取并行。
    vertex_params, vertex_params_gpu := gpu_arena_alloc(*gpu_arena, Vertex_Params);
    vertex_params.* = .{Matrix4_Identity, positions_gpu, colors_gpu};

    // 像素着色器不用参数，但 push constant 的像素槽位仍要放一个合法地址，随便指向一小块内存。
    pixel_dummy, pixel_gpu := gpu_arena_alloc(*gpu_arena, [4] float);
    pixel_dummy.* = .[1, 1, 1, 1];

    // ------------------------------------------------------------------------: 深度缓冲
    //
    // 深度缓冲的尺寸必须和交换链一致，窗口变化时重建。
    depth: Gpu_Texture;
    depth_view: Gpu_Texture_View;
    depth_width, depth_height: u32;
    defer if depth != 0 then gpu_free(depth);

    main_queue := gpu_get_queue(.MAIN, 0);
    start_time := seconds_since_init();

    quit := false;
    while !quit {
        update_window_events();
        for events_this_frame {
            if it.type == .QUIT then quit = true;
            if it.type == .KEYBOARD && it.key_pressed && it.key_code == .ESCAPE then quit = true;
        }
        if get_window_resizes().count > 0 then gpu_swapchain_resize();

        gpu_collect_garbage();

        // 等上一帧完成并拿到这一帧要画的交换链图像。
        _, swapchain_image := gpu_swapchain_acquire();
        if !swapchain_image continue;

        // 交换链尺寸变了就重建深度纹理。
        width, height := gpu_get_surface_extent();
        if width != depth_width || height != depth_height {
            gpu_wait_idle();   // 旧的深度纹理可能还在被上一帧写
            if depth != 0 then gpu_free(depth);
            result: Gpu_Result;
            result, depth = gpu_create_texture(.{
                dimensions = .[width, height, 1],
                format = DEPTH_FORMAT,
                usage = .DEPTH_STENCIL_ATTACHMENT,
            }, label = "Depth");
            assert(result == .SUCCESS && depth != 0);
            // 创建纹理会在队列上排一个布局转换命令，等它跑完再让第一个 pass 写深度。
            gpu_queue_wait_idle(main_queue);
            depth_view = gpu_texture_view(depth);
            depth_width = width;
            depth_height = height;
        }

        // --------------------------------------------------------------------: 每帧矩阵
        //
        // 三个矩阵各管一件事，乘在一起交给着色器：
        //   model      局部 -> 世界：让立方体绕 Y 轴和 X 轴慢慢转
        //   view       世界 -> 相机：相机放在 (0, 1.5, 4) 看向原点
        //   projection 相机 -> 裁剪：透视投影，Vulkan 的深度范围是 [0, 1]
        // 列向量约定下，先作用的矩阵写在右边：clip = P * V * M * local。
        t := cast(float) (seconds_since_init() - start_time);
        model := rotation_y(t * 0.8) * rotation_x(t * 0.5);
        view := look_at(.{0, 1.5, 4}, .{0, 0, 0});
        aspect := width.(float) / max(height, 1).(float);
        projection := perspective(60 * PI / 180, aspect, 0.1, 100);
        vertex_params.mvp = projection * view * model;

        // --------------------------------------------------------------------: 录制并提交
        _, cmd := gpu_start_command_recording(main_queue);
        gpu_begin_render_pass(cmd, .{
            color_targets = .[.{
                view = swapchain_image, load_op = .CLEAR, store_op = .STORE,
                clear_color._float = .[0.08, 0.09, 0.11, 1],
            }],
            // 深度清成 1（最远）；任何更近的像素都能通过 LESS 测试。
            depth_target = .{view = depth_view, load_op = .CLEAR, store_op = .STORE, clear_value.depth = 1},
        });
        gpu_set_pipeline(cmd, pipeline);
        gpu_set_depth_stencil_state(cmd, depth_desc);
        gpu_draw_indexed_instanced(cmd, vertex_params_gpu, pixel_gpu, indices_gpu, 36, 1);
        gpu_end_render_pass(cmd);
        gpu_submit_and_present(cmd);
    }
    gpu_wait_idle();
}

// ----------------------------------------------------------------------------: 立方体数据
//
// 用"法线 + 切线"描述每个面：面心在 normal * 0.5，四个角沿 tangent 和 up 各偏移 ±0.5。
// 角的顺序 (-1,-1) -> (1,-1) -> (1,1) -> (-1,1) 从面的外侧看是逆时针，正好是 SGPU 的正面。
build_cube :: (positions: *[24] Vector3, colors: *[24] Vector3, indices: *[36] u32) {
    normals  := Vector3.[.{ 1, 0, 0}, .{-1, 0, 0}, .{0,  1, 0}, .{0, -1, 0}, .{0, 0,  1}, .{0, 0, -1}];
    tangents := Vector3.[.{ 0, 0,-1}, .{ 0, 0, 1}, .{1,  0, 0}, .{1,  0, 0}, .{1, 0,  0}, .{-1, 0, 0}];
    face_colors := Vector3.[
        .{0.9, 0.2, 0.2},   // +X 红
        .{0.2, 0.9, 0.2},   // -X 绿
        .{0.2, 0.3, 0.9},   // +Y 蓝
        .{0.9, 0.9, 0.2},   // -Y 黄
        .{0.9, 0.3, 0.9},   // +Z 紫
        .{0.2, 0.9, 0.9},   // -Z 青
    ];
    corners := Vector2.[.{-1, -1}, .{1, -1}, .{1, 1}, .{-1, 1}];

    for face: 0..5 {
        normal := normals[face];
        tangent := tangents[face];
        up := cross(normal, tangent);
        for corner: 0..3 {
            v := face * 4 + corner;
            positions.*[v] = (normal + tangent * corners[corner].x + up * corners[corner].y) * 0.5;
            colors.*[v] = face_colors[face];
        }
        // 两个三角形：0-1-2 和 0-2-3，都保持逆时针。
        for index, i: u32.[0, 1, 2, 0, 2, 3] {
            indices.*[face * 6 + i] = cast(u32) (face * 4) + index;
        }
    }
}

// ----------------------------------------------------------------------------: 矩阵
//
// 这些在 Math 模块里也有，但自己写一遍才知道每个数放在哪。Jai 的 Matrix4 按行存放，_14 是第 1 行第 4 列。

rotation_y :: (angle: float) -> Matrix4 {
    c := cos(angle);
    s := sin(angle);
    using m := Matrix4_Identity;
    _11 = c;  _13 = s;
    _31 = -s; _33 = c;
    return m;
}

rotation_x :: (angle: float) -> Matrix4 {
    c := cos(angle);
    s := sin(angle);
    using m := Matrix4_Identity;
    _22 = c; _23 = -s;
    _32 = s; _33 = c;
    return m;
}

// 世界 -> 相机。相机自己的变换是"旋转 R，再平移到 eye"；它的逆是"减去 eye，再乘 R 的转置"。
// 旋转矩阵的逆就是转置，所以 view 的三行就是相机的三个基向量。相机看向 -Z，所以第三行是 -forward。
look_at :: (eye: Vector3, target: Vector3) -> Matrix4 {
    forward := unit_vector(target - eye);
    right := unit_vector(cross(forward, .{0, 1, 0}));
    up := cross(right, forward);
    using m := Matrix4_Identity;
    _11 =  right.x;   _12 =  right.y;   _13 =  right.z;   _14 = -dot(right, eye);
    _21 =  up.x;      _22 =  up.y;      _23 =  up.z;      _24 = -dot(up, eye);
    _31 = -forward.x; _32 = -forward.y; _33 = -forward.z; _34 =  dot(forward, eye);
    return m;
}

// 透视投影，深度映射到 Vulkan 的 [0, 1]。
// _43 = -1 让 clip.w = -view.z：相机前方的点 view.z < 0，于是 w > 0，透视除法后越远越小。
// SGPU 编译 Slang 时开了 VulkanInvertY，所以这里按 Y 向上的习惯写即可。
perspective :: (fov_y: float, aspect: float, near: float, far: float) -> Matrix4 {
    f := 1 / tan(fov_y * 0.5);
    m: Matrix4;
    m._11 = f / aspect;
    m._22 = f;
    m._33 = far / (near - far);
    m._34 = near * far / (near - far);
    m._43 = -1;
    return m;
}
