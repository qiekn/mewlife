main :: () {
    // ----------------------------------------------------------------------------: Initialization
    result := gpu_init();
    assert(result == .SUCCESS);
    defer gpu_shutdown();

    imgui_input_prepare_window();
    window := create_native_window(1600, 900, "ck: mewlife");

    window_type: Native_Window_Type;
    #if      OS == .WINDOWS then window_type = .WIN32;
    else #if OS == .LINUX   then window_type = .X11;
    else #if OS == .MACOS   then window_type = .COCOA;
    else assert(false, "Unsupported OS");

    // Prefer the newest completed frame. FIFO fallback uses two images to limit presentation queuing.
    gpu_init_swapchain(window, window_type, preferred_present_modes = .[.MAILBOX, .FIFO], min_image_count = 2);
    defer gpu_destroy_swapchain();

    main_queue := gpu_get_queue(.MAIN, 0);

    imgui_context := ImGui.CreateContext();
    assert(imgui_context != null);
    defer ImGui.DestroyContext(imgui_context);
    io := ImGui.GetIO();
    io.ConfigFlags_ |= .NavEnableKeyboard;
    io.IniFilename = null;
    imgui_theme_apply_style();

    dpi_scale := imgui_input_dpi_scale(window);
    imgui_load_font(dpi_scale);
    defer imgui_shutdown_font();

    input: Imgui_Input;
    imgui_input_init(*input, window);
    defer imgui_input_shutdown(*input);
    renderer: Imgui_Sgpu;
    imgui_sgpu_init(*renderer);
    defer imgui_sgpu_shutdown(*renderer);

    // Naysayer background from .refs/theme.jai.
    DEFAULT_BACKGROUND :: Vector4.{6.0 / 255, 38.0 / 255, 38.0 / 255, 1};
    background_color := DEFAULT_BACKGROUND;
    show_demo := false;
    needs_resize := false;

    // ----------------------------------------------------------------------------: Rendering loop

    quit := false;
    while !quit {
        update_window_events();
        for events_this_frame {
            if it.type == .QUIT then quit = true;
        }
        if quit then break;

        if get_window_resizes().count > 0 then needs_resize = true;
        width, height := imgui_input_window_size(window);
        new_dpi_scale := imgui_input_dpi_scale(window);
        if new_dpi_scale != dpi_scale {
            dpi_scale = new_dpi_scale;
            imgui_load_font(dpi_scale);
            imgui_sgpu_upload_font_atlas(*renderer);
        }
        if width == 0 || height == 0 {
            imgui_input_update(*input, width, height, dpi_scale);
            // A zero-sized Vulkan swapchain is invalid. Resize once the window returns.
            needs_resize = true;
            sleep_milliseconds(16);
            continue;
        }
        if needs_resize {
            gpu_swapchain_resize();
            needs_resize = false;
        }

        result=, swapchain_image := gpu_swapchain_acquire();
        assert(result == .SUCCESS);
        // Acquire may wait for the GPU or display. Sample the mouse after that wait, just before NewFrame.
        imgui_input_update(*input, width, height, dpi_scale);
        if swapchain_image == 0 {
            needs_resize = true;
            sleep_milliseconds(16);
            continue;
        }

        ImGui.NewFrame();
        ImGui.SetNextWindowPos(.{24, 24}, .FirstUseEver);
        ImGui.SetNextWindowSize(.{360, 0}, .FirstUseEver);
        if ImGui.Begin("Rendering Settings", flags = .AlwaysAutoResize) {
            ImGui.SetNextItemWidth(220);
            ImGui.ColorEdit3("Background Color", *background_color.xyz.component, .Float);
            if ImGui.Button("Reset") then background_color = DEFAULT_BACKGROUND;
            ImGui.Separator();
            ImGui.Text("FPS: %", cast(s32) io.Framerate);
            ImGui.Checkbox("ImGui Demo", *show_demo);
        }
        ImGui.End();
        if show_demo then ImGui.ShowDemoWindow(*show_demo);
        imgui_input_update_cursor(*input);
        ImGui.Render();

        result=, cmd := gpu_start_command_recording(main_queue);
        assert(result == .SUCCESS);
        render_desc := Gpu_Render_Pass_Desc.{
            color_targets = .[.{
                view = swapchain_image,
                load_op = .CLEAR,
                store_op = .STORE,
                clear_color._float = background_color.component,
            }],
        };
        result = gpu_begin_render_pass(cmd, render_desc);
        assert(result == .SUCCESS);
        ui_completion := imgui_sgpu_render(*renderer, cmd, swapchain_image, ImGui.GetDrawData());
        gpu_end_render_pass(cmd);
        gpu_submit_and_present(cmd, signals = .[ui_completion]);
    }

    gpu_wait_idle();
}

#import "sgpu"(VALIDATION = true);
#import "Basic";
#import "Input";
#import "Math";
ImGui :: #import "ImGui";

#load "utils/window.jai";
#load "ui/imgui_input.jai";
#load "ui/imgui_font.jai";
#load "ui/imgui_theme.jai";
#load "ui/imgui_sgpu.jai";
