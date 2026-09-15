// ----------------------------------------------------------------------------: Shared UI palette

Naysayer :: struct {
    background      :: 0x062626;
    selection       :: 0x23444b;
    text            :: 0xd0b892;
    comment         :: 0x40c040;
    punctuation     :: 0x8cde94;
    keyword         :: 0xffffff;
    constant        :: 0x87ffde;
    white           :: 0xffffff;
    red             :: 0xf92672;
    error           :: 0xff0000;
    warning         :: 0xffaa00;
    highlight       :: 0x0b3335;
    line_fg         :: 0x126367;
    lualine_fg      :: 0x12251b;
    lualine_bg      :: 0xd3b58e;
    dimmed_variable :: 0xa0b8c8;
}

// ImGui draw lists store ABGR; callers still write ordinary 0xRRGGBB colors.
ui_color :: inline (rgb: u32, alpha: u32 = 0xff) -> u32 {
    return (alpha << 24) | ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
}
