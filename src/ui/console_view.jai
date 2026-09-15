// ----------------------------------------------------------------------------: Dropdown console, styled after ootss-cmd

console_draw :: (console: *Console) {
    if !console.visible then return;
    viewport := ImGui.GetIO().DisplaySize;
    mini := console.mode == .MINI;
    padding: float = 12;
    input_height := ImGui.GetFrameHeight();
    footer_height: float = 28;
    height := viewport.y;
    if console.mode == .SMALL then height = min(viewport.y, max(180.0, viewport.y * 0.3));
    width := viewport.x;
    position := Vector2.{0, 0};
    if mini {
        height = input_height + padding * 2;
        width = min(780.0, viewport.x - 24);
        position = .{12, viewport.y - height - 12};
    }
    ImGui.SetNextWindowPos(position, .Always);
    ImGui.SetNextWindowSize(.{width, height}, .Always);
    if console.request_focus then ImGui.SetNextWindowFocus();
    ImGui.PushStyleVar(.WindowRounding, 0.0);
    ImGui.PushStyleVar(.WindowBorderSize, 0.0);
    ImGui.PushStyleVar(.WindowPadding, .{padding, padding});
    ImGui.PushStyleVar(.FrameRounding, 0.0);
    ImGui.PushStyleColor(.WindowBg, color_rgb(Naysayer.background));
    ImGui.PushStyleColor(.Text, color_rgb(Naysayer.text));
    ImGui.PushStyleColor(.FrameBg, color_rgb(Naysayer.highlight));
    ImGui.PushStyleColor(.TextSelectedBg, color_rgb(Naysayer.selection));
    ImGui.PushStyleColor(.Border, color_rgb(Naysayer.line_fg));
    defer ImGui.PopStyleColor(5);
    defer ImGui.PopStyleVar(4);
    shown := ImGui.Begin("##DropdownConsole", flags = .NoTitleBar | .NoResize | .NoMove | .NoCollapse
                                                    | .NoSavedSettings | .NoScrollbar | .NoNavFocus);
    defer ImGui.End();
    if !shown then return;
    draw := ImGui.GetWindowDrawList();
    if !mini {
        log_height := max(1.0, height - input_height - footer_height - padding * 3);
        if ImGui.BeginChild("##ConsoleOutput", .{0, log_height}, false, .NoNavInputs | .NoNavFocus) {
            for index: 0..console.line_count - 1 {
                line := *console.lines[index];
                color := color_rgb(Naysayer.text);
                if line.kind == .COMMENT then color = color_rgb(Naysayer.comment);
                if line.kind == .ERROR then color = color_rgb(Naysayer.red);
                ImGui.PushStyleColor(.Text, color);
                ImGui.TextUnformatted(console_text(*line.text));
                ImGui.PopStyleColor();
            }
            if console.scroll_bottom {
                ImGui.SetScrollHereY(1);
                console.scroll_bottom = false;
            }
        }
        ImGui.EndChild();
        ImGui.SetCursorPos(.{padding, height - footer_height - input_height - padding});
        draw.AddRectFilled(draw, .{0, height - footer_height}, .{width, height}, ui_color(Naysayer.lualine_bg));
        mode_name := ifx console.mode == .FULL then "full" else "small";
        draw.AddText(draw, .{padding, height - footer_height + 4}, ui_color(Naysayer.lualine_fg),
                     tprint("%   |   help    toggle full / small / mini    |    Esc close", mode_name));
    }
    ImGui.AlignTextToFramePadding();
    ImGui.TextUnformatted("$");
    ImGui.SameLine();
    ImGui.SetNextItemWidth(-1);
    if console.request_focus {
        ImGui.SetKeyboardFocusHere();
        console.request_focus = false;
    }
    if ImGui.InputText("##ConsoleInput", console.input.data, console.input.count,
                       .EnterReturnsTrue | .CallbackHistory, console_input_callback, console) {
        console_execute(console, to_string(console.input.data));
        console.input[0] = 0;
        console.request_focus = console.visible;
    }
}

#scope_file

console_input_callback :: (data: *ImGui.InputTextCallbackData) -> s32 #c_call {
    push_context {
        if data.EventFlag == .CallbackHistory {
            console := cast(*Console) data.UserData;
            direction := ifx data.EventKey == .UpArrow then -1 else 1;
            current := string.{data.BufTextLen, data.Buf};
            text := console_history_step(console, xx direction, current);
            data.DeleteChars(data, 0, data.BufTextLen);
            data.InsertChars(data, 0, text);
        }
        return 0;
    }
}

#import "Basic";
#import "Math";
#import "String";
