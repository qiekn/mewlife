home_camera: Camera;   // "Reset" 回到的位置。

main :: () {
    gpu_init();
    defer gpu_shutdown();

    ui_prepare_window();
    window := create_native_window(1600, 900, "mewlife");

    window_type: Native_Window_Type;
    #if      OS == .WINDOWS then window_type = .WIN32;
    else #if OS == .LINUX   then window_type = .X11;
    else #if OS == .MACOS   then window_type = .COCOA;
    else assert(false, "Unsupported OS");

    // 优先垂直同步：SGPU 默认选 IMMEDIATE，几百帧每秒时撕裂看起来像闪烁。
    gpu_init_swapchain(window, window_type, preferred_present_modes = .[.MAILBOX, .FIFO]);
    defer gpu_destroy_swapchain();

    queue := gpu_get_queue(.MAIN, 0);

    // ImGui：上下文、输入后端、SGPU 渲染后端、字体和主题都在 Ui 里。
    ui: Ui;
    ui_init(*ui, window);
    defer ui_shutdown(*ui);

    renderer_init();
    defer renderer_shutdown();

    // 两个演示场景都在启动时加载，切换只是换指针。
    sokoban_init();
    defer sokoban_shutdown();
    helmet_init();
    defer helmet_shutdown();
    switch_scene(.HELMET);

    last_time := seconds_since_init();
    needs_resize := false;

    quit := false;
    while !quit {
        defer reset_temporary_storage();

        Input.update_window_events();
        for Input.events_this_frame if it.type == .QUIT then quit = true;
        if quit break;
        if Input.get_window_resizes().count > 0 then needs_resize = true;

        // 处理 DPI 变化并推进 ImGui 时钟；最小化时也要调用。
        width, height := ui_update(*ui, window);
        if width == 0 || height == 0 {
            needs_resize = true;
            sleep_milliseconds(16);
            continue;
        }
        if needs_resize {
            gpu_swapchain_resize();
            needs_resize = false;
        }

        now := seconds_since_init();
        dt := cast(float) min(now - last_time, 0.1);   // 卡顿时钳住，免得相机瞬移。
        last_time = now;

        result, target := gpu_swapchain_acquire();
        assert(result == .SUCCESS);
        // acquire 可能会等待显示器；之后再采样一次鼠标，让 ImGui 拿到最新坐标。
        ui_update(*ui, window);
        if target == 0 { needs_resize = true; continue; }

        ImGui.NewFrame();
        draw_ui(ui.dpi_scale);
        update_frame(dt);
        ui_update_cursor(*ui);
        ImGui.Render();

        draws := world_build_draws(active_world());

        gpu_collect_garbage();
        result=, cmd := gpu_start_command_recording(queue);
        assert(result == .SUCCESS);
        scene_completion := renderer_render(cmd, target, draws);
        // ImGui 在一个只读颜色、保留场景像素的 pass 里画在上面。
        assert(gpu_begin_render_pass(cmd, .{
            color_targets = .[.{view = target, load_op = .LOAD, store_op = .STORE}],
        }) == .SUCCESS);
        ui_completion := ui_render(*ui, cmd, target);
        gpu_end_render_pass(cmd);
        gpu_submit_and_present(cmd, signals = .[scene_completion, ui_completion]);
    }
    gpu_wait_idle();   // 之后才能释放 GPU 资源。
}

active_world :: () -> *World {
    return ifx current_scene == .HELMET then *helmet.world else *sokoban.world;
}

switch_scene :: (scene: Demo_Scene) {
    current_scene = scene;
    gizmo.snap = scene == .SOKOBAN;   // 格子世界里拖动按整格吸附
    if scene == .HELMET {
        helmet_setup_lights();
        helmet_frame_camera();
    } else {
        sokoban_reset_level();
    }
}

#scope_file

