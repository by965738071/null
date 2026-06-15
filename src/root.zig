//! null 包：Zig 练手项目集合。

const std = @import("std");
const Io = std.Io;

pub const arena = @import("arena.zig");
pub const brainfuck = @import("brainfuck.zig");
pub const input = @import("input.zig");

const snake = @import("snake/terminal.zig");
const tetris = @import("tetris/terminal.zig");
const game2048 = @import("game2048/terminal.zig");
const life = @import("life/terminal.zig");
const raytrace = @import("raytrace/terminal.zig");

pub fn runSnake(gpa: std.mem.Allocator, io: Io) !void {
    try snake.run(gpa, io);
}
pub fn runTetris(gpa: std.mem.Allocator, io: Io) !void {
    try tetris.run(gpa, io);
}
pub fn run2048(gpa: std.mem.Allocator, io: Io) !void {
    try game2048.run(gpa, io);
}
pub fn runLife(gpa: std.mem.Allocator, io: Io) !void {
    try life.run(gpa, io);
}
pub fn runRaytrace(gpa: std.mem.Allocator, io: Io) !void {
    try raytrace.render(gpa, io);
}

/// Arena 分配器演示
pub fn runArenaDemo(gpa: std.mem.Allocator, io: Io) !void {
    _ = gpa;
    const stderr = Io.File.stderr();
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(stderr, io, &stderr_buf);
    const w = &stderr_writer.interface;

    try w.print("\n📦 Arena Allocator 演示\n\n", .{});
    var a = try arena.Arena.init(std.heap.page_allocator, 256);
    defer a.deinit();
    const alloc = a.allocator();

    try w.print("  初始状态: allocated={d}, remaining={d}\n", .{ a.allocatedBytes(), a.remainingBytes() });
    const buf1 = try alloc.alloc(u8, 100);
    @memset(buf1, 0x41);
    try w.print("  分配 100 字节后: allocated={d}, remaining={d}\n", .{ a.allocatedBytes(), a.remainingBytes() });
    const buf2 = try alloc.alloc(u8, 80);
    @memset(buf2, 0x42);
    try w.print("  再分配 80 字节后: allocated={d}, remaining={d}\n", .{ a.allocatedBytes(), a.remainingBytes() });
    try w.print("  buf1[0] = '{c}', buf2[0] = '{c}'\n", .{ buf1[0], buf2[0] });

    const buf3 = alloc.alloc(u8, 200);
    if (buf3) |_| {
        try w.print("  意外: 200 字节分配成功了?\n", .{});
    } else |_| {
        try w.print("  ❌ 分配 200 字节失败 ——符合预期\n", .{});
    }

    a.reset();
    try w.print("\n  🔄 Reset 后: allocated={d}, remaining={d}\n", .{ a.allocatedBytes(), a.remainingBytes() });
    const buf4 = try alloc.alloc(u8, 200);
    @memset(buf4, 0x43);
    try w.print("  Reset 后分配 200 字节成功, buf4[0] = '{c}'\n", .{buf4[0]});
    try w.print("  ⚠️  buf1[0] 现在是 '{c}' (被 buf4 覆盖了!)\n", .{buf1[0]});
    try w.print("\n  ✅ Arena 演示完成。核心要点:\n", .{});
    try w.print("     1. Arena 是 bump allocator，分配极快\n", .{});
    try w.print("     2. 不单独释放，整体 reset\n", .{});
    try w.print("     3. Reset 后旧指针可能被覆盖\n", .{});
    try w.print("     4. 适合请求级/帧级生命周期\n\n", .{});
    try stderr_writer.flush();
}

test "basic add functionality" {
    try std.testing.expect(arena.Arena.default_node_size == 65536);
}
