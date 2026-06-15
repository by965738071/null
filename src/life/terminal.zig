//! 康威生命游戏 —— Conway's Game of Life。
//!
//! 规则：
//!   - 活细胞（■）：2 或 3 个活邻居 → 存活，否则死亡
//!   - 死细胞（ ）：正好 3 个活邻居 → 复活
//!   - 环形边界（上下左右互通）
//!
//! 操作：空格暂停、R 重置、Q 退出、方向键移动视角

const std = @import("std");
const input = @import("../input.zig");
const mem = std.mem;

const GRID_W: u16 = 60;
const GRID_H: u16 = 40;

/// 将 input.Key 映射为 switch 期望的 u8 字符，
/// 方向键 → 旧约定字符 (U/D/R/L)，char → 自身，enter/escape → null。
fn viewKey(k: input.Key) ?u8 {
    return switch (k) {
        .up => 'U',
        .down => 'D',
        .left => 'L',
        .right => 'R',
        .char => |c| c,
        .enter, .escape => null,
    };
}

/// 两个网格交替使用（当前 + 下一帧）
const Grid = struct {
    cells: [GRID_H][GRID_W]bool,
    /// 计算 (y, x) 的活邻居数（环形边界）
    fn countNeighbors(self: *const Grid, y: u16, x: u16) u8 {
        var count: u8 = 0;
        var dy: i4 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i4 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dy == 0 and dx == 0) continue;
                const ny = @as(i32, y) + dy;
                const nx = @as(i32, x) + dx;
                const wy = @mod(@as(i16, @intCast(ny)), GRID_H);
                const wx = @mod(@as(i16, @intCast(nx)), GRID_W);
                if (self.cells[@intCast(wy)][@intCast(wx)]) count += 1;
            }
        }
        return count;
    }
};

pub fn run(allocator: mem.Allocator, io: std.Io) !void {
    _ = allocator;

    var term = try input.Terminal.enterRawMode();
    defer term.deinit();

    var obuf: [2048]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &obuf);
    const w = &fw.interface;

    var rng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
    const rand = rng.random();

    // 两个网格：cur = 当前帧，next = 下一帧
    var cur: Grid = undefined;
    var next: Grid = undefined;
    // 随机初始状态 ~30% 存活
    for (0..GRID_H) |y| {
        for (0..GRID_W) |x| {
            cur.cells[y][x] = rand.boolean();
            next.cells[y][x] = false;
        }
    }

    var paused = false;
    var generation: u64 = 0;
    var offset_x: u16 = 0;
    var offset_y: u16 = 0;

    var buf: [65536]u8 = undefined;
    var last_step = std.Io.Timestamp.now(io, .awake);

    while (true) {
        // 输入
        while (try term.readKey()) |ik| {
            if (viewKey(ik)) |key| {
                switch (key) {
                    'q', 'Q' => {
                        try w.writeAll("\x1b[?25h\x1b[2J\x1b[H");
                        return;
                    },
                    ' ' => paused = !paused,
                    'r', 'R' => {
                        for (0..GRID_H) |y| {
                            for (0..GRID_W) |x| {
                                cur.cells[y][x] = rand.boolean();
                            }
                        }
                        generation = 0;
                        paused = false;
                    },
                    'w', 'W' => offset_y = offset_y -| 1,
                    's', 'S' => offset_y += 1,
                    'a', 'A' => offset_x = offset_x -| 1,
                    'd', 'D' => offset_x += 1,
                    else => {},
                }
            }
        }

        // 演化
        if (!paused) {
            const now = std.Io.Timestamp.now(io, .awake);
            if (last_step.durationTo(now).toMilliseconds() >= 100) {
                last_step = now;
                generation += 1;
                for (0..GRID_H) |y| {
                    for (0..GRID_W) |x| {
                        const n = cur.countNeighbors(@intCast(y), @intCast(x));
                        next.cells[y][x] = if (cur.cells[y][x]) n == 2 or n == 3 else n == 3;
                    }
                }
                // 交换 cur ↔ next
                const tmp = cur;
                cur = next;
                next = tmp;
            }
        }

        // 渲染
        var bw: std.Io.Writer = .fixed(&buf);
        try bw.writeAll("\x1b[H");
        for (0..@min(GRID_H, @as(u16, @intCast(30)))) |row| {
            const y = (row + offset_y) % GRID_H;
            for (0..@min(GRID_W, @as(u16, @intCast(80)))) |col| {
                const x = (col + offset_x) % GRID_W;
                if (cur.cells[y][x]) {
                    try bw.writeAll("\x1b[32m■\x1b[0m");
                } else {
                    try bw.writeAll(" ");
                }
            }
            try bw.writeAll("\r\n");
        }
        try bw.print("  第 {d} 代  {s}\r\n", .{ generation, if (paused) "[暂停]" else "" });
        try bw.writeAll("  空格:暂停 | R:重置 | 方向键:移动 | Q:退出\r\n");

        try w.writeAll(std.Io.Writer.buffered(&bw));
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake) catch {};
    }
}

test "演化规则：blinker oscillator" {
    // Blinker: 3 个水平细胞 → 3 个垂直细胞 → 3 个水平...
    var grid: Grid = undefined;
    for (&grid.cells) |*row| @memset(row, false);
    grid.cells[5][4] = true;
    grid.cells[5][5] = true;
    grid.cells[5][6] = true;

    var next: Grid = undefined;
    for (&next.cells) |*row| @memset(row, false);

    // 计算下一帧
    for (0..GRID_H) |y| {
        for (0..GRID_W) |x| {
            const n = grid.countNeighbors(@intCast(y), @intCast(x));
            next.cells[y][x] = if (grid.cells[y][x]) n == 2 or n == 3 else n == 3;
        }
    }

    // 验证变成垂直 3 个
    try std.testing.expect(next.cells[4][5]);
    try std.testing.expect(next.cells[5][5]);
    try std.testing.expect(next.cells[6][5]);
    // 原来水平的两个端点应该死了
    try std.testing.expect(!next.cells[5][4]);
    try std.testing.expect(!next.cells[5][6]);
}
