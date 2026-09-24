// ----------------------------------------------------------------------------: ImGui font

FONT_PATH :: "assets/fonts/OpenSans-Regular.ttf";
FONT_SIZE :: 20.0;   // Logical pixels.

// Rebuilds the atlas. Call between ImGui frames, then upload it with upload_font_atlas.
init_font :: (dpi_scale: float) {
    assert(dpi_scale > 0);
    io := ImGui.GetIO();
    io.Fonts.Clear(io.Fonts);
    io.Fonts.TexDesiredWidth = 2048;

    config: ImGui.ImFontConfig;
    config.Constructor(*config);
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
        builder.BuildRanges(*builder, *font_glyph_ranges);
    }

    // ImGui lays out in physical pixels (see app.jai), so the font is simply loaded at the scaled size.
    // Laying out in logical pixels and scaling up put glyphs on fractional physical pixels and blurred them.
    font := io.Fonts.AddFontFromFileTTF(io.Fonts, temp_c_string(FONT_PATH),
                                        FONT_SIZE * dpi_scale, *config, font_glyph_ranges.Data);
    assert(font != null, "Failed to load %.", FONT_PATH);
    io.FontDefault = font;
    io.FontGlobalScale = 1;
}

// Call after shutting down the ImGui renderer and before destroying the ImGui context.
free_font :: () {
    io := ImGui.GetIO();
    io.FontDefault = null;
    io.Fonts.Clear(io.Fonts);
    ImGui.MemFree(font_glyph_ranges.Data);
    font_glyph_ranges = .{};
}

#scope_file
font_glyph_ranges: ImGui.ImVector(ImGui.ImWchar);
#import "Basic";
