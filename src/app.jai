// ----------------------------------------------------------------------------: Application host: platform, editor and game meet here

App_Mode :: enum { VIEWER; GAME; }
GROUND_WIDTH :: 40;
GROUND_HEIGHT :: 40;

App :: struct {
    mode: App_Mode = .VIEWER;
    has_session: bool;
    quit: bool;
    menu_back: bool;
    game: Game_State;
    menu: Menu_State;
    console: Console;
    editor: Editor;
    audio: Audio_Player;
    sounds: Game_Sounds;
    model, crystal: Model_Asset;
    priestess_model, crystal_model: u32;
    idle, walk, push: Animation_Clip;
    turns, push_turns: [3] Animation_Clip;
    blocked_clips: [4] Animation_Clip;
    animator: Animator;
    animation_motion_serial: u64;
    viewer_clock: World_Clock;
    held_move_key: u32;
    items: [..] Render_Item;
}

app_init :: (app: *App) {
    assert(model_load(*app.model, "assets/models/priestess/priestess.meshbin"), "Cannot load Priestess mesh.");
    assert(model_load(*app.crystal, "assets/models/crystal/crystal.meshbin"), "Cannot load crystal mesh.");
    assert(animation_load(*app.idle, "assets/models/priestess/idle.animbin", "Idle", app.model.joints.count));
    assert(animation_load(*app.walk, "assets/models/priestess/walk.animbin", "Walk", app.model.joints.count));
    assert(animation_load(*app.push, "assets/models/priestess/push.animbin", "Push", app.model.joints.count));
    for name: string.["left", "right", "back"] {
        assert(animation_load(*app.turns[it_index], tprint("assets/models/priestess/turn_%.animbin", name),
                               tprint("Turn %", name), app.model.joints.count));
        assert(animation_load(*app.push_turns[it_index], tprint("assets/models/priestess/push_turn_%.animbin", name),
                               tprint("Push turn %", name), app.model.joints.count));
    }
    for name: string.["blocked", "blocked_left", "blocked_right", "blocked_back"] {
        assert(animation_load(*app.blocked_clips[it_index], tprint("assets/models/priestess/%.animbin", name),
                              name, app.model.joints.count));
    }
    animator_init(*app.animator, *app.model);
    app_load_sounds(app);
    game_reset(*app.game);
    editor_reset_camera(*app.editor, false);
    editor_reset_gameplay_camera(*app.editor);
    console_log(*app.console, "mewlife console", .COMMENT);
    console_log(*app.console, "Type help. Use toggle full, toggle small or toggle mini to change size.");
}

app_shutdown :: (app: *App) {
    app_free_sounds(app);
    array_free(app.items);
    animator_free(*app.animator);
    animation_free(*app.idle);
    animation_free(*app.walk);
    animation_free(*app.push);
    for *app.turns { animation_free(it); }
    for *app.push_turns { animation_free(it); }
    for *app.blocked_clips { animation_free(it); }
    model_free(*app.model);
    model_free(*app.crystal);
}

app_init_scene :: (app: *App, scene: *Scene_Renderer) {
    scene_init(scene);
    app.priestess_model = scene_add_model(scene, *app.model, "assets/models/priestess");
    app.crystal_model = scene_add_model(scene, *app.crystal, "assets/models/crystal");
}

