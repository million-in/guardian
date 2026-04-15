const std = @import("std");

pub fn clampPositive(value: i32) i32 {
    if (value < 0) {
        return 0;
    }

    return value;
}
