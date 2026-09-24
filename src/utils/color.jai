color_rgb :: inline (rgb: u32, alpha: float = 1) -> Vector4 {
    return .{((rgb >> 16) & 0xff).(float) / 255,
             ((rgb >> 8) & 0xff).(float) / 255,
             (rgb & 0xff).(float) / 255, alpha};
}

#scope_file
#import "Math";
