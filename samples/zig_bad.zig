const std = @import("std");

pub fn convertValue(value: anytype) u8 {
    if (value > 0) {
        if (value > 1) {
            if (value > 2) {
                if (value > 3) {
                    return @intCast(value);
                }
            }
        }
    }

    return 0;
}
