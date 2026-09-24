// ----------------------------------------------------------------------------: Ui
//
// 把 ImGui 上下文、平台输入后端、SGPU 渲染后端、字体和主题打包成一个对象，
// 应用只需 ui_init / ui_shutdown，以及每帧的 ui_update / ui_render。
//
// ImGui 按物理像素工作：DisplaySize 就是帧缓冲尺寸，字体按 size * dpi 加载，
// 样式尺寸只缩放一次，这样字形落在整像素上，保持清晰。

Ui :: struct {
    imgui_context: *ImGui.ImGuiContext;
    input: Input_Backend;
    renderer: Renderer;
    dpi_scale: float;
}

// 在创建原生窗口之前调用（安装 DPI 变化��窗口消息钩子）。
ui_prepare_window :: () {
    prepare_window();
}

ui_init :: (ui: *Ui, window: u64) {
    ui.imgui_context = ImGui.CreateContext();
    io := ImGui.GetIO();
    io.IniFilename = null;

    ui.dpi_scale = window_dpi_scale(window);
    apply_theme(ui.dpi_scale);
    init_font(ui.dpi_scale);
    input_init(*ui.input, window);
    renderer_init(*ui.renderer);
}

// 与 ui_init 顺序相反：先停渲染器，再释放字体，最后销毁上下文。
ui_shutdown :: (ui: *Ui) {
    renderer_shutdown(*ui.renderer);
    input_shutdown(*ui.input);
    free_font();
    ImGui.DestroyContext(ui.imgui_context);
    ui.* = .{};
}

// 每帧在 Input.update_window_events() 之后调用；窗口最小化时也要调用，让 ImGui 时钟继续走。
// 若窗口移到了不同 DPI 的显示器上，会重建样式、字体和图集。返回窗口尺寸（物理像素）。
ui_update :: (ui: *Ui, window: u64) -> width: s32, height: s32 {
    width, height := window_size(window);
    if height > 0 {
        scale := window_dpi_scale(window);
        if scale != ui.dpi_scale {
            ui.dpi_scale = scale;
            apply_theme(scale);
            init_font(scale);
            upload_font_atlas(*ui.renderer);
        }
    }
    // 缩放传 1：ImGui 坐标就是物理像素。
    input_update(*ui.input, width, height, 1);
    return width, height;
}

// 在 ImGui.NewFrame() 与 ImGui.Render() 之间调用，同步鼠标光标形状。
ui_update_cursor :: (ui: *Ui) {
    update_cursor(*ui.input);
}

// 在 ImGui.Render() 之后、渲染通道内部调用。返回的时间线必须作为 signals 传给提交。
ui_render :: (ui: *Ui, cmd: Gpu_Command_Buffer, target: Gpu_Texture_View) -> Gpu_Timeline_Pair {
    return render(*ui.renderer, cmd, target, ImGui.GetDrawData());
}