// 一帧的输入分发：ImGui 优先，然后是 gizmo，然后是拾取，最后才是相机/角色。
update_frame :: (dt: float) {
    io := ImGui.GetIO();
    world := active_world();
    focused := Input.input_application_has_focus;
    keys_free := focused && !io.WantCaptureKeyboard;
    mouse_free := focused && !io.WantCaptureMouse;

    gizmo_busy := gizmo_update(world);

    // 左键点击选中。
    if mouse_free && !gizmo_busy && ImGui.IsMouseClicked(.Left) {
        ray := camera_ray(io.MousePos, io.DisplaySize);
        world.selected = cast(s32) world_pick(world, ray);
    }
    if keys_free && ImGui.IsKeyPressed(.Escape, false) then world.selected = -1;

    // 相机：头盔场景直接 WASD 飞行；推箱子场景 WASD 归角色，按住右键时才飞。
    input: Camera_Input;
    looking := mouse_free && key_down(xx Input.Key_Code.MOUSE_BUTTON_RIGHT);
    fly_keys := keys_free && (current_scene == .HELMET || looking);
    if fly_keys {
        if key_down(#char "W") then input.move.z += 1;
        if key_down(#char "S") then input.move.z -= 1;
        if key_down(#char "D") then input.move.x += 1;
        if key_down(#char "A") then input.move.x -= 1;
        if key_down(#char "E") then input.move.y += 1;
        if key_down(#char "Q") then input.move.y -= 1;
        input.fast = key_down(xx Input.Key_Code.SHIFT);
    }
    if looking then input.look = .{xx Input.mouse_delta_x, xx Input.mouse_delta_y};
    handle_camera_input(input, dt);

    if current_scene == .HELMET {
        helmet_update(dt);
    } else {
        game: Sokoban_Input;
        if keys_free && !looking {
            game.direction = held_direction();
            game.held = game.direction.x != 0 || game.direction.z != 0;
            game.pressed = key_pressed(#char "W") || key_pressed(#char "S") || key_pressed(#char "A") || key_pressed(#char "D")
                        || key_pressed(xx Input.Key_Code.ARROW_UP) || key_pressed(xx Input.Key_Code.ARROW_DOWN)
                        || key_pressed(xx Input.Key_Code.ARROW_LEFT) || key_pressed(xx Input.Key_Code.ARROW_RIGHT);
            game.run = key_down(xx Input.Key_Code.SHIFT);
            game.reset = key_pressed(#char "R");
            if key_pressed(xx Input.Key_Code.DELETE) then sokoban_delete_selected();
        }
        sokoban_update(game, dt);
    }
}

// 当前按住的方向（后按的优先级没有区分，取第一个）。W 朝 -Z，即屏幕里。
held_direction :: () -> Grid_Cell {
    if key_down(#char "W") || key_down(xx Input.Key_Code.ARROW_UP)    return .{0, 0, -1};
    if key_down(#char "S") || key_down(xx Input.Key_Code.ARROW_DOWN)  return .{0, 0, 1};
    if key_down(#char "A") || key_down(xx Input.Key_Code.ARROW_LEFT)  return .{-1, 0, 0};
    if key_down(#char "D") || key_down(xx Input.Key_Code.ARROW_RIGHT) return .{1, 0, 0};
    return .{};
}

key_down :: (key: u32) -> bool {
    return (Input.input_button_states[key] & .DOWN) != 0;
}

key_pressed :: (key: u32) -> bool {
    return (Input.input_button_states[key] & .START) != 0;
}

#scope_export   // imports 和 loads 要对所有 src 文件可见。

#import "sgpu"(VALIDATION = true);
#import "imgui_sgpu"(VALIDATION = true);   // module 参数必须与上面的 sgpu 一致
#import "Basic";
#import "Math";
#import "String";
#import "File";
#import "Hash_Table";

#import "stb_image";
#import "obj";
#import "gltf";

ImGui :: #import "ImGui";
Input :: #import "Input";

#load "engine/camera.jai";
#load "engine/entity.jai";
#load "engine/gizmo.jai";
#load "engine/model.jai";
#load "engine/animation.jai";
#load "engine/primitives.jai";
#load "render/renderer.jai";
#load "scenes/helmet.jai";
#load "scenes/sokoban.jai";
#load "utils/color.jai";
#load "utils/window.jai";
#load "draw_imgui.jai";
