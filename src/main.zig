const std = @import("std");
const Io = std.Io;

const null_mod = @import("null");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena_alloc = init.arena.allocator();
    const io = init.io;

    // 解析命令行参数
    const args = try init.minimal.args.toSlice(arena_alloc);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "snake")) {
            try null_mod.runSnake(gpa, io);
            return;
        }
        if (std.mem.eql(u8, args[1], "tetris")) {
            try null_mod.runTetris(gpa, io);
            return;
        }
        if (std.mem.eql(u8, args[1], "2048")) {
            try null_mod.run2048(gpa, io);
            return;
        }
        if (std.mem.eql(u8, args[1], "life")) {
            try null_mod.runLife(gpa, io);
            return;
        }
        if (std.mem.eql(u8, args[1], "raytrace")) {
            try null_mod.runRaytrace(gpa, io);
            return;
        }
        if (std.mem.eql(u8, args[1], "arena")) {
            try null_mod.runArenaDemo(gpa, io);
            return;
        }
    }

    // 默认：打印帮助
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print(
        \\
        \\╔══════════════════════════════════════════╗
        \\║       🧪 Zig 练手项目                   ║
        \\╠══════════════════════════════════════════╣
        \\║  snake    →  🐍 贪吃蛇                  ║
        \\║  tetris   →  🧱 俄罗斯方块              ║
        \\║  2048     →  🔢 2048                    ║
        \\║  life     →  🧬 生命游戏                ║
        \\║  raytrace →  🎨 光线追踪 (stdout)       ║
        \\║  arena    →  📦 Arena 分配器            ║
        \\║  test     →  🧪 运行测试                ║
        \\╚══════════════════════════════════════════╝
        \\
    , .{});
    try stdout_writer.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