app_run :: () {
    assert(gpu_init() == .SUCCESS);
    defer gpu_shutdown();
    app: App;
    app_init(*app);
    defer app_shutdown(*app);

    imgui_input_prepare_window();
    window := create_native_window(1600, 900, "ck: ENIGMASH");
    if !audio_init(*app.audio) then console_log(*app.console, "No audio output device; continuing silently.", .ERROR);
    window_type: Native_Window_Type;
    #if      OS == .WINDOWS then window_type = .WIN32;
    else #if OS == .LINUX   then window_type = .X11;
    else #if OS == .MACOS   then window_type = .COCOA;
    else assert(false, "Unsupported OS");
    gpu_init_swapchain(window, window_type, preferred_present_modes = .[.MAILBOX, .FIFO], min_image_count = 2);
    defer gpu_destroy_swapchain();
    queue := gpu_get_queue(.MAIN, 0);

    imgui_context := ImGui.CreateContext();
    assert(imgui_context != null);
    defer ImGui.DestroyContext(imgui_context);
    io := ImGui.GetIO();
    io.ConfigFlags_ |= .NavEnableKeyboard;
    io.IniFilename = null;
    // Direct mouse sampling is preserved; the application never smooths ImGui input.
    imgui_theme_apply_style();
    dpi_scale := imgui_input_dpi_scale(window);
    initial_width, initial_height := imgui_input_window_size(window);
    imgui_load_font(dpi_scale, initial_height / dpi_scale);
    defer imgui_shutdown_font();
    ui_input: Imgui_Input;
    imgui_input_init(*ui_input, window);
    defer imgui_input_shutdown(*ui_input);
    input := Platform_Input.{window = window};
    defer platform_input_shutdown(*input);
    ui: Imgui_Sgpu;
    imgui_sgpu_init(*ui);
    defer imgui_sgpu_shutdown(*ui);
    scene: Scene_Renderer;
    app_init_scene(*app, *scene);
    defer scene_shutdown(*scene);
    needs_resize := false;

    while !app.quit {
        defer reset_temporary_storage();
        Input.update_window_events();
        for event: Input.events_this_frame if event.type == .QUIT then app.quit = true;
        if app.quit then break;
        platform_read_input(*input);
        if Input.get_window_resizes().count > 0 then needs_resize = true;
        width, height := imgui_input_window_size(window);
        new_scale := imgui_input_dpi_scale(window);
        if height > 0 && (new_scale != dpi_scale || imgui_menu_em_for_height(height / new_scale) != imgui_menu_em) {
            dpi_scale = new_scale;
            imgui_load_font(dpi_scale, height / dpi_scale);
            imgui_sgpu_upload_font_atlas(*ui);
        }
        if width == 0 || height == 0 {
            imgui_input_update(*ui_input, width, height, dpi_scale);
            platform_mouse_look(*input, false);
            app.audio.paused = true;
            audio_update(*app.audio, 0.016);
            needs_resize = true;
            sleep_milliseconds(16);
            continue;
        }
        if needs_resize {
            gpu_swapchain_resize();
            needs_resize = false;
        }
        result, target := gpu_swapchain_acquire();
        assert(result == .SUCCESS);
        // Acquire can wait for the display. Sample the absolute UI pointer after that wait.
        was_blocked := app.menu.visible || app.console.visible;
        skip_text := app_shortcuts(*app, *input);
        imgui_input_update(*ui_input, width, height, dpi_scale, skip_text);
        if target == 0 { needs_resize = true; continue; }

        ImGui.NewFrame();
        app_draw_ui(*app, *input, *scene);
        allow_keys := !was_blocked && !app.menu.visible && !app.console.visible && input.focused
                      && !io.WantCaptureKeyboard && !io.WantTextInput;
        app_update(*app, *input, min(io.DeltaTime, 0.1), allow_keys);
        if !input.mouse_look then imgui_input_update_cursor(*ui_input);
        ImGui.Render();

        app_build_scene(*app);
        scene_prepare_target(*scene, target);
        gpu_collect_garbage();
        result=, cmd := gpu_start_command_recording(queue);
        assert(result == .SUCCESS);
        scene_completion := scene_render(*scene, cmd, target, editor_active_camera(*app.editor, app.mode == .GAME),
                                          app.items, app.editor.background, dpi_scale);
        // ImGui uses a color-only pass. It never shares the scene's depth attachment.
        assert(gpu_begin_render_pass(cmd, .{
            color_targets = .[.{view = target, load_op = .LOAD, store_op = .STORE}],
        }) == .SUCCESS);
        ui_completion := imgui_sgpu_render(*ui, cmd, target, ImGui.GetDrawData());
        gpu_end_render_pass(cmd);
        gpu_submit_and_present(cmd, signals = .[scene_completion, ui_completion]);
    }
    gpu_wait_idle();
}

