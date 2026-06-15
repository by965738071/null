const std = @import("std");
const g = @import("terminal.zig");
pub fn main(init: std.process.Init) !void {
    try g.run(init.gpa, init.io);
}
