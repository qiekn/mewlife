IMGUI_FONT_PATH :: "assets/fonts/NotoSansCJKsc-Regular.otf";
IMGUI_FONT_SIZE :: 18.0;
// Extra CJK glyphs for font coverage checks; the ImGui interface uses English.
IMGUI_EXTRA_GLYPHS :: "渲染设置背景颜色重置演示按栅格化字体使用逻辑坐标布局";

// Call between ImGui frames, then upload the rebuilt atlas with imgui_sgpu_upload_font_atlas.
imgui_load_font :: (dpi_scale: float) {
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
    // Rasterize at physical-pixel resolution; preserve an 18-pixel logical font size.
    io.FontGlobalScale = 1.0 / dpi_scale;
}

// Call after destroying the renderer and before destroying the ImGui context.
imgui_shutdown_font :: () {
    io := ImGui.GetIO();
    io.FontDefault = null;
    io.Fonts.Clear(io.Fonts);
    ImGui.MemFree(font_glyph_ranges.Data);
    font_glyph_ranges = .{};
}

#scope_file
font_glyph_ranges: ImGui.ImVector(ImGui.ImWchar);
#import "Basic";
#import "String";
