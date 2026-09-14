// ----------------------------------------------------------------------------: ImGui theme

// ImGui style from .refs/theme.jai. Sizes stay logical; framebuffer scaling handles DPI.
imgui_theme_apply_style :: () {
    ImGui.StyleColorsDark();

    style := ImGui.GetStyle();
    style.WindowRounding = 4.0;
    style.FrameRounding = 8.0;
    style.GrabRounding = 8.0;
    style.TabRounding = 8.0;
    style.ScrollbarRounding = 8.0;
    style.WindowBorderSize = 1.0;
    style.FrameBorderSize = 0.0;
    style.WindowMenuButtonPosition = .None;

    style.Colors[ImGui.Col.WindowBg]           = .{0.10, 0.105,  0.11,  1.0};
    style.Colors[ImGui.Col.Header]             = .{0.20, 0.205,  0.21,  1.0};
    style.Colors[ImGui.Col.HeaderHovered]      = .{0.30, 0.305,  0.31,  1.0};
    style.Colors[ImGui.Col.HeaderActive]       = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.Button]             = .{0.20, 0.205,  0.21,  1.0};
    style.Colors[ImGui.Col.ButtonHovered]      = .{0.30, 0.305,  0.31,  1.0};
    style.Colors[ImGui.Col.ButtonActive]       = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.FrameBg]            = .{0.20, 0.205,  0.21,  1.0};
    style.Colors[ImGui.Col.FrameBgHovered]     = .{0.30, 0.305,  0.31,  1.0};
    style.Colors[ImGui.Col.FrameBgActive]      = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.Tab]                = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.TabHovered]         = .{0.38, 0.3805, 0.381, 1.0};
    style.Colors[ImGui.Col.TabActive]          = .{0.28, 0.2805, 0.281, 1.0};
    style.Colors[ImGui.Col.TabUnfocused]       = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.TabUnfocusedActive] = .{0.20, 0.205,  0.21,  1.0};
    style.Colors[ImGui.Col.TitleBg]            = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.TitleBgActive]      = .{0.15, 0.1505, 0.151, 1.0};
    style.Colors[ImGui.Col.TitleBgCollapsed]   = .{0.15, 0.1505, 0.151, 1.0};
}
