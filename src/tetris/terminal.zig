//! 终端俄罗斯方块 —— 经典下落方块游戏。
//!
//! ## 架构概览
//!
//! 整个文件分为以下几个逻辑块：
//!   1. 共享终端输入（via `input.zig`：raw 模式 + 按键解码）
//!   2. 方块系统（7 种标准方块，4×4 u8 矩阵表示，矩阵转置+水平翻转旋转）
//!   3. 游戏状态（Game 结构体：棋盘、当前/下一个方块、分数、速度）
//!   4. 渲染器（Renderer：ANSI escape codes + 帧缓冲区）
//!   5. 按键映射（toGameKey：input.Key → 游戏 Key）
//!   6. 主循环（run 函数）
//!
//! ## 操作
//!   - ← → : 左右移动
//!   - ↓ : 软降（加速下落）
//!   - ↑ : 旋转（顺时针 90°）
//!   - 空格 : 硬降到底
//!   - Q : 退出
//!   - P : 暂停/继续
//!
//! ## 计分规则
//!   - 消 1 行 → 100 分
//!   - 消 2 行 → 300 分
//!   - 消 3 行 → 500 分
//!   - 消 4 行 → 800 分
//!   - 每消 10 行升一级，速度加快

const std = @import("std");
const mem = std.mem;
const input = @import("../input.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// 游戏常量
// ═══════════════════════════════════════════════════════════════════════════════

/// 棋盘宽度（格子数）
const BOARD_WIDTH: u8 = 10;
/// 棋盘高度（格子数）
const BOARD_HEIGHT: u8 = 20;
/// 棋盘总格数
const BOARD_SIZE = BOARD_WIDTH * BOARD_HEIGHT;

/// 7 种标准俄罗斯方块，每种用 4×4 的 u8 矩阵表示。
/// 每行是一个 u8，低 4 位对应从左到右的 4 列（bit 3 = 最左列，bit 0 = 最右列）。
const PIECES = [_][4]u8{
    // I: ████
    .{ 0b0000, 0b1111, 0b0000, 0b0000 },
    // O: ██
    //    ██
    .{ 0b0110, 0b0110, 0b0000, 0b0000 },
    // T:  █
    //    ███
    .{ 0b0100, 0b1110, 0b0000, 0b0000 },
    // S:  ██
    //    ██
    .{ 0b0110, 0b1100, 0b0000, 0b0000 },
    // Z: ██
    //     ██
    .{ 0b1100, 0b0110, 0b0000, 0b0000 },
    // J: █
    //    ███
    .{ 0b1000, 0b1110, 0b0000, 0b0000 },
    // L:   █
    //    ███
    .{ 0b0010, 0b1110, 0b0000, 0b0000 },
};

/// 每种方块的 ANSI 前景色转义码（与 PIECES 索引对应）
const PIECE_COLORS = [_][]const u8{
    "\x1b[36m", // I: 青色
    "\x1b[33m", // O: 黄色
    "\x1b[35m", // T: 紫色
    "\x1b[32m", // S: 绿色
    "\x1b[31m", // Z: 红色
    "\x1b[34m", // J: 蓝色
    "\x1b[37m", // L: 白色
};

// ═══════════════════════════════════════════════════════════════════════════════
// 方块旋转：矩阵转置 + 水平翻转（顺时针 90°）
// ═══════════════════════════════════════════════════════════════════════════════

/// 将 4×4 矩阵顺时针旋转 90°。
/// 算法：先转置矩阵，再水平翻转每一行。
///
/// 示例（T 方块）：
///   原始:  0100    转置:  0100    翻转:  0010
///          1110           1100           0011
///          0000           0100           0010
///          0000           0000           0000
fn rotatePiece(shape: [4]u8) [4]u8 {
    // 第一步：转置（行变列）
    var transposed = [_]u8{ 0, 0, 0, 0 };
    for (0..4) |row| {
        for (0..4) |col| {
            // 检查原始矩阵 (row, col) 是否有方块
            if ((shape[row] >> @intCast(3 - col)) & 1 == 1) {
                // 转置后放到 (col, row)
                transposed[col] |= @as(u8, 1) << @intCast(3 - row);
            }
        }
    }
    // 第二步：水平翻转每一行（@bitReverse 反转所有 8 位，>> 4 取低 4 位）
    var result = [_]u8{ 0, 0, 0, 0 };
    for (0..4) |row| {
        result[row] = @bitReverse(transposed[row]) >> 4;
    }
    return result;
}

/// 获取方块的 ANSI 颜色码
fn pieceColor(piece_index: u3) []const u8 {
    return PIECE_COLORS[piece_index];
}

/// 获取指定旋转次数的方块形状
fn getShape(piece_index: u3, rotation: u2) [4]u8 {
    var shape = PIECES[piece_index];
    var i: u2 = 0;
    while (i < rotation) : (i += 1) {
        shape = rotatePiece(shape);
    }
    return shape;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 游戏状态
// ═══════════════════════════════════════════════════════════════════════════════

const Game = struct {
    /// 棋盘：BOARD_HEIGHT 行 × BOARD_WIDTH 列。
    /// 0 = 空格，1~7 = 对应颜色的方块（索引 + 1，因为 0 表示空）。
    board: [BOARD_HEIGHT][BOARD_WIDTH]u8,

    /// 当前活动方块的类型索引（0~6）
    current_piece: u3,
    /// 当前活动方块的旋转次数（0~3）
    current_rotation: u2,
    /// 当前活动方块左上角在棋盘上的列位置（可超出左/右边界用于旋转）
    current_x: i16,
    /// 当前活动方块左上角在棋盘上的行位置（可为负，表示部分在顶部之上）
    current_y: i16,

    /// 下一个方块的类型索引
    next_piece: u3,

    /// 当前得分
    score: u32,
    /// 当前等级（每消 10 行 +1）
    level: u32,
    /// 累计消除行数
    lines_cleared: u32,

    /// 游戏是否运行中
    running: bool,
    /// 是否暂停
    paused: bool,

    /// 下落间隔（毫秒），随等级提高而减小
    drop_interval_ms: u32,

    /// 随机数生成器
    rng: std.Random.DefaultPrng,

    /// 初始化游戏状态。
    /// 棋盘清空，生成第一个当前方块和下一个方块。
    pub fn init(seed: u64) Game {
        var game = Game{
            .board = undefined,
            .current_piece = 0,
            .current_rotation = 0,
            .current_x = 0,
            .current_y = 0,
            .next_piece = 0,
            .score = 0,
            .level = 0,
            .lines_cleared = 0,
            .running = true,
            .paused = false,
            .drop_interval_ms = 800,
            .rng = std.Random.DefaultPrng.init(seed),
        };
        // 清空棋盘
        for (&game.board) |*row| {
            @memset(row, @as(u8, 0));
        }
        // 生成初始的两个方块
        game.current_piece = game.randomPiece();
        game.next_piece = game.randomPiece();
        game.spawnPiece();
        return game;
    }

    /// 从 7 种方块中随机选一种
    fn randomPiece(self: *Game) u3 {
        return @intCast(self.rng.random().uintAtMost(u3, 6));
    }

    /// 将当前方块放到初始位置（棋盘顶部居中）
    fn spawnPiece(self: *Game) void {
        self.current_rotation = 0;
        // 水平居中：棋盘宽 10，方块占 4 列，居中开始于列 (10-4)/2 = 3
        self.current_x = 3;
        // 垂直位置：第 0 行（方块从顶部出现）
        self.current_y = 0;
        // 检查是否一出现就碰撞 → 游戏结束
        if (self.checkCollision(getShape(self.current_piece, self.current_rotation), self.current_x, self.current_y)) {
            self.running = false;
        }
    }

    /// 碰撞检测：检查给定形状在 (px, py) 位置是否与棋盘边界或已锁定方块重叠。
    /// 参数：
    ///   - shape: 4×4 方块矩阵
    ///   - px: 左上角列坐标
    ///   - py: 左上角行坐标
    /// 返回 true 表示有碰撞。
    fn checkCollision(self: *const Game, shape: [4]u8, px: i16, py: i16) bool {
        for (0..4) |row| {
            for (0..4) |col| {
                // 检查矩阵中该位置是否有方块
                if ((shape[row] >> @intCast(3 - col)) & 1 == 0) continue;

                const bx = px + @as(i16, @intCast(col));
                const by = py + @as(i16, @intCast(row));

                // 左右边界检查
                if (bx < 0 or bx >= BOARD_WIDTH) return true;
                // 底部边界检查
                if (by >= BOARD_HEIGHT) return true;
                // 顶部之上允许（方块可以从上方进入）
                if (by < 0) continue;
                // 与已锁定方块碰撞
                if (self.board[@intCast(by)][@intCast(bx)] != 0) return true;
            }
        }
        return false;
    }

    /// 尝试左移当前方块。成功返回 true。
    fn moveLeft(self: *Game) bool {
        const shape = getShape(self.current_piece, self.current_rotation);
        if (!self.checkCollision(shape, self.current_x - 1, self.current_y)) {
            self.current_x -= 1;
            return true;
        }
        return false;
    }

    /// 尝试右移当前方块。成功返回 true。
    fn moveRight(self: *Game) bool {
        const shape = getShape(self.current_piece, self.current_rotation);
        if (!self.checkCollision(shape, self.current_x + 1, self.current_y)) {
            self.current_x += 1;
            return true;
        }
        return false;
    }

    /// 尝试下移当前方块。成功返回 true，失败 → 锁定方块并生成下一个。
    fn moveDown(self: *Game) bool {
        const shape = getShape(self.current_piece, self.current_rotation);
        if (!self.checkCollision(shape, self.current_x, self.current_y + 1)) {
            self.current_y += 1;
            return true;
        }
        // 无法下移 → 锁定
        self.lockPiece(shape);
        self.clearLines();
        // 下一个方块变成当前方块
        self.current_piece = self.next_piece;
        self.next_piece = self.randomPiece();
        self.spawnPiece();
        return false;
    }

    /// 尝试旋转当前方块（顺时针 90°）。成功返回 true。
    fn rotate(self: *Game) bool {
        const new_rotation: u2 = @intCast((@as(u3, self.current_rotation) + 1) % 4);
        const new_shape = getShape(self.current_piece, new_rotation);

        // 先尝试直接旋转
        if (!self.checkCollision(new_shape, self.current_x, self.current_y)) {
            self.current_rotation = new_rotation;
            return true;
        }

        // 墙踢（Wall Kick）：尝试左右偏移
        // 偏移量：[-1, +1, -2, +2]
        const kicks = [_]i16{ -1, 1, -2, 2 };
        for (kicks) |dx| {
            if (!self.checkCollision(new_shape, self.current_x + dx, self.current_y)) {
                self.current_x += dx;
                self.current_rotation = new_rotation;
                return true;
            }
        }
        return false;
    }

    /// 硬降：方块直接落到底部，然后锁定。
    fn hardDrop(self: *Game) void {
        const shape = getShape(self.current_piece, self.current_rotation);
        // 不断下移直到碰撞
        while (!self.checkCollision(shape, self.current_x, self.current_y + 1)) {
            self.current_y += 1;
        }
        // 锁定方块
        self.lockPiece(shape);
        self.clearLines();
        // 下一个方块
        self.current_piece = self.next_piece;
        self.next_piece = self.randomPiece();
        self.spawnPiece();
    }

    /// 将当前活动方块锁定到棋盘上。
    fn lockPiece(self: *Game, shape: [4]u8) void {
        const color: u8 = @intCast(self.current_piece + 1); // 1~7，0 表示空
        for (0..4) |row| {
            for (0..4) |col| {
                if ((shape[row] >> @intCast(3 - col)) & 1 == 0) continue;

                const bx = self.current_x + @as(i16, @intCast(col));
                const by = self.current_y + @as(i16, @intCast(row));
                // 只锁定在棋盘范围内的部分
                if (bx >= 0 and bx < BOARD_WIDTH and by >= 0 and by < BOARD_HEIGHT) {
                    self.board[@intCast(by)][@intCast(bx)] = color;
                }
            }
        }
    }

    /// 检查并消除所有满行。从上往下扫描，满行消除后上面的行下移。
    fn clearLines(self: *Game) void {
        var cleared: u8 = 0;
        var row: i16 = BOARD_HEIGHT - 1;
        while (row >= 0) {
            if (self.isRowFull(@intCast(row))) {
                // 将该行以上的所有行下移一行
                var r: i16 = row;
                while (r > 0) : (r -= 1) {
                    self.board[@intCast(r)] = self.board[@intCast(r - 1)];
                }
                // 最顶行清空
                @memset(&self.board[0], @as(u8, 0));
                cleared += 1;
                // row 不变，因为上面行下移后需要重新检查当前行
            } else {
                row -= 1;
            }
        }

        if (cleared > 0) {
            // 计分：1行=100, 2行=300, 3行=500, 4行=800
            const points: u32 = switch (cleared) {
                1 => 100,
                2 => 300,
                3 => 500,
                4 => 800,
                else => 0,
            };
            self.score += points;
            self.lines_cleared += cleared;
            // 升级：每 10 行升一级
            self.level = self.lines_cleared / 10;
            // 速度随等级加快：起始 800ms，每级减 50ms，最低 100ms
            self.drop_interval_ms = @max(100, 800 - @as(u32, @intCast(self.level)) * 50);
        }
    }

    /// 检查指定行是否已满（所有格子非空）
    fn isRowFull(self: *const Game, row: u8) bool {
        for (self.board[row]) |cell| {
            if (cell == 0) return false;
        }
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// 渲染器：把游戏状态画成 ANSI escape codes
// ═══════════════════════════════════════════════════════════════════════════════

const Renderer = struct {
    /// 输出目标（标准输出的 Writer 接口）
    writer: *std.Io.Writer,
    /// 帧缓冲区（16KB，足够容纳 10×20 棋盘 + 边框 + 信息面板）
    buf: [16384]u8,

    /// 初始化屏幕：隐藏光标 + 清屏
    fn initScreen(self: *Renderer) !void {
        try self.writer.writeAll("\x1b[?25l\x1b[2J");
    }

    /// 恢复屏幕：显示光标 + 清屏 + 光标归位
    fn restoreScreen(self: *Renderer) !void {
        try self.writer.writeAll("\x1b[?25h\x1b[2J\x1b[H");
    }

    /// 渲染一帧游戏画面。
    ///
    /// 布局：
    ///   ┌──────────┐  ┌────┐
    ///   │ 棋盘区域  │  │预览│
    ///   │ 10×20    │  └────┘
    ///   │          │  得分: xxx
    ///   │          │  等级: x
    ///   │          │  行数: xx
    ///   └──────────┘  操作提示
    fn render(self: *Renderer, game: *const Game) !void {
        var w: std.Io.Writer = .fixed(&self.buf);

        // 光标回左上角
        try w.writeAll("\x1b[H");

        // 获取当前方块形状（用于绘制活动方块）
        const current_shape = getShape(game.current_piece, game.current_rotation);
        const current_color = pieceColor(game.current_piece);

        // 获取预览方块形状
        const next_shape = PIECES[game.next_piece];
        const next_color = pieceColor(game.next_piece);

        // ── 顶部边框 ──
        try w.writeAll("┌");
        for (0..BOARD_WIDTH) |_| try w.writeAll("──");
        try w.writeAll("┐   ┌────┐\r\n");

        // ── 棋盘区域（逐行绘制）──
        for (0..BOARD_HEIGHT) |row| {
            try w.writeAll("│"); // 左边框

            for (0..BOARD_WIDTH) |col| {
                const bx = @as(i16, @intCast(col));
                const by = @as(i16, @intCast(row));

                // 优先级：活动方块 > 已锁定方块 > 空格
                if (isInPiece(current_shape, game.current_x, game.current_y, bx, by)) {
                    try w.writeAll(current_color);
                    try w.writeAll("██");
                    try w.writeAll("\x1b[0m");
                } else if (game.board[row][col] != 0) {
                    // 已锁定的方块：根据颜色值渲染
                    const color_idx: u3 = @intCast(game.board[row][col] - 1);
                    try w.writeAll(PIECE_COLORS[color_idx]);
                    try w.writeAll("██");
                    try w.writeAll("\x1b[0m");
                } else {
                    // 空格：用暗色点填充
                    try w.writeAll("\x1b[90m··\x1b[0m");
                }
            }

            try w.writeAll("│"); // 右边框

            // ── 右侧信息面板（与棋盘行对应）──
            if (row == 0) {
                try w.writeAll("   ┌────┐");
            } else if (row >= 1 and row <= 4) {
                // 显示下一个方块预览（4×4 矩阵）
                const pr = row - 1; // 预览区域的相对行
                try w.writeAll("   │");
                for (0..4) |pc| {
                    if ((next_shape[pr] >> @intCast(3 - pc)) & 1 == 1) {
                        try w.writeAll(next_color);
                        try w.writeAll("██");
                        try w.writeAll("\x1b[0m");
                    } else {
                        try w.writeAll("  ");
                    }
                }
                try w.writeAll("│");
            } else if (row == 5) {
                try w.writeAll("   └────┘");
            } else if (row == 7) {
                try w.writeAll("  得分: ");
                try w.print("{d: >6}", .{game.score});
            } else if (row == 8) {
                try w.writeAll("  等级: ");
                try w.print("{d: >6}", .{game.level});
            } else if (row == 9) {
                try w.writeAll("  行数: ");
                try w.print("{d: >6}", .{game.lines_cleared});
            }

            try w.writeAll("\r\n");
        }

        // ── 底部边框 ──
        try w.writeAll("└");
        for (0..BOARD_WIDTH) |_| try w.writeAll("──");
        try w.writeAll("┘\r\n");

        // ── 状态栏 ──
        if (game.paused) {
            try w.writeAll("  ⏸ 暂停中  ");
        } else {
            try w.writeAll("           ");
        }
        try w.writeAll("←→移动 ↓软降 ↑旋转 空格硬降  Q退出 P暂停\r\n");

        // ── 一次性输出整个帧缓冲区 ──
        const written = std.Io.Writer.buffered(&w);
        try self.writer.writeAll(written);
    }
};

/// 检查坐标 (bx, by) 是否在指定方块形状内。
/// (px, py) 是方块左上角的棋盘坐标。
fn isInPiece(shape: [4]u8, px: i16, py: i16, bx: i16, by: i16) bool {
    const rel_x = bx - px;
    const rel_y = by - py;
    if (rel_x < 0 or rel_x >= 4 or rel_y < 0 or rel_y >= 4) return false;
    const mask = @as(u8, 1) << @intCast(3 - rel_x);
    return (shape[@intCast(rel_y)] & mask) != 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 按键定义
// ═══════════════════════════════════════════════════════════════════════════════

/// 游戏按键语义
const Key = union(enum) {
    move_left, // ←
    move_right, // →
    soft_drop, // ↓
    rotate, // ↑
    hard_drop, // 空格
    quit, // Q
    pause, // P
};

/// 将 input.Key 映射为游戏 Key；返回 null 表示该按键在 Tetris 中无操作。
fn toGameKey(k: input.Key) ?Key {
    return switch (k) {
        .up => .rotate,
        .down => .soft_drop,
        .left => .move_left,
        .right => .move_right,
        .char => |c| switch (c) {
            ' ' => .hard_drop,
            'q', 'Q' => .quit,
            'p', 'P' => .pause,
            else => null,
        },
        .escape, .enter => null,
    };
}

/// 运行俄罗斯方块游戏。
pub fn run(allocator: mem.Allocator, io: std.Io) !void {
    _ = allocator;

    // ── 终端 raw 模式（共享 input 模块） ──
    var term = try input.Terminal.enterRawMode();
    defer term.deinit();

    // ── 标准输出 ──
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout_writer = &stdout_file_writer.interface;

    // ── 渲染器 ──
    var renderer = Renderer{ .writer = stdout_writer, .buf = undefined };
    try renderer.initScreen();
    defer renderer.restoreScreen() catch {};

    // ── 初始化游戏 ──
    const seed: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    var game = Game.init(seed);

    // ═════════════════════════════════════════════════════════════════
    // 主游戏循环
    // ═════════════════════════════════════════════════════════════════
    var last_drop = std.Io.Timestamp.now(io, .awake);

    while (game.running) {
        // ── 输入处理 ──
        while (try term.readKey()) |ik| {
            if (toGameKey(ik)) |key| {
                if (game.paused) {
                    switch (key) {
                        .pause => game.paused = false,
                        .quit => game.running = false,
                        else => {},
                    }
                    continue;
                }

                switch (key) {
                    .move_left => _ = game.moveLeft(),
                    .move_right => _ = game.moveRight(),
                    .soft_drop => _ = game.moveDown(),
                    .rotate => _ = game.rotate(),
                    .hard_drop => game.hardDrop(),
                    .quit => game.running = false,
                    .pause => game.paused = true,
                }
            }
        }

        // ── 自动下落 ──
        if (!game.paused) {
            const now = std.Io.Timestamp.now(io, .awake);
            const elapsed_ms = last_drop.durationTo(now).toMilliseconds();
            if (elapsed_ms >= game.drop_interval_ms) {
                last_drop = now;
                _ = game.moveDown();
            }
        }

        // ── 渲染 ──
        try renderer.render(&game);

        // ── 帧率控制（~60fps）──
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake) catch {};
    }

    // ═════════════════════════════════════════════════════════════════
    // 游戏结束
    // ═════════════════════════════════════════════════════════════════
    try renderer.restoreScreen();
    try stdout_writer.print("\n  🎮 游戏结束!\n", .{});
    try stdout_writer.print("  最终得分: {d}\n", .{game.score});
    try stdout_writer.print("  消除行数: {d}\n", .{game.lines_cleared});
    try stdout_writer.print("  达到等级: {d}\n", .{game.level});
    try stdout_writer.print("\n  按 Q 退出...", .{});
    try stdout_writer.flush();

    // 等待用户按 Q 退出
    while (true) {
        if (try term.readKey()) |ik| {
            if (toGameKey(ik)) |key| {
                if (key == .quit) break;
            }
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════════

test "方块旋转正确" {
    // 测试 T 方块旋转 4 次回到原位
    // T 方块原始形状:
    //   0100
    //   1110
    //   0000
    //   0000
    const t_shape = PIECES[2]; // T 是第 3 个（索引 2）
    const rotated_once = rotatePiece(t_shape);
    const rotated_twice = rotatePiece(rotated_once);
    const rotated_thrice = rotatePiece(rotated_twice);
    const rotated_four = rotatePiece(rotated_thrice);

    // 旋转 4 次应回到原始形状
    try std.testing.expectEqual(t_shape[0], rotated_four[0]);
    try std.testing.expectEqual(t_shape[1], rotated_four[1]);
    try std.testing.expectEqual(t_shape[2], rotated_four[2]);
    try std.testing.expectEqual(t_shape[3], rotated_four[3]);

    // 验证旋转 1 次后的形状：T 顺时针 90°
    // 原始:  0100    旋转1次: 0010
    //        1110             0011
    //        0000             0010
    //        0000             0000
    try std.testing.expectEqual(@as(u8, 0b0010), rotated_once[0]);
    try std.testing.expectEqual(@as(u8, 0b0011), rotated_once[1]);
    try std.testing.expectEqual(@as(u8, 0b0010), rotated_once[2]);
    try std.testing.expectEqual(@as(u8, 0b0000), rotated_once[3]);

    // 测试 O 方块旋转后仍是 2×2 方块（形状不变，但可能在 4×4 网格内偏移）
    const o_shape = PIECES[1]; // O 是第 2 个（索引 1）
    const o_rotated = rotatePiece(o_shape);
    // O 方块旋转后仍有恰好 4 个填充格（2×2）
    var o_count: u8 = 0;
    for (0..4) |r| {
        o_count += @popCount(o_rotated[r]);
    }
    try std.testing.expectEqual(@as(u8, 4), o_count);
}

test "行消除正确" {
    const seed: u64 = 42;
    var game = Game.init(seed);

    // 手动构造一个几乎满行的棋盘
    // 第 19 行（最底行）填满除了最后一格以外的所有格
    for (0..BOARD_WIDTH - 1) |col| {
        game.board[BOARD_HEIGHT - 1][col] = 1; // 用颜色 1（I 方块的颜色）
    }
    // 第 18 行填满
    for (0..BOARD_WIDTH) |col| {
        game.board[BOARD_HEIGHT - 2][col] = 2;
    }
    // 第 17 行填满
    for (0..BOARD_WIDTH) |col| {
        game.board[BOARD_HEIGHT - 3][col] = 3;
    }

    // 验证初始状态：第 18、17 行满，第 19 行不满
    try std.testing.expect(!game.isRowFull(BOARD_HEIGHT - 1)); // 缺一格
    try std.testing.expect(game.isRowFull(BOARD_HEIGHT - 2)); // 满
    try std.testing.expect(game.isRowFull(BOARD_HEIGHT - 3)); // 满

    const old_score = game.score;

    // 手动填充第 19 行最后一格，触发 3 行消除
    game.board[BOARD_HEIGHT - 1][BOARD_WIDTH - 1] = 4;
    try std.testing.expect(game.isRowFull(BOARD_HEIGHT - 1));

    // 执行消除（注意：clearLines 通常在 lockPiece 后调用，
    // 这里直接测试 clearLines 的行为）
    game.clearLines();

    // 消除 3 行应得 500 分
    try std.testing.expectEqual(old_score + 500, game.score);
    // 消除 3 行
    try std.testing.expectEqual(@as(u32, 3), game.lines_cleared);
    // 消除后原第 19 行不再满（已被上方行覆盖或清空）
    // 所有满行都已消除
    for (0..BOARD_HEIGHT) |row| {
        try std.testing.expect(!game.isRowFull(@intCast(row)));
    }
}
