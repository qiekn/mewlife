// ----------------------------------------------------------------------------: ImGui controls with Meslo Nerd Font arrows

ICON_TRIANGLE_DOWN :: "";  // nf-cod-triangle_down, U+EB6E
ICON_TRIANGLE_RIGHT :: ""; // nf-cod-triangle_right, U+EB70

ui_collapsing_header :: (label: string, flags: ImGui.TreeNodeFlags = .None) -> bool {
    draw := ImGui.GetWindowDrawList();
    position := ImGui.GetCursorScreenPos();
    font := ImGui.GetFont();
    size := ImGui.GetFontSize();
    padding := ImGui.GetStyle().FramePadding;
    color := ImGui.GetColorU32(.Text);
    // Keep ImGui's item ID, navigation, open state, hit testing and header background.
    // Its original arrow/text are hidden together, then drawn with the requested glyph.
    ImGui.PushStyleColor(.Text, color_rgb(0xffffff, 0));
    expanded := ImGui.CollapsingHeader(temp_c_string(label), flags);
    ImGui.PopStyleColor();
    if ImGui.IsItemVisible() {
        lower := ImGui.GetItemRectMin();
        upper := ImGui.GetItemRectMax();
        ui_triangle(draw, .{lower.x + padding.x, lower.y}, .{lower.x + padding.x + size, upper.y}, expanded, color, size);
        text_pos := position + .{size + padding.x * 3, padding.y};
        clip := Vector4.{text_pos.x, lower.y, upper.x - padding.x, upper.y};
        draw.AddText(draw, font, size, text_pos, color, ui_visible_label(label), cpu_fine_clip_rect = *clip);
    }
    return expanded;
}

// Pair a successful call with ImGui.EndCombo(), exactly like ImGui.BeginCombo().
ui_begin_combo :: (label: string, preview: string) -> bool {
    draw := ImGui.GetWindowDrawList();
    position := ImGui.GetCursorScreenPos();
    width := ImGui.CalcItemWidth();
    height := ImGui.GetFrameHeight();
    font := ImGui.GetFont();
    size := ImGui.GetFontSize();
    padding := ImGui.GetStyle().FramePadding;
    color := ImGui.GetColorU32(.Text);
    expanded := ImGui.BeginCombo(temp_c_string(label), "", .NoArrowButton);
    // BeginCombo may now be in its popup; draw into the saved parent draw list and font.
    lower := position + .{max(0.0, width - height), 0};
    upper := position + .{width, height};
    ui_triangle(draw, lower, upper, true, color, size);
    clip := Vector4.{position.x + padding.x, position.y, lower.x - padding.x, upper.y};
    draw.AddText(draw, font, size, position + padding, color, preview, cpu_fine_clip_rect = *clip);
    return expanded;
}

#scope_file

ui_triangle :: (draw: *ImGui.ImDrawList, lower: Vector2, upper: Vector2, down: bool, color: u32, size: float) {
    font := ImGui.GetIO().FontDefault;
    codepoint: ImGui.ImWchar = ifx down then cast(ImGui.ImWchar) 0xeb6e else cast(ImGui.ImWchar) 0xeb70;
    glyph := font.FindGlyphNoFallback(font, codepoint);
    assert(glyph != null, "Meslo Codicon glyph missing from the font atlas.");
    scale := size / font.FontSize;
    // Center the actual ink, not the monospaced advance, at every display DPI.
    extent := Vector2.{glyph.X1 - glyph.X0, glyph.Y1 - glyph.Y0} * scale;
    position := (lower + upper - extent) * 0.5 - Vector2.{glyph.X0, glyph.Y0} * scale;
    draw.AddText(draw, font, size, position, color, ifx down then ICON_TRIANGLE_DOWN else ICON_TRIANGLE_RIGHT);
}

ui_visible_label :: (label: string) -> string {
    for index: 0..label.count - 2 {
        if label[index] == #char "#" && label[index + 1] == #char "#" then return .{index, label.data};
    }
    return label;
}

#import "Basic";
#import "Math";
#import "String";
