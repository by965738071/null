const std = @import("std");
const rt = @import("terminal.zig");
pub fn main(init: std.process.Init) !void {
    try rt.render(init.gpa, init.io);
}
