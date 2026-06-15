//! 终端 2048 游戏。
//!
//! 4×4 网格，WASD/方向键滑动，相同数字合并。
//! ANSI escape codes + 帧缓冲区渲染，不同数字不同颜色。
//!
//! 公开入口：`pub fn run(allocator: std.mem.Allocator, io: std.Io) !void`

const std = @import("std");
const mem = std.mem;
const input = @import("../input.zig");

/// 最高分存储文件名
const SCORE_FILE = ".2048_highscore";

// ═══════════════════════════════════════════════════════════════════════════════
// 常量
// ═══════════════════════════════════════════════════════════════════════════════

/// 网格大小（4×4）
const GRID_SIZE = 4;
/// 每个格子的显示宽度（字符数，含两侧空格）
const CELL_W = 6;
/// 帧缓冲区大小（足够容纳整个画面）
const FB_SIZE = 4096;

// ═══════════════════════════════════════════════════════════════════════════════
// 方向枚举
// ═══════════════════════════════════════════════════════════════════════════════
const Direction = enum {
    up,
    down,
    left,
    right,
};

// ═══════════════════════════════════════════════════════════════════════════════
// ANSI 颜色定义
// ═══════════════════════════════════════════════════════════════════════════════
// 使用 24-bit 真彩色（\x1b[38;2;R;G;Bm），现代终端均支持。
// 不同数值对应不同颜色：
//   2白  4黄  8橙  16红  32紫  64蓝  128青  256绿  512深绿  1024粉  2048金
const COLORS = std.StaticStringMap([]const u8).initComptime(.{
    .{ "2", "\x1b[38;2;238;238;238m" }, // 白色
    .{ "4", "\x1b[38;2;237;224;116m" }, // 黄色
    .{ "8", "\x1b[38;2;242;177;121m" }, // 橙色
    .{ "16", "\x1b[38;2;245;96;66m" }, // 红色
    .{ "32", "\x1b[38;2;200;100;255m" }, // 紫色
    .{ "64", "\x1b[38;2;80;120;255m" }, // 蓝色
    .{ "128", "\x1b[38;2;0;200;200m" }, // 青色
    .{ "256", "\x1b[38;2;80;200;80m" }, // 绿色
    .{ "512", "\x1b[38;2;0;150;0m" }, // 深绿
    .{ "1024", "\x1b[38;2;255;100;180m" }, // 粉色
    .{ "2048", "\x1b[38;2;255;200;0m" }, // 金色
});

/// 获取数值对应的 ANSI 颜色转义序列
fn cellColor(value: u16) []const u8 {
    // 将数值转为字符串，在 COLORS 表中查找
    var buf: [6]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "\x1b[37m";
    return COLORS.get(s) orelse "\x1b[38;2;255;215;0m"; // 超 2048 用亮金色
}

/// ANSI 重置
const RESET = "\x1b[0m";

// ═══════════════════════════════════════════════════════════════════════════════
// 按键定义
// ═══════════════════════════════════════════════════════════════════════════════
const Key = union(enum) {
    /// 方向键 / WASD
    direction: Direction,
    /// 退出（Q 键）
    quit,
    /// 确认（Y/回车）
    confirm,
    /// 拒绝/取消（N 键）
    cancel,
};

