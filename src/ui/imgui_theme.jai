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

    style.Colors[ImGui.Col.WindowBg]           = color_rgb(0x1a1b1c);
    style.Colors[ImGui.Col.Header]             = color_rgb(0x333436);
    style.Colors[ImGui.Col.HeaderHovered]      = color_rgb(0x4d4e4f);
    style.Colors[ImGui.Col.HeaderActive]       = color_rgb(0x262727);
    style.Colors[ImGui.Col.Button]             = color_rgb(0x333436);
    style.Colors[ImGui.Col.ButtonHovered]      = color_rgb(0x4d4e4f);
    style.Colors[ImGui.Col.ButtonActive]       = color_rgb(0x262727);
    style.Colors[ImGui.Col.FrameBg]            = color_rgb(0x333436);
    style.Colors[ImGui.Col.FrameBgHovered]     = color_rgb(0x4d4e4f);
    style.Colors[ImGui.Col.FrameBgActive]      = color_rgb(0x262727);
    style.Colors[ImGui.Col.Tab]                = color_rgb(0x262727);
    style.Colors[ImGui.Col.TabHovered]         = color_rgb(0x616161);
    style.Colors[ImGui.Col.TabActive]          = color_rgb(0x474848);
    style.Colors[ImGui.Col.TabUnfocused]       = color_rgb(0x262727);
    style.Colors[ImGui.Col.TabUnfocusedActive] = color_rgb(0x333436);
    style.Colors[ImGui.Col.TitleBg]            = color_rgb(0x262727);
    style.Colors[ImGui.Col.TitleBgActive]      = color_rgb(0x262727);
    style.Colors[ImGui.Col.TitleBgCollapsed]   = color_rgb(0x262727);
}
