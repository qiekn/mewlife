// ----------------------------------------------------------------------------: Enigmash text menu, using its baseline and em-size layout

MENU_BACKGROUND: u32 : 0x004569;
MENU_TEXT: u32 : 0xffffff;
MENU_SELECTION: u32 : 0xeb8a30;

menu_draw :: (menu: *Menu_State, editor: *Editor, has_session: bool, enabled: bool) -> Menu_Input {
    result: Menu_Input;
    if !menu.visible then return result;
    size := ImGui.GetIO().DisplaySize;
    ImGui.SetNextWindowPos(.{0, 0}, .Always);
    ImGui.SetNextWindowSize(size, .Always);
    if enabled && menu.request_focus {
        ImGui.SetNextWindowFocus();
        menu.request_focus = false;
    }
    ImGui.PushStyleVar(.WindowRounding, 0.0);
    ImGui.PushStyleVar(.WindowBorderSize, 0.0);
    ImGui.PushStyleColor(.WindowBg, color_rgb(MENU_BACKGROUND));
    ImGui.PushFont(imgui_menu_ui_font);
    flags: ImGui.WindowFlags = .NoTitleBar | .NoResize | .NoMove | .NoCollapse
                              | .NoSavedSettings | .NoScrollbar | .NoBringToFrontOnFocus;
    if !menu.options then flags |= .NoNavInputs | .NoNavFocus;
    shown := ImGui.Begin("##MainMenu", flags = flags);
    defer {
        ImGui.End();
        ImGui.PopFont();
        ImGui.PopStyleColor();
        ImGui.PopStyleVar(2);
    }
    if !shown then return result;
    draw := ImGui.GetWindowDrawList();
    title_baseline := size.y * 0.28;
    title := ifx menu.options then "Options" else ifx menu.campaigns then "Load a Different Campaign"
             else "ENIGMASH - Remake";
    menu_centered_text(draw, imgui_title_font, imgui_title_size, size.x, title_baseline, title, MENU_TEXT);
    if !menu.options {
        stride := imgui_menu_em * 1.5;
        first_baseline := title_baseline + imgui_menu_em * 1.6 + stride;
        items := menu_items(has_session, menu.campaigns);
        for item: items {
            label := ifx menu.pending_confirmation == it_index then item.confirmation else item.label;
            baseline := first_baseline + it_index * stride;
            extent := imgui_menu_font.CalcTextSizeA(imgui_menu_font, imgui_menu_size, FLOAT32_MAX, 0, label);
            top := baseline - imgui_menu_font.Ascent * imgui_menu_size / imgui_menu_font.FontSize;
            ImGui.SetCursorPos(.{(size.x - extent.x) * 0.5 - 8, top});
            ImGui.PushID(cast(s32) it_index);
            pressed := ImGui.InvisibleButton("##MenuItem", .{extent.x + 16, imgui_menu_size});
            ImGui.PopID();
            if enabled && ImGui.IsItemHovered() && dot(ImGui.GetIO().MouseDelta, ImGui.GetIO().MouseDelta) > 0 {
                if menu.selected != it_index then menu.pending_confirmation = -1;
                menu.selected = xx it_index;
            }
            if enabled && pressed then result.clicked = xx it_index;
            color: u32 = ifx menu.selected == it_index then MENU_SELECTION else MENU_TEXT;
            menu_centered_text(draw, imgui_menu_font, imgui_menu_size, size.x, baseline, label, color);
        }
    } else {
        panel_width := min(480.0, size.x - 48);
        ImGui.SetCursorPos(.{(size.x - panel_width) * 0.5, title_baseline + imgui_menu_em});
        ImGui.BeginGroup();
        ImGui.BeginDisabled(!enabled);
        ImGui.SetNextItemWidth(230);
        ImGui.SliderFloat("Camera Speed", *editor.camera.move_speed, 0.5, 16, "%.1f m/s");
        sensitivity := editor.camera.sensitivity * 1000;
        ImGui.SetNextItemWidth(230);
        if ImGui.SliderFloat("Mouse Sensitivity", *sensitivity, 0.5, 6, "%.1f") then editor.camera.sensitivity = sensitivity / 1000;
        ImGui.Checkbox("Show Scene Inspector", *editor.visible);
        ImGui.Checkbox("Cubic Checkerboard", *editor.show_ground);
        ImGui.SetNextItemWidth(230);
        ImGui.SliderFloat("Sound Effects", *editor.sfx_volume, 0, 1, "%.2f");
        ImGui.SetNextItemWidth(230);
        ImGui.ColorEdit3("Background", *editor.background.xyz.component, .Float);
        ImGui.Spacing();
        ImGui.TextUnformatted("Game: WASD move, Shift run");
        ImGui.TextUnformatted("World time: Ctrl 0.25x, Alt 4x");
        ImGui.TextUnformatted("Free camera: F2, RMB look, WASD + Q/E");
        ImGui.TextUnformatted("Model viewer: F3 while playing");
        ImGui.TextUnformatted("Console: ` toggle, : dropdown, ; mini");
        ImGui.Spacing();
        if ImGui.Button("Back", .{100, 32}) then result.back = true;
        ImGui.EndDisabled();
        ImGui.EndGroup();
    }
    if !menu.options {
        version := "Version 0.1.0";
        extent := imgui_menu_font.CalcTextSizeA(imgui_menu_font, imgui_menu_size, FLOAT32_MAX, 0, version);
        // The supplied screenshot is a 2160px-tall menu scaled down; its original footer margin is 20px.
        margin := size.y / 108;
        top := size.y - margin - imgui_menu_font.Ascent * imgui_menu_size / imgui_menu_font.FontSize;
        draw.AddText(draw, imgui_menu_font, imgui_menu_size, .{size.x - extent.x - margin, top}, ui_color(MENU_TEXT), version);
    }
    return result;
}

#scope_file
menu_centered_text :: (draw: *ImGui.ImDrawList, font: *ImGui.ImFont, font_size: float,
                       width: float, baseline: float, text: string, rgb: u32) {
    extent := font.CalcTextSizeA(font, font_size, FLOAT32_MAX, 0, text);
    top := baseline - font.Ascent * font_size / font.FontSize;
    draw.AddText(draw, font, font_size, .{(width - extent.x) * 0.5, top}, ui_color(rgb), text);
}
#import "Basic";
#import "Math";