// Returns exactly the TEXT_INPUT event consumed by an opening/closing console shortcut.
app_shortcuts :: (app: *App, input: *Platform_Input) -> s64 {
    app.menu_back = false;
    if !input.focused then return -1;
    io := ImGui.GetIO();
    for event: Input.events_this_frame {
        if event.type != .TEXT_INPUT then continue;
        // Holding the toggle key should not repeatedly open and close the console.
        if event.utf32 == #char "`" && platform_down(input, xx #char "`")
            && !platform_pressed(input, xx #char "`") then return it_index;
        if console_shortcut(*app.console, event.utf32, io.WantTextInput) {
            if !app.console.visible then ImGui.SetWindowFocus(cast(*u8) null);
            platform_mouse_look(input, false);
            return it_index;
        }
    }
    if platform_pressed(input, .ESCAPE) {
        if app.console.visible {
            console_close(*app.console);
            ImGui.SetWindowFocus(cast(*u8) null);
        } else if app.menu.visible {
            app.menu_back = true;
        } else menu_open(*app.menu);
    }
    if !app.console.visible && !app.menu.visible && !io.WantTextInput {
        if platform_pressed(input, .F1) then app.editor.visible = !app.editor.visible;
        if platform_pressed(input, .F2) {
            editor_set_free_camera(*app.editor, !app.editor.free_camera, app.mode == .GAME);
        }
        if platform_pressed(input, .F3) {
            app_menu_action(app, ifx app.mode == .GAME then .MODEL_VIEWER else .RESUME);
        }
    }
    return -1;
}

app_menu_action :: (app: *App, action: Menu_Action) {
    if action == .QUIT { app.quit = true; return; }
    if action == .RESUME && app.has_session && app.mode == .GAME {
        ImGui.SetWindowFocus(cast(*u8) null);
        return;
    }
    if action != .START_GAME && action != .MODEL_VIEWER && action != .RESUME then return;
    first_game := !app.has_session;
    app.has_session = true;
    app.mode = ifx action == .MODEL_VIEWER then .VIEWER else .GAME;
    app.editor.free_camera = app.mode == .VIEWER;
    app.editor.paused = false;
    app.editor.pose = ifx app.mode == .GAME then .GAMEPLAY else .BIND;
    editor_reset_camera(*app.editor, app.mode == .GAME);
    if action == .START_GAME || first_game then game_reset(*app.game);
    if action == .START_GAME || first_game then audio_stop(*app.audio);
    animator_bind_pose(*app.animator);
    ImGui.SetWindowFocus(cast(*u8) null);
}

app_draw_ui :: (app: *App, input: *Platform_Input, scene: *Scene_Renderer) {
    if app.menu.visible && !app.console.visible && input.focused {
        menu_input := Menu_Input.{
            up = platform_pressed(input, .ARROW_UP) || platform_pressed(input, xx #char "W"),
            down = platform_pressed(input, .ARROW_DOWN) || platform_pressed(input, xx #char "S"),
            accept = platform_pressed(input, .ENTER) || platform_pressed(input, .SPACEBAR),
            back = app.menu_back,
        };
        app_menu_action(app, menu_update(*app.menu, menu_input, app.has_session));
    }
    if app.menu.visible {
        click := menu_draw(*app.menu, *app.editor, app.has_session, !app.console.visible);
        if !app.console.visible then app_menu_action(app, menu_update(*app.menu, click, app.has_session));
    } else if app.has_session {
        ImGui.BeginDisabled(app.console.visible);
        scale := ifx app.mode == .GAME then app.game.clock.scale else app.viewer_clock.scale;
        editor_draw(*app.editor, app.mode == .GAME, scene.draw_count, scene.triangle_count,
                    app.model.joints.count, scale, app.game.move_count);
        ImGui.EndDisabled();
        app_draw_hud(app);
    }
    console_draw(*app.console);
}

app_update :: (app: *App, input: *Platform_Input, real_dt: float, allow_keys: bool) {
    editor := *app.editor;
    paused := app.menu.visible || app.console.visible || !input.focused;
    camera_input: Camera_Input;
    if editor.free_camera && allow_keys {
        camera_input.move.x = cast(float) platform_down(input, xx #char "D") - cast(float) platform_down(input, xx #char "A");
        camera_input.move.z = cast(float) platform_down(input, xx #char "W") - cast(float) platform_down(input, xx #char "S");
        camera_input.move.y = cast(float) platform_down(input, xx #char "E") - cast(float) platform_down(input, xx #char "Q");
        camera_input.fast = platform_down(input, .SHIFT);
    }
    look := editor.free_camera && !paused && platform_down(input, .MOUSE_BUTTON_RIGHT)
            && (input.mouse_look || !ImGui.GetIO().WantCaptureMouse);
    platform_mouse_look(input, look);
    if look then camera_input.look = input.mouse_delta;
    camera_update(*editor.camera, camera_input, real_dt);

    game_input: Game_Input;
    if allow_keys && !editor.free_camera && !editor.paused && app.mode == .GAME {
        latest_press: Platform_Key_Press;
        for press: input.key_presses {
            direction := app_move_direction(press.key.(u32));
            if direction.x == 0 && direction.z == 0 then continue;
            latest_press = press;
            game_input.pressed = true;
            app.held_move_key = press.key.(u32);
        }
        if app.held_move_key != 0 && !input.held[app.held_move_key] then app.held_move_key = 0;
        if app.held_move_key == 0 {
            for key: u32.[#char "W", #char "S", #char "A", #char "D"] {
                if input.held[key] { app.held_move_key = key; break; }
            }
        }
        game_input.direction = app_move_direction(app.held_move_key);
        game_input.held = app.held_move_key != 0;
        game_input.run = platform_down(input, .SHIFT);
        if game_input.pressed {
            // Only the latest current-frame press matters. No command survives into a later frame.
            game_input.direction = app_move_direction(latest_press.key.(u32));
            game_input.held = input.held[latest_press.key];
            game_input.run = latest_press.shift;
        }
        game_input.undo = platform_pressed(input, xx #char "Z");
        game_input.restart = platform_pressed(input, xx #char "R");
        if game_input.undo || game_input.restart {
            app.held_move_key = 0;
            game_input.direction = .{};
            game_input.pressed = false;
            game_input.held = false;
        }
    } else {
        app.held_move_key = 0;
    }
    slow := allow_keys && platform_down(input, .CTRL);
    fast := allow_keys && platform_down(input, .ALT);
    game_input.slow_time = slow;
    game_input.fast_time = fast;
    world_dt: float;
    if app.mode == .GAME {
        game_update(*app.game, game_input, real_dt, paused || editor.free_camera || editor.paused);
        world_dt = app.game.clock.dt;
        if !paused && !editor.free_camera && !editor.paused && (game_input.undo || game_input.restart) {
            animator_bind_pose(*app.animator);
        }
    } else {
        world_clock_update(*app.viewer_clock, real_dt, paused, slow, fast);
        world_dt = app.viewer_clock.dt;
    }
    app.animator.paused = editor.paused;
    app_update_audio(app, real_dt);
    if editor.pose == .BIND { animator_bind_pose(*app.animator); return; }
    clip := *app.idle;
    gameplay := editor.pose == .GAMEPLAY && app.mode == .GAME;
    rate := ifx gameplay then 1.0 else editor.playback_rate;
    if editor.pose == .WALK || editor.pose == .RUN then clip = *app.walk;
    if editor.pose == .PUSH then clip = *app.push;
    if editor.pose == .BLOCKED then clip = *app.blocked_clips[0];
    if editor.pose == .RUN then rate *= 2;
    if gameplay && game_busy(*app.game) {
        motion: Game_Motion = ifx app.game.blocked then .BLOCKED else ifx app.game.pushed_box >= 0 then .PUSH else .WALK;
        clip = app_motion_clip(app, motion, app.game.turn);
        animator_play(*app.animator, clip, looping = false,
                      restart = app.animation_motion_serial != app.game.motion_serial);
        app.animation_motion_serial = app.game.motion_serial;
        duration := app.game.turn_duration + app.game.step_duration;
        progress := clamp(game_motion_time(*app.game) / duration, 0.0, 1.0);
        animator_seek(*app.animator, animation_duration(clip) * progress, world_dt);
        return;
    }
    animator_play(*app.animator, clip);
    animator_update(*app.animator, world_dt, rate);
}

app_motion_clip :: (app: *App, motion: Game_Motion, turn: Game_Turn) -> *Animation_Clip {
    if motion == .BLOCKED then return *app.blocked_clips[turn.(s64)];
    if turn != .NONE {
        index := turn.(s64) - 1;
        return ifx motion == .PUSH then *app.push_turns[index] else *app.turns[index];
    }
    return ifx motion == .PUSH then *app.push else *app.walk;
}

app_build_scene :: (app: *App) {
    array_reset(*app.items);
    if app.menu.visible then return;
    position: Vector3;
    yaw: float;
    if app.mode == .GAME {
        game := *app.game;
        position = game.player_position;
        yaw = game.visual_facing;
        for index: 0..game.box_count - 1 {
            cell := game.boxes[index];
            on_goal := game_is_goal(game, cell);
            // Core color is stored in the imported material; rim/emission follow crystal_Block_A.
            color := ifx on_goal then color_rgb(0xd9ff8c) else color_rgb(0xffffff);
            if on_goal then color.y *= 3.8; // HDR material multiplier, separate from the RGB tint.
            rim := color_rgb(cast(u32) (ifx on_goal then 0x59d947 else 0x8b73f4)).xyz;
            array_add(*app.items, .{geometry = .MODEL, model_id = app.crystal_model,
                transform = make_translation_matrix4(game.box_positions[index]), color = color,
                surface = .CRYSTAL, rim_color = rim, emissive = 0.241379});
        }
    }
    // The ground spans the surrounding world independently of the current puzzle's bounds.
    // Integer tile centres keep its unit cubes aligned with the gameplay grid and goal cells.
    if app.editor.show_ground {
        for z: 0..GROUND_HEIGHT - 1 for x: 0..GROUND_WIDTH - 1 {
            world_x := x - GROUND_WIDTH / 2;
            world_z := z - GROUND_HEIGHT / 2;
            cell := Grid_Position.{xx (world_x + BOARD_WIDTH / 2), xx (world_z + BOARD_HEIGHT / 2)};
            checker := (world_x + world_z) & 1;
            color := color_rgb(cast(u32) (ifx checker == 0 then 0x525c59 else 0x737d78));
            if app.mode == .GAME && game_is_goal(*app.game, cell) then color = color_rgb(0x218a3d);
            app_add_cube(app, .{xx world_x, -0.5, xx world_z}, .{1, 1, 1}, color);
        }
    }
    if app.mode == .GAME {
        for z: 0..BOARD_HEIGHT - 1 for x: 0..BOARD_WIDTH - 1 {
            if !app.game.walls[z * BOARD_WIDTH + x] then continue;
            center := game_grid_world(.{xx x, xx z});
            checker := (x + z) & 1;
            color := color_rgb(cast(u32) (ifx checker == 0 then 0x213036 else 0x2e4045));
            app_add_cube(app, center + .{0, 0.5, 0}, .{1, 1, 1}, color);
        }
    }
    rotation: Quaternion;
    // The source character faces +X; gameplay yaw is measured from +Z.
    set_from_axis_and_angle(*rotation, 0, 1, 0, yaw - PI * 0.5);
    transform := make_translation_matrix4(position) * rotation_matrix(Matrix4, rotation);
    array_add(*app.items, .{geometry = .MODEL, model_id = app.priestess_model, transform = transform,
        skinning = app.animator.skinning,
        outline_width = ifx app.editor.character_outline then app.editor.outline_width else 0});
}

app_add_cube :: (app: *App, position: Vector3, size: Vector3, color: Vector4) {
    array_add(*app.items, .{geometry = .CUBE,
        transform = make_translation_matrix4(position) * make_scale_matrix4(size), color = color});
}

app_draw_hud :: (app: *App) {
    size := ImGui.GetIO().DisplaySize;
    ImGui.SetNextWindowPos(.{16, size.y - 16}, .Always, .{0, 1});
    ImGui.SetNextWindowBgAlpha(0.86);
    if ImGui.Begin("##SceneHints", flags = .NoDecoration | .AlwaysAutoResize | .NoSavedSettings | .NoInputs) {
        if app.mode == .VIEWER {
            ImGui.TextUnformatted("MODEL VIEWER   |   Priestess   |   Esc: menu");
            ImGui.TextUnformatted("F1: inspector   F3: game   RMB: look   WASD + Q/E: fly   Shift: faster");
        } else {
            if app.game.solved then ImGui.TextUnformatted("PUZZLE COMPLETE   |   R: play again   Z: undo   Esc: menu");
            else if app.editor.free_camera then ImGui.TextUnformatted("FREE CAMERA   |   Game paused   |   F2: return to game");
            else ImGui.TextUnformatted("WASD: move   Shift: run   Ctrl: slow time   Alt: fast time   Z: undo   R: restart");
            ImGui.Text("Moves: %   |   World: %x   |   F1: inspector   F2: camera   Esc: menu", app.game.move_count, app.game.clock.scale);
            if app.game.blocked then ImGui.TextUnformatted("Blocked - no room to move.");
        }
    }
    ImGui.End();
}

#scope_file

app_move_direction :: (key: u32) -> Grid_Position {
    if key == #char "W" then return .{0, -1};
    if key == #char "S" then return .{0, 1};
    if key == #char "A" then return .{-1, 0};
    if key == #char "D" then return .{1, 0};
    return .{};
}
