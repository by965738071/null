const std = @import("std");
const tetris = @import("terminal.zig");
pub fn main(init: std.process.Init) !void {
    try tetris.run(init.gpa, init.io);
}
