// ----------------------------------------------------------------------------: Bounded console state and deliberately small command set

Console_Mode :: enum { FULL; SMALL; MINI; }
Console_Line_Kind :: enum { NORMAL; COMMAND; COMMENT; ERROR; }
Console_Text :: struct { bytes: [512] u8; count: s32; }
Console_Line :: struct { text: Console_Text; kind: Console_Line_Kind; }
Console :: struct {
    visible: bool;
    mode: Console_Mode = .SMALL;
    dropdown_mode: Console_Mode = .SMALL;
    input: [512] u8;
    lines: [128] Console_Line;
    line_count: s32;
    history: [64] Console_Text;
    history_count: s32;
    history_position: s32;
    draft: Console_Text;
    request_focus: bool;
    scroll_bottom: bool;
}

console_set_text :: (target: *Console_Text, text: string) {
    target.count = cast(s32) min(text.count, target.bytes.count - 1);
    memcpy(target.bytes.data, text.data, target.count);
    target.bytes[target.count] = 0;
}

console_text :: (text: *Console_Text) -> string { return .{text.count, text.bytes.data}; }

console_log :: (console: *Console, text: string, kind: Console_Line_Kind = .NORMAL) {
    if console.line_count == console.lines.count {
        for index: 1..console.lines.count - 1 { console.lines[index - 1] = console.lines[index]; }
        console.line_count -= 1;
    }
    line := *console.lines[console.line_count];
    console_set_text(*line.text, text);
    line.kind = kind;
    console.line_count += 1;
    console.scroll_bottom = true;
}

console_open :: (console: *Console, mode: Console_Mode) {
    console.visible = true;
    console.mode = mode;
    if mode != .MINI then console.dropdown_mode = mode;
    console.request_focus = true;
}

console_close :: (console: *Console) { console.visible = false; console.request_focus = false; }

// Only opening punctuation is consumed; colon and semicolon remain normal text once open.
console_shortcut :: (console: *Console, character: u32, other_text_active: bool) -> bool {
    if character == #char "`" && (console.visible || !other_text_active) {
        if console.visible then console_close(console);
        else console_open(console, console.dropdown_mode);
        return true;
    }
    if console.visible || other_text_active then return false;
    if character == #char ":" { console_open(console, console.dropdown_mode); return true; }
    if character == #char ";" { console_open(console, .MINI); return true; }
    return false;
}

console_history_step :: (console: *Console, direction: s32, current: string) -> string {
    if console.history_count == 0 then return current;
    if console.history_position == console.history_count then console_set_text(*console.draft, current);
    console.history_position = clamp(console.history_position + direction, 0, console.history_count);
    if console.history_position == console.history_count then return console_text(*console.draft);
    return console_text(*console.history[console.history_position]);
}

console_execute :: (console: *Console, text: string) {
    command := trim(text);
    if !command then return;
    if console.history_count == 0 || console_text(*console.history[console.history_count - 1]) != command {
        if console.history_count == console.history.count {
            for index: 1..console.history.count - 1 { console.history[index - 1] = console.history[index]; }
            console.history_count -= 1;
        }
        console_set_text(*console.history[console.history_count], command);
        console.history_count += 1;
    }
    console.history_position = console.history_count;
    console_log(console, tprint("$ %", command), .COMMAND);
    keep_open := false;
    if command == "help" {
        console_log(console, "help    clear    close    toggle full|small|mini", .COMMENT);
        console_log(console, "`: toggle   : dropdown   ; mini   Esc: close   Up/Down: history");
    } else if command == "clear" {
        console.line_count = 0;
    } else if command == "close" {
        console_close(console);
    } else {
        _, verb, argument := split_from_left_by_any(command, " \t");
        argument = trim(argument);
        if verb == "toggle" && (argument == "full" || argument == "small" || argument == "mini") {
            mode: Console_Mode = .SMALL;
            if argument == "full" then mode = .FULL;
            if argument == "mini" then mode = .MINI;
            console_open(console, mode);
            keep_open = true;
        } else console_log(console, "Unknown command. Type help for the available commands.", .ERROR);
    }
    if console.mode == .MINI && !keep_open then console_close(console);
}

#scope_file
#import "Basic";
#import "Math";
#import "String";
