#import,dir "../modules/sgpu"(VALIDATION = true);
#import "Basic";
#import "Input";

#load "utils/windows.jai";

main :: () {
    // Init
    gpu_init();
    defer gpu_shutdown();

    // Window
    window := create_native_window(1200, 800, "ck: TRIANGLE");

    window_type: Native_Window_Type;
    #if      OS == .WINDOWS then window_type = .WIN32;
    else #if OS == .LINUX   then window_type = .X11;
    else #if OS == .MACOS   then window_type = .COCOA;
    else assert(false, "Unsupported OS");

    // Swapchain
    gpu_init_swapchain(window, window_type);
    defer gpu_destroy_swapchain();

    // SPIR-V Shaders
    success_vs, vertex_spv := compile_shader("shaders/triangle_vertex.slang"); assert(success_vs);
    success_ps, pixel_spv  := compile_shader("shaders/triangle_pixel.slang");  assert(success_ps);

    depth_desc := Gpu_Depth_Stencil_Desc.{
        depth_test = .NEVER,
        depth_mode = .NONE,
    };

    // Graphics pipeline
    blend_state : Gpu_Blend_Desc;
    raster_desc := Gpu_Raster_Desc.{
        cull = .CW,
        color_targets = .[
            .{ format = .B8G8R8A8_UNORM }
        ],
        blend_state = *blend_state,
    };
    pipeline := gpu_create_graphics_pipeline(vertex_spv, pixel_spv, raster_desc);
    defer gpu_free_pipeline(pipeline);

    // Data

    Vertex2D :: struct {
        x: float;
        y: float;
    }

    gpu_arena := gpu_make_arena(1024);
    defer gpu_free_arena(gpu_arena);

    vertex_buffer, vertex_gpu := gpu_arena_alloc(*gpu_arena, [3] Vertex2D);
    vertex_buffer.* = .[
        .{  0.0,  0.5 },
        .{ -0.5, -0.5 },
        .{  0.5, -0.5 }
    ];

    vertex_colors, colors_gpu := gpu_arena_alloc(*gpu_arena, [9] float);
    vertex_colors.* = .[
        1., 0., 0.,
        0., 1., 0.,
        0., 0., 1.,
    ];

    param_block, vertex_params_gpu := gpu_arena_alloc(*gpu_arena, [2] Gpu_Ptr);
    param_block.* = .[vertex_gpu, colors_gpu];

    index_buffer, index_gpu := gpu_arena_alloc(*gpu_arena, [3] u32);
    index_buffer.* = .[ 0, 1, 2 ];

    pixel_data, pixel_gpu := gpu_arena_alloc(*gpu_arena, [3] float);
    pixel_data.* = .[1., 0., 1.];

    main_queue := gpu_get_queue(.MAIN, 0);

    // Render Loop
    quit := false;
    while !quit {
        update_window_events();

        for events_this_frame {
            if it.type == .QUIT then quit = false;
            if it.type == .KEYBOARD {
                if it.key_pressed == 0 continue;

                if it.key_code == .ESCAPE {
                    quit = true;
                }
            }
        }

        if get_window_resizes().count > 0 {
            gpu_swapchain_resize();
        }

        _, swapchain_image := gpu_swapchain_acquire();
        if !swapchain_image continue;

        _, cmd := gpu_start_command_recording(main_queue);

        gpu_begin_render_pass(cmd, .{
            color_targets = .[
                .{
                    view = swapchain_image,
                    load_op = .CLEAR,
                    store_op = .STORE,
                    clear_color._float = .[0, 0, 0, 1],
                }
            ]
        });
        gpu_set_depth_stencil_state(cmd, depth_desc);

        gpu_set_pipeline(cmd, pipeline);

        gpu_draw_indexed_instanced(cmd, vertex_params_gpu, pixel_gpu, index_gpu, 3, 1);

        gpu_end_render_pass(cmd);

        gpu_submit_and_present(cmd);
    }
    gpu_wait_idle();
}
