// ----------------------------------------------------------------------------: Jai window and input backend

Imgui_Input :: struct {
    window: u64;
    last_time: float64;
    focused: bool;
    cursors: [9] *void;
}

// Install before creating the single native window. DPI awareness is set by the executable manifest.
imgui_input_prepare_window :: () {
    #if OS == .WINDOWS {
        previous_window_proc = context.input_handler.window_proc;
        context.input_handler.window_proc = imgui_window_proc;
    }
}

imgui_input_dpi_scale :: (window: u64) -> float {
    #if OS == .WINDOWS {
        dpi := get_dpi_for_window(cast(Win32.HWND) window);
        return max(dpi, 96).(float) / 96.0;
    } else #if OS == .MACOS {
        return cast(float) NSWindow.backingScaleFactor(cast(*NSWindow) window);
    } else {
        return 1.0;
    }
}

imgui_input_init :: (input: *Imgui_Input, window: u64) {
    input.window = window;
    input.last_time = seconds_since_init();
    io := ImGui.GetIO();
    assert(io.BackendPlatformUserData == null);
    io.BackendPlatformName = "imgui_jai_input";
    io.BackendPlatformUserData = input;
    ImGui.GetMainViewport().PlatformHandleRaw = cast(*void) window;

    #if OS == .WINDOWS {
        cursor_ids := *void.[Win32.IDC_ARROW, Win32.IDC_IBEAM, Win32.IDC_SIZEALL,
                             Win32.IDC_SIZENS, Win32.IDC_SIZEWE, Win32.IDC_SIZENESW,
                             Win32.IDC_SIZENWSE, Win32.IDC_HAND, Win32.IDC_NO];
        for cursor_ids {
            input.cursors[it_index] = Win32.LoadCursorW(null, xx it);
        }
        io.BackendFlags_ |= .HasMouseCursors;
    }
}

imgui_input_window_size :: (window: u64) -> s32, s32 {
    #if OS == .WINDOWS {
        if Input.window_minimized then return 0, 0;
    }
    _, _, width, height, success := Window.get_dimensions(cast(Window.Window_Type) window, false);
    if !success then return 0, 0;
    return max(width, 0), max(height, 0);
}

// Call after Input.update_window_events(), including while the window is minimized.
// For rendered frames, call after swapchain acquisition so mouse coordinates are fresh at NewFrame.
// Jai's window helpers report physical client pixels; ImGui operates in logical coordinates.
imgui_input_update :: (input: *Imgui_Input, width: s32, height: s32, dpi_scale: float) {
    io := ImGui.GetIO();
    now := seconds_since_init();
    io.DeltaTime = cast(float) max(now - input.last_time, 0.000001);
    input.last_time = now;
    io.DisplaySize = .{width.(float) / dpi_scale, height.(float) / dpi_scale};
    io.DisplayFramebufferScale = .{dpi_scale, dpi_scale};

    focused := Input.input_application_has_focus;
    if input.focused != focused {
        io.AddFocusEvent(io, focused);
        input.focused = focused;
    }

    x, y, mouse_valid := Window.get_mouse_pointer_position(cast(Window.Window_Type) input.window, false);
    if mouse_valid && focused {
        io.AddMousePosEvent(io, x.(float) / dpi_scale, y.(float) / dpi_scale);
    } else {
        io.AddMousePosEvent(io, -FLOAT32_MAX, -FLOAT32_MAX);
    }

    for event: Input.events_this_frame {
        if event.type == {
            case .KEYBOARD;
                down := event.key_pressed != 0;
                io.AddKeyEvent(io, .Mod_Ctrl, event.ctrl_pressed);
                io.AddKeyEvent(io, .Mod_Shift, event.shift_pressed);
                io.AddKeyEvent(io, .Mod_Alt, event.alt_pressed);
                io.AddKeyEvent(io, .Mod_Super, event.cmd_meta_pressed);

                button := imgui_mouse_button(event.key_code);
                if button >= 0 {
                    io.AddMouseButtonEvent(io, button, down);
                } else {
                    key := imgui_key(event.key_code);
                    if key != .None then io.AddKeyEvent(io, key, down);
                }
            case .TEXT_INPUT;
                #if OS == .WINDOWS {
                    // Input forwards WM_CHAR UTF-16 code units on Windows.
                    io.AddInputCharacterUTF16(io, xx event.utf32);
                } else {
                    io.AddInputCharacter(io, event.utf32);
                }
            case .MOUSE_WHEEL;
                if event.typical_wheel_delta != 0 {
                    io.AddMouseWheelEvent(io, 0, event.wheel_delta.(float) / event.typical_wheel_delta.(float));
                }
        }
    }
}

