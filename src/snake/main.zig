const std = @import("std");
const snake = @import("terminal.zig");
pub fn main(init: std.process.Init) !void {
    try snake.run(init.gpa, init.io);
}