/// 将共享模块的 `input.Key` 转换为游戏专用 Key。
fn toGameKey(k: input.Key) ?Key {
    return switch (k) {
        .up => Key{ .direction = .up },
        .down => Key{ .direction = .down },
        .left => Key{ .direction = .left },
        .right => Key{ .direction = .right },
        .char => |c| switch (c) {
            'q', 'Q' => Key.quit,
            'y', 'Y' => Key.confirm,
            'n', 'N' => Key.cancel,
            ' ', '\r', '\n' => Key.confirm,
            'w', 'W' => Key{ .direction = .up },
            's', 'S' => Key{ .direction = .down },
            'a', 'A' => Key{ .direction = .left },
            'd', 'D' => Key{ .direction = .right },
            else => null,
        },
        .enter => Key.confirm,
        .escape => Key.cancel,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// 终端抽象已迁移至 ../input.zig
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// 核心游戏逻辑
// ═══════════════════════════════════════════════════════════════════════════════

/// 4×4 网格
const Grid = [GRID_SIZE][GRID_SIZE]u16;

/// 游戏状态
const Game = struct {
    /// 4×4 网格，0 表示空格
    grid: Grid,
    /// 当前分数（合并数字的总和）
    score: u32,
    /// 历史最高分
    high_score: u32,
    /// 是否已经合成过 2048
    won: bool,
    /// 达到 2048 后是否选择继续游戏
    keep_playing: bool,
    /// 是否正在显示胜利提示
    showing_win_prompt: bool,
    /// 游戏是否结束
    over: bool,
    /// 伪随机数生成器
    rng: std.Random.DefaultPrng,

    const Position = struct { row: u8, col: u8 };

    /// 初始化游戏状态。
    /// 在 4×4 空格子中随机放置 2 个初始方块（2 或 4）。
    fn init(seed: u64, high_score: u32) Game {
        var game = Game{
            .grid = .{
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
                .{ 0, 0, 0, 0 },
            },
            .score = 0,
            .high_score = high_score,
            .won = false,
            .keep_playing = false,
            .showing_win_prompt = false,
            .over = false,
            .rng = std.Random.DefaultPrng.init(seed),
        };

        // 初始放置 2 个随机方块
        game.addRandomTile();
        game.addRandomTile();

        return game;
    }

    /// 在随机空格中生成新方块。
    /// 90% 概率生成 2，10% 概率生成 4。
    fn addRandomTile(self: *Game) void {
        const empty = self.emptyCells();
        if (empty.len == 0) return;

        const rand = self.rng.random();
        // 随机选一个空格
        const idx = rand.intRangeLessThan(u8, 0, @intCast(empty.len));
        const pos = empty[idx];

        // 90% 生成 2，10% 生成 4
        const value: u16 = if (rand.intRangeLessThan(u8, 0, 10) == 0) 4 else 2;

        self.grid[pos.row][pos.col] = value;
    }

    /// 获取所有空格的坐标列表。
    fn emptyCells(self: *const Game) []const Game.Position {
        const static = struct {
            var buf: [GRID_SIZE * GRID_SIZE]Game.Position = undefined;
            var len: usize = 0;
        };
        static.len = 0;
        for (self.grid, 0..) |row, r| {
            for (row, 0..) |cell, c| {
                if (cell == 0) {
                    static.buf[static.len] = .{ .row = @intCast(r), .col = @intCast(c) };
                    static.len += 1;
                }
            }
        }
        return static.buf[0..static.len];
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// 滑动合并逻辑
// ═══════════════════════════════════════════════════════════════════════════════

/// 将一行（长度为 GRID_SIZE 的数组）向左滑动并合并。
/// 返回合并后的新行，并通过指针累加分数。
///
/// 算法：
///   1. 压实：去掉所有 0，非零值左对齐
///   2. 合并：从左到右扫描，相邻相等值合并（每个位置最多合并一次）
///   3. 再次压实：去掉合并产生的 0
///
/// 示例：
///   [2,2,2,2] → 压实 [2,2,2,2] → 合并 [4,0,4,0] → 压实 [4,4,0,0]
///   [4,0,2,2] → 压实 [4,2,2,0] → 合并 [4,4,0,0] → 压实 [4,4,0,0]
fn slideRow(row: [GRID_SIZE]u16, add_score: *u32) [GRID_SIZE]u16 {
    // 第一步：压实（去掉 0）
    var compacted: [GRID_SIZE]u16 = .{ 0, 0, 0, 0 };
    var pos: u3 = 0;
    for (row) |v| {
        if (v != 0) {
            compacted[pos] = v;
            pos += 1;
        }
    }

    // 第二步：合并相邻相等值
    for (0..GRID_SIZE - 1) |i| {
        if (compacted[i] != 0 and compacted[i] == compacted[i + 1]) {
            compacted[i] *= 2;
            add_score.* += compacted[i];
            compacted[i + 1] = 0;
        }
    }

    // 第三步：再次压实（去掉合并产生的 0）
    var result: [GRID_SIZE]u16 = .{ 0, 0, 0, 0 };
    pos = 0;
    for (compacted) |v| {
        if (v != 0) {
            result[pos] = v;
            pos += 1;
        }
    }

    return result;
}

/// 测试用：比较两个网格是否相等
fn gridEqual(a: Grid, b: Grid) bool {
    for (a, 0..) |row_a, r| {
        for (row_a, 0..) |cell_a, c| {
            if (cell_a != b[r][c]) return false;
        }
    }
    return true;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 移动逻辑
// ═══════════════════════════════════════════════════════════════════════════════

/// 对整个网格执行一次滑动。
/// 返回 true 表示网格发生了变化（有方块移动或合并），并累加分数。
///
/// 移动方向处理：
///   - Left:  每行原样 → slideRow → 写回
///   - Right: 每行反转 → slideRow → 反转 → 写回
///   - Up:    每列自上而下提取 → slideRow → 写回
///   - Down:  每列自下而上提取 → slideRow → 写回
fn moveGrid(grid: *Grid, direction: Direction, add_score: *u32) bool {
    const size = GRID_SIZE;
    var changed = false;

    switch (direction) {
        .left => {
            for (0..size) |r| {
                const old_row = grid[r];
                const new_row = slideRow(old_row, add_score);
                if (!mem.eql(u16, &old_row, &new_row)) {
                    changed = true;
                    grid[r] = new_row;
                }
            }
        },
        .right => {
            for (0..size) |r| {
                // 提取行并反转
                var row: [size]u16 = undefined;
                for (0..size) |c| {
                    row[size - 1 - c] = grid[r][c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (!mem.eql(u16, &old_row, &new_row)) {
                    changed = true;
                    // 反转写回
                    for (0..size) |c| {
                        grid[r][size - 1 - c] = new_row[c];
                    }
                }
            }
        },
        .up => {
            for (0..size) |c| {
                // 提取列（自上而下）
                var row: [size]u16 = undefined;
                for (0..size) |r| {
                    row[r] = grid[r][c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (!mem.eql(u16, &old_row, &new_row)) {
                    changed = true;
                    for (0..size) |r| {
                        grid[r][c] = new_row[r];
                    }
                }
            }
        },
        .down => {
            for (0..size) |c| {
                // 提取列（自下而上，即反转）
                var row: [size]u16 = undefined;
                for (0..size) |r| {
                    row[size - 1 - r] = grid[r][c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (!mem.eql(u16, &old_row, &new_row)) {
                    changed = true;
                    // 反转写回
                    for (0..size) |r| {
                        grid[size - 1 - r][c] = new_row[r];
                    }
                }
            }
        },
    }

    return changed;
}

/// 检测是否还有可用的移动（任意方向滑动是否能让网格变化）。
/// 用于判断游戏是否结束。
fn canMove(grid: *const Grid) bool {
    const size = GRID_SIZE;

    // 检查是否有空格（空格意味着总能移动）
    for (0..size) |r| {
        for (0..size) |c| {
            if (grid[r][c] == 0) return true;
        }
    }

    // 没有空格时，检查相邻格子是否有相同值（水平方向）
    for (0..size) |r| {
        for (0..size - 1) |c| {
            if (grid[r][c] == grid[r][c + 1]) return true;
        }
    }

    // 检查相邻格子是否有相同值（垂直方向）
    for (0..size - 1) |r| {
        for (0..size) |c| {
            if (grid[r][c] == grid[r + 1][c]) return true;
        }
    }

    return false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 渲染器
// ═══════════════════════════════════════════════════════════════════════════════
const Renderer = struct {
    /// 输出目标（标准输出的 Writer 接口）
    writer: *std.Io.Writer,
    /// 帧缓冲区
    buf: [FB_SIZE]u8,

    /// 初始化屏幕：隐藏光标 + 清屏
    fn initScreen(self: *Renderer) !void {
        try self.writer.writeAll("\x1b[?25l\x1b[2J");
    }

    /// 恢复屏幕：显示光标 + 清屏
    fn restoreScreen(self: *Renderer) !void {
        try self.writer.writeAll("\x1b[?25h\x1b[2J\x1b[H");
    }

    /// 在帧缓冲区中写入一个格子的内容（含颜色和居中对齐）。
    fn writeCell(w: *std.Io.Writer, value: u16) !void {
        if (value == 0) {
            // 空格子：6 个空格
            try w.writeAll("      ");
            return;
        }

        // 格式化数字
        var num_buf: [6]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{value});

        // 计算居中需要的左右空格数
        const cell_w = CELL_W;
        const num_w = num_str.len;
        const left_pad = (cell_w - num_w) / 2;
        const right_pad = cell_w - num_w - left_pad;

        // 写入颜色代码
        try w.writeAll(cellColor(value));

        // 写入左填充
        var i: usize = 0;
        while (i < left_pad) : (i += 1) {
            try w.writeByte(' ');
        }

        // 写入数字
        try w.writeAll(num_str);

        // 写入右填充
        i = 0;
        while (i < right_pad) : (i += 1) {
            try w.writeByte(' ');
        }

        // 重置颜色
        try w.writeAll(RESET);
    }

    /// 渲染水平分隔线：├──────┼──────┼──────┼──────┤
    fn writeHLine(w: *std.Io.Writer, left: []const u8, mid: []const u8, right: []const u8) !void {
        try w.writeAll(left);
        for (0..GRID_SIZE) |i| {
            if (i > 0) try w.writeAll(mid);
            var j: usize = 0;
            while (j < CELL_W) : (j += 1) {
                try w.writeAll("─");
            }
        }
        try w.writeAll(right);
        try w.writeAll("\r\n");
    }

    /// 渲染完整一帧。
    fn render(self: *Renderer, game: *const Game) !void {
        // 创建写入帧缓冲区的 Writer
        var w: std.Io.Writer = .fixed(&self.buf);

        // 光标回左上角（重绘整个画面）
        try w.writeAll("\x1b[H");

        // ── 标题 ──
        try w.writeAll("  ╔════ 2048 ════╗\r\n");

        // ── 顶部边框 ──
        try writeHLine(&w, "  ┌", "┬", "┐");

        // ── 游戏网格 ──
        for (game.grid, 0..) |row, r| {
            // 行分隔线（非首行）
            if (r > 0) {
                try writeHLine(&w, "  ├", "┼", "┤");
            }

            // 行内容
            try w.writeAll("  │");
            for (row, 0..) |cell, c| {
                if (c > 0) try w.writeAll("│");
                try writeCell(&w, cell);
            }
            try w.writeAll("│\r\n");
        }

        // ── 底部边框 ──
        try writeHLine(&w, "  └", "┴", "┘");

        // ── 状态信息 ──
        try w.print("  分数: {d}    最高分: {d}\r\n", .{ game.score, game.high_score });

        // ── 提示信息（根据当前状态显示不同内容）──
        if (game.showing_win_prompt) {
            try w.print("  🎉 达到 2048!  继续游戏? (Y/N)\r\n", .{});
        } else if (game.over) {
            try w.print("  💀 游戏结束!  按 Q 退出\r\n", .{});
        } else {
            try w.print("  WASD/方向键移动 | Q 退出\r\n", .{});
        }

        // 一次性输出帧缓冲区的所有内容
        const written = std.Io.Writer.buffered(&w);
        try self.writer.writeAll(written);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// 最高分文件 I/O
// ═══════════════════════════════════════════════════════════════════════════════

/// 从 .2048_highscore 文件读取历史最高分。
/// 文件不存在或格式错误时返回 0。
fn loadHighScore(allocator: mem.Allocator, io: std.Io) u32 {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, SCORE_FILE, allocator, .limited(32)) catch return 0;
    defer allocator.free(contents);

    const trimmed = mem.trimEnd(u8, contents, &std.ascii.whitespace);
    return std.fmt.parseUnsigned(u32, trimmed, 10) catch 0;
}

/// 将最高分写入 .2048_highscore 文件。
fn saveHighScore(io: std.Io, score: u32) !void {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{score});

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, SCORE_FILE, .{});
    defer file.close(io);

    var file_buf: [64]u8 = undefined;
    var fw = file.writer(io, &file_buf);
    try fw.interface.writeAll(text);
    try fw.flush();
}

// ═══════════════════════════════════════════════════════════════════════════════
// 公开入口
// ═══════════════════════════════════════════════════════════════════════════════

/// 运行 2048 游戏。
///
/// 参数：
///   - allocator: 内存分配器（用于读取最高分文件）
///   - io: 当前线程的 Io 实例
pub fn run(allocator: mem.Allocator, io: std.Io) !void {
    // ── 加载历史最高分 ──
    const high_score = loadHighScore(allocator, io);

    // ── 终端 raw 模式 ──
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
    // 用当前时间戳（纳秒）作为随机种子
    const seed: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    var game = Game.init(seed, high_score);

    // ── 主游戏循环 ──
    while (true) {
        // 渲染当前画面
        try renderer.render(&game);

        // 读取输入（非阻塞）
        const raw = (try term.readKey()) orelse {
            // 无输入时休眠 16ms（约 60fps），避免 CPU 空转
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake) catch {};
            continue;
        };

        // ── 处理胜利提示状态 ──
        const key = toGameKey(raw);
        if (game.showing_win_prompt) {
            if (key) |k| {
                switch (k) {
                    .confirm => {
                        // 继续游戏
                        game.showing_win_prompt = false;
                        game.keep_playing = true;
                        game.won = true;
                    },
                    .cancel, .quit => {
                        game.over = true;
                    },
                    else => {},
                }
            }
            if (game.over) break;
            continue;
        }

        // ── 处理游戏结束状态 ──
        if (game.over) {
            if (key) |k| {
                if (k == .quit or k == .confirm) break;
            }
            continue;
        }

        // ── 正常游戏状态 ──
        if (key) |k|
            switch (k) {
                .direction => |dir| {
                    var add_score: u32 = 0;
                    const changed = moveGrid(&game.grid, dir, &add_score);

                    if (changed) {
                        game.score += add_score;

                        // 检查是否达到 2048（且尚未胜利过）
                        if (!game.won and !game.keep_playing) {
                            outer: for (game.grid) |row| {
                                for (row) |cell| {
                                    if (cell >= 2048) {
                                        game.showing_win_prompt = true;
                                        break :outer;
                                    }
                                }
                            }
                        }

                        // 生成新方块
                        if (!game.showing_win_prompt) {
                            game.addRandomTile();
                        }
                    }

                    // 检查游戏是否无法继续
                    if (!canMove(&game.grid) and !game.showing_win_prompt) {
                        game.over = true;
                    }
                },
                .quit => {
                    game.over = true;
                    break;
                },
                else => {},
            }
        else
            continue;
    }

    // ════════════════════════════════════════════════════════════════════════════
    // 游戏结束
    // ═══════════════════════════════════════════════════════════════════════════

    // 如果破了纪录，保存到文件
    if (game.score > game.high_score) {
        saveHighScore(io, game.score) catch {};
    }

    // 更新最高分用于显示
    const final_high = @max(game.score, game.high_score);

    // 显示结束画面
    try renderer.restoreScreen();
    try stdout_writer.print("\n  🎮 2048 游戏结束!\n", .{});
    try stdout_writer.print("  得分: {d}    最高分: {d}\n", .{ game.score, final_high });
    if (game.won) {
        try stdout_writer.print("  🎉 恭喜达到 2048!\n", .{});
    }
    if (game.score > game.high_score and game.score > 0) {
        try stdout_writer.print("  🏆 新纪录!\n", .{});
    }
    try stdout_writer.print("\n  按 Enter 退出...", .{});
    try stdout_writer.flush();

    // 等待用户按 Enter 或 Q 退出
    while (true) {
        const raw = try term.readKey();
        if (raw) |k| {
            const gk = toGameKey(k);
            if (gk) |g| {
                if (g == .confirm or g == .quit) break;
            }
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════════

test "2048: 合并逻辑正确" {
    // 测试 slideRow 的各种输入

    // 测试 1：两个相同数字合并
    {
        var score: u32 = 0;
        const result = slideRow(.{ 2, 2, 0, 0 }, &score);
        try std.testing.expectEqual(@as(u32, 4), score);
        try std.testing.expectEqualSlices(u16, &.{ 4, 0, 0, 0 }, &result);
    }

    // 测试 2：两对合并
    {
        var score: u32 = 0;
        const result = slideRow(.{ 2, 2, 4, 4 }, &score);
        try std.testing.expectEqual(@as(u32, 12), score); // 2+2=4, 4+4=8, total=12
        try std.testing.expectEqualSlices(u16, &.{ 4, 8, 0, 0 }, &result);
    }

    // 测试 3：三个相同数字（前两个合并，第三个不参与）
    {
        var score: u32 = 0;
        const result = slideRow(.{ 2, 2, 2, 0 }, &score);
        try std.testing.expectEqual(@as(u32, 4), score);
        try std.testing.expectEqualSlices(u16, &.{ 4, 2, 0, 0 }, &result);
    }

    // 测试 4：四个相同数字（两两合并）
    {
        var score: u32 = 0;
        const result = slideRow(.{ 2, 2, 2, 2 }, &score);
        try std.testing.expectEqual(@as(u32, 8), score); // 2+2=4, 2+2=4, total=8
        try std.testing.expectEqualSlices(u16, &.{ 4, 4, 0, 0 }, &result);
    }

    // 测试 5：中间有空格
    {
        var score: u32 = 0;
        const result = slideRow(.{ 4, 0, 0, 4 }, &score);
        try std.testing.expectEqual(@as(u32, 8), score);
        try std.testing.expectEqualSlices(u16, &.{ 8, 0, 0, 0 }, &result);
    }

    // 测试 6：没有可合并的
    {
        var score: u32 = 0;
        const result = slideRow(.{ 2, 4, 8, 16 }, &score);
        try std.testing.expectEqual(@as(u32, 0), score);
        try std.testing.expectEqualSlices(u16, &.{ 2, 4, 8, 16 }, &result);
    }

    // 测试 7：全零
    {
        var score: u32 = 0;
        const result = slideRow(.{ 0, 0, 0, 0 }, &score);
        try std.testing.expectEqual(@as(u32, 0), score);
        try std.testing.expectEqualSlices(u16, &.{ 0, 0, 0, 0 }, &result);
    }

    // 测试 8：2,0,2,4（两个2应该合并，4移动但不合并）
    {
        var score: u32 = 0;
        const result = slideRow(.{ 2, 0, 2, 4 }, &score);
        try std.testing.expectEqual(@as(u32, 4), score);
        try std.testing.expectEqualSlices(u16, &.{ 4, 4, 0, 0 }, &result);
    }
}

test "2048: 移动逻辑正确" {
    // 测试 moveGrid 在各个方向上的正确性

    // 测试向左移动
    {
        var grid: Grid = .{
            .{ 0, 2, 0, 2 },
            .{ 4, 4, 0, 0 },
            .{ 2, 2, 2, 2 },
            .{ 0, 0, 0, 0 },
        };
        var score: u32 = 0;
        const changed = moveGrid(&grid, .left, &score);

        try std.testing.expect(changed);
        // Row0: 0,2,0,2 → compact [2,2] → merge [4,0] → result [4,0,0,0], score+=4
        // Row1: 4,4,0,0 → compact [4,4] → merge [8,0] → result [8,0,0,0], score+=8
        // Row2: 2,2,2,2 → compact [2,2,2,2] → merge [4,0,4,0] → result [4,4,0,0], score+=4+4=8
        // Total: 4+8+8=20
        try std.testing.expectEqual(@as(u32, 20), score);

        const expected: Grid = .{
            .{ 4, 0, 0, 0 },
            .{ 8, 0, 0, 0 },
            .{ 4, 4, 0, 0 },
            .{ 0, 0, 0, 0 },
        };
        try std.testing.expect(gridEqual(grid, expected));
    }

    // 测试向右移动
    {
        var grid: Grid = .{
            .{ 2, 0, 0, 0 },
            .{ 0, 0, 0, 2 },
            .{ 2, 2, 0, 0 },
            .{ 0, 0, 2, 2 },
        };
        var score: u32 = 0;
        const changed = moveGrid(&grid, .right, &score);

        try std.testing.expect(changed);
        try std.testing.expectEqual(@as(u32, 8), score); // row2: 2+2=4, row3: 2+2=4

        const expected: Grid = .{
            .{ 0, 0, 0, 2 },
            .{ 0, 0, 0, 2 },
            .{ 0, 0, 0, 4 },
            .{ 0, 0, 0, 4 },
        };
        try std.testing.expect(gridEqual(grid, expected));
    }

    // 测试向上移动
    {
        var grid: Grid = .{
            .{ 2, 0, 0, 0 },
            .{ 2, 0, 0, 0 },
            .{ 0, 4, 0, 0 },
            .{ 0, 4, 0, 0 },
        };
        var score: u32 = 0;
        const changed = moveGrid(&grid, .up, &score);

        try std.testing.expect(changed);
        try std.testing.expectEqual(@as(u32, 12), score); // col0: 2+2=4, col1: 4+4=8

        const expected: Grid = .{
            .{ 4, 8, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
        };
        try std.testing.expect(gridEqual(grid, expected));
    }

    // 测试向下移动
    {
        var grid: Grid = .{
            .{ 2, 0, 0, 4 },
            .{ 0, 0, 0, 4 },
            .{ 2, 8, 8, 0 },
            .{ 0, 8, 0, 0 },
        };
        var score: u32 = 0;
        const changed = moveGrid(&grid, .down, &score);

        try std.testing.expect(changed);
        // col0 bottom-up: [0,2,0,2] → slide → [4,0,0,0] → write [0,0,0,4], score+=4
        // col1 bottom-up: [8,8,0,0] → slide → [16,0,0,0] → write [0,0,0,16], score+=16
        // col2 bottom-up: [0,8,0,0] → slide → [8,0,0,0] → write [0,0,0,8], score+=0
        // col3 bottom-up: [0,0,4,4] → slide → [8,0,0,0] → write [0,0,0,8], score+=8
        // Total: 4+16+8=28
        try std.testing.expectEqual(@as(u32, 28), score);

        const expected: Grid = .{
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 4, 16, 8, 8 },
        };
        try std.testing.expect(gridEqual(grid, expected));
    }

    // 测试无变化（不能移动的情况）
    {
        var grid: Grid = .{
            .{ 2, 4, 8, 16 },
            .{ 16, 8, 4, 2 },
            .{ 2, 4, 8, 16 },
            .{ 16, 8, 4, 2 },
        };
        var score: u32 = 0;
        const changed = moveGrid(&grid, .left, &score);

        try std.testing.expect(!changed);
        try std.testing.expectEqual(@as(u32, 0), score);
        // 网格不应变化
        const expected: Grid = .{
            .{ 2, 4, 8, 16 },
            .{ 16, 8, 4, 2 },
            .{ 2, 4, 8, 16 },
            .{ 16, 8, 4, 2 },
        };
        try std.testing.expect(gridEqual(grid, expected));
    }
}