imgui_input_update_cursor :: (input: *Imgui_Input) {
    #if OS == .WINDOWS {
        io := ImGui.GetIO();
        if io.ConfigFlags_ & .NoMouseCursorChange then return;
        x, y, valid := Window.get_mouse_pointer_position(cast(Window.Window_Type) input.window, false);
        // Leave the OS in charge over the title bar, resize borders and other windows.
        over_client := valid && input.focused && x >= 0 && y >= 0
                    && x.(float) < io.DisplaySize.x * io.DisplayFramebufferScale.x
                    && y.(float) < io.DisplaySize.y * io.DisplayFramebufferScale.y;
        Input.set_custom_cursor_handling(over_client);
        if !over_client then return;
        cursor := ImGui.GetMouseCursor();
        if io.MouseDrawCursor || cursor == .None {
            Win32.SetCursor(null);
        } else {
            Win32.SetCursor(input.cursors[cursor]);
        }
    }
}

imgui_input_shutdown :: (input: *Imgui_Input) {
    #if OS == .WINDOWS {
        Input.set_custom_cursor_handling(false);
        context.input_handler.window_proc = previous_window_proc;
    }
    io := ImGui.GetIO();
    io.BackendPlatformName = null;
    io.BackendPlatformUserData = null;
    io.BackendFlags_ &= ~ImGui.BackendFlags.HasMouseCursors;
    input.* = .{};
}

#scope_file

imgui_mouse_button :: (key: Input.Key_Code) -> s32 {
    if key == {
        case .MOUSE_BUTTON_LEFT;    return 0;
        case .MOUSE_BUTTON_RIGHT;   return 1;
        case .MOUSE_BUTTON_MIDDLE;  return 2;
        case .MOUSE_BUTTON_EXTRA_1; return 3;
        case .MOUSE_BUTTON_EXTRA_2; return 4;
    }
    return -1;
}

imgui_key :: (key: Input.Key_Code) -> ImGui.Key {
    value := key.(u32);
    if value >= #char "A" && value <= #char "Z" {
        return cast(ImGui.Key) (ImGui.Key.A.(u32) + value - #char "A");
    }
    if value >= #char "a" && value <= #char "z" {
        return cast(ImGui.Key) (ImGui.Key.A.(u32) + value - #char "a");
    }
    if value >= #char "0" && value <= #char "9" {
        return cast(ImGui.Key) (ImGui.Key._0.(u32) + value - #char "0");
    }
    if key >= .F1 && key <= .F12 {
        return cast(ImGui.Key) (ImGui.Key.F1.(u32) + value - Input.Key_Code.F1.(u32));
    }
    if key == {
        case .TAB;          return .Tab;
        case .ARROW_LEFT;   return .LeftArrow;
        case .ARROW_RIGHT;  return .RightArrow;
        case .ARROW_UP;     return .UpArrow;
        case .ARROW_DOWN;   return .DownArrow;
        case .PAGE_UP;      return .PageUp;
        case .PAGE_DOWN;    return .PageDown;
        case .HOME;         return .Home;
        case .END;          return .End;
        case .INSERT;       return .Insert;
        case .DELETE;       return .Delete;
        case .BACKSPACE;    return .Backspace;
        case .SPACEBAR;     return .Space;
        case .ENTER;        return .Enter;
        case .ESCAPE;       return .Escape;
        case .CTRL;         return .LeftCtrl;
        case .SHIFT;        return .LeftShift;
        case .ALT;          return .LeftAlt;
        case .CMD;          return .LeftSuper;
        case .PAUSE;        return .Pause;
        case .SCROLL_LOCK;  return .ScrollLock;
        case .PRINT_SCREEN; return .PrintScreen;
    }
    if value == {
        case #char "'";  return .Apostrophe;
        case #char ",";  return .Comma;
        case #char "-";  return .Minus;
        case #char ".";  return .Period;
        case #char "/";  return .Slash;
        case #char ";";  return .Semicolon;
        case #char "=";  return .Equal;
        case #char "[";  return .LeftBracket;
        case #char "\\"; return .Backslash;
        case #char "]";  return .RightBracket;
        case #char "`";  return .GraveAccent;
    }
    return .None;
}

#import "Basic";
#import "Math";
Input :: #import "Input";
Window :: #import "Window_Creation"(DEFAULT_MSAA = 1);
#if OS == .WINDOWS {
    Win32 :: #import "Windows";
    user32 :: #library,system "user32";
    get_dpi_for_window :: (window: Win32.HWND) -> u32 #foreign user32 "GetDpiForWindow";
    previous_window_proc: type_of(Input.MyWindowProc);

    imgui_window_proc :: (window: Win32.HWND, message: u32,
                          wparam: Win32.WPARAM, lparam: Win32.LPARAM) -> s64 #c_call {
        push_context {
            if message == Win32.WM_DPICHANGED {
                rect := cast(*Win32.RECT) lparam;
                Win32.SetWindowPos(window, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                                   Win32.SWP_NOZORDER | Win32.SWP_NOACTIVATE);
                return 0;
            }
            return previous_window_proc(window, message, wparam, lparam);
        }
    }
} else #if OS == .MACOS {
    #import "Objective_C";
    #import "Objective_C/AppKit";
}
