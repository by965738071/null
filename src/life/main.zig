const std = @import("std");
const life = @import("terminal.zig");
pub fn main(init: std.process.Init) !void {
    try life.run(init.gpa, init.io);
}
