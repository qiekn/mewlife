// Native window size is specified in logical client dimensions, before display DPI scaling.
create_native_window :: (width: int, height: int, name: string) -> u64 {
    // Standard window creation module does not yet support creating a window with Metal surface for macOS.
    // We will use the standard library module on all other platforms.
    #if OS == .MACOS {
        screen := NSScreen.mainScreen();
        scale := NSScreen.backingScaleFactor(screen);
        work_area := NSScreen.visibleFrame(screen);
        pixel_width := cast(int) (min(width.(float64), work_area.size.width * 0.95) * scale);
        pixel_height := cast(int) (min(height.(float64), work_area.size.height * 0.95) * scale);
        return create_window_metal(pixel_width, pixel_height, name).(u64);
    } else {
        window := create_window(width, height, name);
        assert(window.(u64) != 0);
        #if OS == .WINDOWS {
            scale := max(native_get_dpi_for_window(window), 96).(float) / 96.0;
            frame, client: Win32.RECT;
            assert(Win32.GetWindowRect(window, *frame) != 0);
            assert(Win32.GetClientRect(window, *client) != 0);
            border_width := (frame.right - frame.left) - (client.right - client.left);
            border_height := (frame.bottom - frame.top) - (client.bottom - client.top);

            monitor := Win32.MonitorFromWindow(window, Win32.MONITOR_DEFAULTTONEAREST);
            info := Win32.MONITORINFO.{cbSize = xx size_of(Win32.MONITORINFO)};
            assert(Win32.GetMonitorInfoW(monitor, *info) != 0);
            work := info.rcWork;
            work_width := work.right - work.left;
            work_height := work.bottom - work.top;

            // Include the title bar and borders, and leave room around the centered window.
            outer_width := min(cast(s32) (width.(float) * scale) + border_width,
                               cast(s32) (work_width.(float) * 0.95));
            outer_height := min(cast(s32) (height.(float) * scale) + border_height,
                                cast(s32) (work_height.(float) * 0.95));
            x := work.left + (work_width - outer_width) / 2;
            y := work.top + (work_height - outer_height) / 2;
            assert(Win32.SetWindowPos(window, null, x, y, outer_width, outer_height,
                                     Win32.SWP_NOZORDER | Win32.SWP_NOACTIVATE) != 0);
        }
        return window.(u64);
    }
}

#if OS == .MACOS {
    #load "macos_window.jai";
} else {
    #import "Window_Creation"(DEFAULT_MSAA = 1);
}

#scope_file
#import "Basic";
#if OS == .WINDOWS {
    Win32 :: #import "Windows";
    native_user32 :: #library,system "user32";
    native_get_dpi_for_window :: (window: Win32.HWND) -> u32 #foreign native_user32 "GetDpiForWindow";
} else #if OS == .MACOS {
    #import "Objective_C/AppKit";
}
