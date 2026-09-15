// ----------------------------------------------------------------------------: Menu flow, independent of drawing and platform keys

Menu_Action :: enum { NONE; RESUME; START_GAME; MODEL_VIEWER; OPTIONS; CAMPAIGNS; BACK; QUIT; }
Menu_Item :: struct { action: Menu_Action; label, confirmation: string; }
Menu_Input :: struct { up, down, accept, back: bool; clicked: s32 = -1; }
Menu_State :: struct {
    visible: bool = true;
    options: bool;
    campaigns: bool;
    selected: s32;
    pending_confirmation: s32 = -1;
    request_focus: bool = true;
}

menu_items :: (has_session: bool, campaigns: bool = false) -> [] Menu_Item {
    if campaigns then return CAMPAIGN_MENU;
    return MAIN_MENU;
}

menu_open :: (menu: *Menu_State) { menu.* = .{}; }

menu_update :: (menu: *Menu_State, input: Menu_Input, has_session: bool) -> Menu_Action {
    if !menu.visible then return .NONE;
    if input.back {
        if menu.options || menu.campaigns {
            menu.options = false;
            menu.campaigns = false;
            menu.selected = 0;
            menu.pending_confirmation = -1;
            return .NONE;
        }
        if menu.pending_confirmation >= 0 { menu.pending_confirmation = -1; return .NONE; }
        if has_session { menu.visible = false; return .RESUME; }
        return .NONE;
    }
    if menu.options then return .NONE;
    items := menu_items(has_session, menu.campaigns);
    if input.up != input.down {
        direction := ifx input.up then -1 else 1;
        menu.selected = cast(s32) ((menu.selected + direction + items.count) % items.count);
        menu.pending_confirmation = -1;
    }
    if input.clicked >= 0 && input.clicked < items.count {
        if menu.selected != input.clicked then menu.pending_confirmation = -1;
        menu.selected = input.clicked;
    }
    if !input.accept && input.clicked < 0 then return .NONE;
    item := items[menu.selected];
    if item.confirmation && menu.pending_confirmation != menu.selected {
        menu.pending_confirmation = menu.selected;
        return .NONE;
    }
    menu.pending_confirmation = -1;
    if item.action == .OPTIONS { menu.options = true; menu.request_focus = true; return .NONE; }
    if item.action == .CAMPAIGNS { menu.campaigns = true; menu.selected = 0; return .NONE; }
    if item.action == .BACK { menu.campaigns = false; menu.selected = 2; return .NONE; }
    menu.visible = false;
    return item.action;
}

#scope_file
MAIN_MENU := Menu_Item.[
    .{.RESUME, "Resume Game", ""},
    .{.OPTIONS, "Options", ""},
    .{.CAMPAIGNS, "Load a Different Campaign", ""},
    .{.START_GAME, "Start a New Campaign", "Choose Again to Restart"},
    .{.QUIT, "Quit", "Quit (Are you sure?)"},
];
CAMPAIGN_MENU := Menu_Item.[
    .{.START_GAME, "First Steps", "Choose Again to Restart"},
    .{.BACK, "Back", ""},
];
