// ----------------------------------------------------------------------------: Held keys and ordered, non-repeating press events

Platform_Key_Press :: struct { key: Input.Key_Code; shift, ctrl, alt: bool; }

Platform_Input :: struct {
    held: [512] bool;
    pressed: [512] bool;
    key_presses: [..] Platform_Key_Press;
    mouse_delta: Vector2;
    focused: bool;
    mouse_look: bool;
    window: u64;
}

platform_read_input :: (input: *Platform_Input) {
    array_reset(*input.key_presses);
    for *input.pressed { it.* = false; }
    input.mouse_delta = .{};
    input.focused = Input.input_application_has_focus;
    if !input.focused {
        for *input.held { it.* = false; }
        // Jai Input currently documents stuck keys after Alt-Tab on Windows.
        for *Input.input_button_states { it.* = .NONE; }
        platform_mouse_look(input, false);
        return;
    }
    input.mouse_delta = .{Input.mouse_delta_x.(float), Input.mouse_delta_y.(float)};
    for event: Input.events_this_frame {
        if event.type != .KEYBOARD then continue;
        code := event.key_code.(u32);
        if code >= input.held.count then continue;
        down := event.key_pressed != 0;
        if down && !input.held[code] && !event.repeat {
            input.pressed[code] = true;
            array_add(*input.key_presses, .{event.key_code, event.shift_pressed, event.ctrl_pressed, event.alt_pressed});
        }
        input.held[code] = down;
        if event.key_code != .CTRL then input.held[Input.Key_Code.CTRL] = event.ctrl_pressed;
        if event.key_code != .SHIFT then input.held[Input.Key_Code.SHIFT] = event.shift_pressed;
        if event.key_code != .ALT then input.held[Input.Key_Code.ALT] = event.alt_pressed;
    }
}

platform_down :: (input: *Platform_Input, key: Input.Key_Code) -> bool { return input.held[key]; }
platform_pressed :: (input: *Platform_Input, key: Input.Key_Code) -> bool { return input.pressed[key]; }

platform_input_shutdown :: (input: *Platform_Input) {
    platform_mouse_look(input, false);
    array_free(input.key_presses);
}

platform_mouse_look :: (input: *Platform_Input, enabled: bool) {
    enabled = enabled && input.focused;
    #if OS == .WINDOWS {
        if enabled {
            rect: Win32.RECT;
            Win32.GetClientRect(cast(Win32.HWND) input.window, *rect);
            origin := Win32.POINT.{rect.left, rect.top};
            Win32.ClientToScreen(cast(Win32.HWND) input.window, *origin);
            rect.right += origin.x; rect.bottom += origin.y;
            rect.left = origin.x; rect.top = origin.y;
            Win32.ClipCursor(*rect);
            if !input.mouse_look then Win32.SetCapture(cast(Win32.HWND) input.window);
            Input.set_custom_cursor_handling(true);
            Win32.SetCursor(null);
        } else if input.mouse_look {
            Win32.ClipCursor(null);
            Win32.ReleaseCapture();
            Input.set_custom_cursor_handling(false);
        }
    }
    input.mouse_look = enabled;
}

#scope_file
Input :: #import "Input";
#import "Basic";
#import "Math";
#if OS == .WINDOWS { Win32 :: #import "Windows"; }
