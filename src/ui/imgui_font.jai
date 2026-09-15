IMGUI_FONT_PATH :: "assets/fonts/NotoSansCJKsc-Regular.otf";
MENU_FONT_PATH :: "assets/fonts/Karmina-Bold.otf";
ICON_FONT_PATH :: "assets/fonts/Meslo-LG-Mono-Nerd-Regular.ttf";
IMGUI_FONT_SIZE :: 18.0;
// Simp/FreeType sizes Karmina in em units; stb uses ascent minus descent (1120 / 1000).
KARMINA_HEIGHT_PER_EM :: 1.12;
imgui_menu_em: float;
imgui_menu_size: float;
imgui_title_size: float;
imgui_title_font: *ImGui.ImFont;
imgui_menu_font: *ImGui.ImFont;
imgui_menu_ui_font: *ImGui.ImFont;
// Extra CJK glyphs for font coverage checks; the ImGui interface uses English.
IMGUI_EXTRA_GLYPHS :: "渲染设置背景颜色重置演示按栅格化字体使用逻辑坐标布局";

// Call between ImGui frames, then upload the rebuilt atlas with imgui_sgpu_upload_font_atlas.
imgui_menu_em_for_height :: (height: float) -> float { return max(12.0, floor(height / 18)); }

imgui_load_font :: (dpi_scale: float, logical_height: float = 900) {
    assert(dpi_scale > 0);
    io := ImGui.GetIO();
    io.Fonts.Clear(io.Fonts);
    io.Fonts.TexDesiredWidth = 2048;

    config: ImGui.ImFontConfig;
    config.Constructor(*config);
    // Rasterization settings from the supplied ImGui theme.
    config.OversampleH = 3;
    config.OversampleV = 1;
    config.PixelSnapH = true;
    config.RasterizerMultiply = 1.10;
    if font_glyph_ranges.Data == null {
        used_chars: [2048] u32; // One bit per BMP code point, matching this ImGui build's ImWchar.
        builder := ImGui.ImFontGlyphRangesBuilder.{
            UsedChars = .{Size = xx used_chars.count, Capacity = xx used_chars.count, Data = used_chars.data},
        };
        builder.AddRanges(*builder, io.Fonts.GetGlyphRangesChineseSimplifiedCommon(io.Fonts));
        builder.AddText(*builder, IMGUI_EXTRA_GLYPHS);
        builder.BuildRanges(*builder, *font_glyph_ranges);
    }
    font := io.Fonts.AddFontFromFileTTF(io.Fonts, temp_c_string(IMGUI_FONT_PATH), IMGUI_FONT_SIZE * dpi_scale, *config, font_glyph_ranges.Data);
    assert(font != null, "Failed to load %.", IMGUI_FONT_PATH);
    io.FontDefault = font;
    // Merge only the two requested Codicons. All ordinary text stays in Noto.
    config.MergeMode = true;
    config.GlyphMinAdvanceX = IMGUI_FONT_SIZE * dpi_scale;
    config.GlyphMaxAdvanceX = IMGUI_FONT_SIZE * dpi_scale;
    icons := io.Fonts.AddFontFromFileTTF(io.Fonts, temp_c_string(ICON_FONT_PATH),
                                      IMGUI_FONT_SIZE * dpi_scale, *config, icon_glyph_ranges.data);
    assert(icons != null, "Failed to load %.", ICON_FONT_PATH);
    config.MergeMode = false;
    config.GlyphMinAdvanceX = 0;
    config.GlyphMaxAdvanceX = FLOAT32_MAX;
    // Menu text uses Karmina; editor and console text retain Noto and CJK coverage.
    imgui_menu_em = imgui_menu_em_for_height(logical_height);
    imgui_menu_size = imgui_menu_em * KARMINA_HEIGHT_PER_EM;
    imgui_title_size = imgui_menu_size * 1.6;
    config.PixelSnapH = false;
    config.RasterizerMultiply = 1;
    config.OversampleV = 2;
    imgui_menu_font = io.Fonts.AddFontFromFileTTF(io.Fonts, temp_c_string(MENU_FONT_PATH),
        imgui_menu_size * dpi_scale, *config, io.Fonts.GetGlyphRangesDefault(io.Fonts));
    imgui_title_font = io.Fonts.AddFontFromFileTTF(io.Fonts, temp_c_string(MENU_FONT_PATH),
        imgui_title_size * dpi_scale, *config, io.Fonts.GetGlyphRangesDefault(io.Fonts));
    imgui_menu_ui_font = io.Fonts.AddFontFromFileTTF(io.Fonts, temp_c_string(MENU_FONT_PATH),
        IMGUI_FONT_SIZE * dpi_scale, *config, io.Fonts.GetGlyphRangesDefault(io.Fonts));
    assert(imgui_menu_font != null && imgui_title_font != null && imgui_menu_ui_font != null, "Failed to load %.", MENU_FONT_PATH);
    // Rasterize at physical-pixel resolution; preserve an 18-pixel logical font size.
    io.FontGlobalScale = 1.0 / dpi_scale;
}

// Call after destroying the renderer and before destroying the ImGui context.
imgui_shutdown_font :: () {
    io := ImGui.GetIO();
    io.FontDefault = null;
    imgui_title_font = null;
    imgui_menu_font = null;
    imgui_menu_ui_font = null;
    io.Fonts.Clear(io.Fonts);
    ImGui.MemFree(font_glyph_ranges.Data);
    font_glyph_ranges = .{};
}

#scope_file
font_glyph_ranges: ImGui.ImVector(ImGui.ImWchar);
icon_glyph_ranges := ImGui.ImWchar.[0xeb6e, 0xeb6e, 0xeb70, 0xeb70, 0];
#import "Basic";
#import "String";
#import "Math";
