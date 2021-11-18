const std = @import("std");
const unit = @import("unit.zig");
const rt = @import("route.zig");

test "Run all tests" {
    std.testing.refAllDecls(@This());
}

