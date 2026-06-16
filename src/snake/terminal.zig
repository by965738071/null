//! 终端贪吃蛇 —— 用 ANSI escape codes 手写的经典游戏。
//!
//! ## 架构概览
//!
//! 整个文件分为以下几个逻辑块：
//!   1. 平台抽象层（win 结构体、PosixTerminal、WindowsTerminal）
//!   2. 游戏状态（Game 结构体：蛇、食物、道具、障碍物）
//!   3. 渲染器（Renderer：用 ANSI escape codes 画画面）
//!   4. 输入处理（Terminal：非阻塞读取按键）
//!   5. 持久化（loadHighScore / saveHighScore：最高分文件读写）
//!   6. 主循环（run 函数：把所有东西串起来）
//!
//! ## 操作
//!   - 方向键 / WASD：控制移动
//!   - R：切换穿墙模式
//!   - Q / Ctrl+C：退出
//!   - P：暂停/继续
//!
//! ## 特性
//!   - 🏆 最高分记录（存到 .snake_highscore 文件）
//!   - 🔄 穿墙模式（按 R 切换，蛇从一边出去、另一边进来）
//!   - ⚡ 加速道具（金色 ★，吃到后 30 步内双倍分 + 移速翻倍）
//!   - 🧱 随机障碍物（每局 5 个灰色方块，撞到即死）
//!   - 🎨 彩虹渐变蛇身（每节不同颜色：红→黄→绿→青→蓝→紫循环）
//!   - 🪟 跨平台（macOS/Linux 用 POSIX termios，Windows 用 Win32 Console API）

const std = @import("std");
const mem = std.mem;
const input = @import("../input.zig");

/// 最高分存储的文件名。放在当前工作目录下。
const SCORE_FILE = ".snake_highscore";

// ═══════════════════════════════════════════════════════════════════════════════
// 游戏状态
// ═══════════════════════════════════════════════════════════════════════════════
//
// Game 是整个游戏的核心数据结构。所有游戏逻辑都在这个结构体的方法里。
// Zig 中 struct 的方法就是把 self 指针作为第一个参数的普通函数，
// 调用时 game.step(allocator) 等价于 Game.step(&game, allocator)。

const Game = struct {
    // ── 内存管理 ──
    /// 分配器，蛇身和障碍物列表都在这个分配器上分配。
    allocator: mem.Allocator,

    // ── 地图 ──
    /// 游戏区域宽度（包含左右边框，内部可用 = width - 2）
    width: u16,
    /// 游戏区域高度（包含上下边框，内部可用 = height - 2）
    height: u16,

    // ── 蛇 ──
    /// 蛇的身体 + 身体各节坐标列表
    snake: Snake,
    /// 当前移动方向
    direction: Direction,
    /// 下一帧的方向（缓冲一帧，防止同一帧内连续反向导致蛇撞自己）
    next_direction: Direction,

    // ── 物品 ──
    /// 普通食物位置（红色 ●）
    food: Position,
    /// 加速道具位置（金色 ★），null 表示当前没有道具
    boost: ?Position,

    // ── 分数 ──
    /// 当前得分
    score: u32,
    /// 历史最高分（启动时从文件读取）
    high_score: u32,

    // ── 状态标志 ──
    /// 游戏是否正在运行（false = 游戏结束）
    running: bool,
    /// 是否暂停
    paused: bool,
    /// 是否开启穿墙模式
    wrap_mode: bool,

    // ── 速度控制 ──
    /// 当前每步间隔（毫秒），越小越快。初始 120ms，每吃一个食物减 2ms
    speed_ms: u32,
    /// 基础速度（加速道具过期后恢复到这个值）
    base_speed_ms: u32,
    /// 加速剩余步数（0 表示未加速），吃到道具设为 30
    boost_remaining: u32,
    /// 道具重生冷却计时（步数），防止道具连续出现
    boost_cooldown: u32,
    /// 道具冷却的最大步数
    boost_cooldown_max: u32,

    // ── 障碍物 ──
    /// 障碍物列表（灰色 ▓ 方块，撞到即死）
    obstacles: std.ArrayList(Position),

    // ── 随机数 ──
    /// 随机数生成器（用于生成食物、道具、障碍物位置）
    rng: std.Random.DefaultPrng,

    // ── 嵌套类型 ──

    /// 二维坐标（x 从左到右，y 从上到下）
    const Position = struct {
        x: u16,
        y: u16,
    };

    /// 移动方向
    const Direction = enum {
        up,
        down,
        left,
        right,

        /// 返回反方向。用于防止蛇掉头（按上和下不能同时生效）
        fn opposite(self: Direction) Direction {
            return switch (self) {
                .up => .down,
                .down => .up,
                .left => .right,
                .right => .left,
            };
        }
    };

    /// 蛇 = 身体各节坐标的动态数组。body[0] 是蛇头，最后一个元素是蛇尾。
    const Snake = struct {
        body: std.ArrayList(Position),
    };

    // ── 方法 ──

    /// 创建新游戏。
    ///
    /// 参数：
    ///   - allocator: 内存分配器
    ///   - width, height: 游戏区域大小
    ///   - seed: 随机种子（用当前时间戳）
    ///   - high_score: 历史最高分（从文件读取，没有则为 0）
    ///
    /// 返回：初始化的游戏状态（蛇在中间，朝右，3 节长）
    pub fn init(allocator: mem.Allocator, width: u16, height: u16, seed: u64, high_score: u32) !Game {
        // 蛇从地图中心开始，初始 3 节，朝右
        const start_x = width / 2;
        const start_y = height / 2;

        // 预分配 200 容量的蛇身列表（足够长了）
        var body = try std.ArrayList(Position).initCapacity(allocator, 200);
        try body.append(allocator, .{ .x = start_x, .y = start_y }); // 蛇头
        try body.append(allocator, .{ .x = start_x - 1, .y = start_y }); // 第 2 节
        try body.append(allocator, .{ .x = start_x - 2, .y = start_y }); // 第 3 节

        // 障碍物列表（预分配 10 容量，实际只放 5 个）
        const obstacles = try std.ArrayList(Position).initCapacity(allocator, 10);

        var game = Game{
            .allocator = allocator,
            .width = width,
            .height = height,
            .snake = .{ .body = body },
            .food = .{ .x = 5, .y = 5 },
            .boost = null,
            .direction = .right,
            .next_direction = .right,
            .score = 0,
            .high_score = high_score,
            .running = true,
            .paused = false,
            .speed_ms = 120,
            .base_speed_ms = 120,
            .boost_remaining = 0,
            .wrap_mode = false,
            .obstacles = obstacles,
            .rng = std.Random.DefaultPrng.init(seed),
            .boost_cooldown = 0,
            .boost_cooldown_max = 40, // 道具消失后 40 步才可能重新出现
        };

        // 初始化完成后生成障碍物（需要避开蛇的出生点）
        try game.spawnObstacles();

        return game;
    }

    /// 释放游戏占用的内存。
    pub fn deinit(self: *Game) void {
        self.snake.body.deinit(self.allocator);
        self.obstacles.deinit(self.allocator);
    }

    /// 在地图上随机放置障碍物。
    ///
    /// 生成规则：
    ///   - 共 5 个障碍物
    ///   - 不能放在蛇出生点附近（3 格范围内）
    ///   - 不能重叠
    ///   - 最多尝试 200 次（防止地图太小放不下）
    fn spawnObstacles(self: *Game) !void {
        const rand = self.rng.random();
        const obstacle_count: u16 = 5;

        var attempts: u16 = 0;
        while (self.obstacles.items.len < obstacle_count and attempts < 200) : (attempts += 1) {
            const x = rand.uintAtMost(u16, self.width - 4) + 2;
            const y = rand.uintAtMost(u16, self.height - 4) + 2;

            if (isNearSnakeStart(self, x, y)) continue;
            if (isObstacleAt(self, x, y)) continue;

            try self.obstacles.append(self.allocator, .{ .x = x, .y = y });
        }
    }

    /// 在地图上随机放置食物。
    /// 确保不放在蛇身或障碍物上。
    fn spawnFood(self: *Game) void {
        const rand = self.rng.random();
        while (true) {
            const x = rand.intRangeLessThan(u16, 1, self.width - 1);
            const y = rand.intRangeLessThan(u16, 1, self.height - 1);
            if (!isOccupied(self, x, y)) { // 找个空位
                self.food = .{ .x = x, .y = y };
                break;
            }
        }
    }

    /// 在地图上随机放置加速道具。
    /// 确保不放在蛇身、障碍物或食物上。最多尝试 100 次。
    fn spawnBoost(self: *Game) void {
        const rand = self.rng.random();
        var attempts: u16 = 0;
        while (attempts < 100) : (attempts += 1) {
            const x = rand.intRangeLessThan(u16, 1, self.width - 1);
            const y = rand.intRangeLessThan(u16, 1, self.height - 1);
            // 不能和食物重叠，不能和蛇身/障碍物重叠
            if (!isOccupied(self, x, y) and !(x == self.food.x and y == self.food.y)) {
                self.boost = .{ .x = x, .y = y };
                return;
            }
        }
        self.boost = null; // 实在找不到位置就不放了
    }

    /// 游戏核心逻辑：每帧推进一格。
    ///
    /// 执行顺序：
    ///   1. 更新方向（应用缓冲的 next_direction）
    ///   2. 计算新蛇头位置
    ///   3. 碰撞检测（墙 / 障碍物 / 自己）
    ///   4. 插入新蛇头
    ///   5. 检查是否吃到东西（食物 → 增长；道具 → 加速）
    ///   6. 没吃到 → 移除蛇尾（保持长度不变）
    ///   7. 更新加速状态和道具冷却
    fn step(self: *Game) !void {
        if (self.paused) return; // 暂停时不更新

        // 应用缓冲的方向
        self.direction = self.next_direction;

        // ── 1. 计算新蛇头位置 ──
        const head = self.snake.body.items[0]; // body[0] 永远是蛇头
        var new_head = head;
        switch (self.direction) {
            .up => new_head.y -= 1,
            .down => new_head.y += 1,
            .left => new_head.x -= 1,
            .right => new_head.x += 1,
        }

        // ── 2. 碰撞检测 ──

        // 穿墙模式：从一边出去，另一边进来
        if (self.wrap_mode) {
            // 注意：边框在坐标 0 和 width-1，内部区域是 1..width-1
            if (new_head.x == 0) new_head.x = self.width - 2;
            if (new_head.x >= self.width - 1) new_head.x = 1;
            if (new_head.y == 0) new_head.y = self.height - 2;
            if (new_head.y >= self.height - 1) new_head.y = 1;
        } else {
            // 普通模式：撞墙 → 游戏结束
            if (new_head.x == 0 or new_head.x >= self.width -| 1 or
                new_head.y == 0 or new_head.y >= self.height -| 1)
            {
                self.running = false;
                return;
            }
        }

        // 撞障碍物 → 游戏结束
        if (isObstacleAt(self, new_head.x, new_head.y)) {
            self.running = false;
            return;
        }

        // 撞自己 → 游戏结束
        // 注意：只检查前 len-1 节（因为最后一节尾巴在这一帧会移走）
        for (self.snake.body.items[0 .. self.snake.body.items.len - 1]) |seg| {
            if (seg.x == new_head.x and seg.y == new_head.y) {
                self.running = false;
                return;
            }
        }

        // ── 3. 移动蛇 ──
        // insert(0, ...) 把新蛇头插入到列表开头，O(n) 但因为蛇不长所以没问题
        try self.snake.body.insert(self.allocator, 0, new_head);

        // ── 4. 吃食物判定 ──
        if (new_head.x == self.food.x and new_head.y == self.food.y) {
            // 加速期间分数翻倍
            const points: u32 = if (self.boost_remaining > 0) 20 else 10;
            self.score += points;
            // 每吃一个食物，速度稍微加快（下限 40ms）
            if (self.speed_ms > 40) self.speed_ms -= 2;
            self.base_speed_ms = self.speed_ms;
            self.spawnFood(); // 生成新食物
            // 注意：吃到食物时不 pop 蛇尾 → 蛇变长一格
        } else {
            _ = self.snake.body.pop(); // 没吃到 → 去掉蛇尾，长度不变
        }

        // ── 5. 吃加速道具判定 ──
        if (self.boost) |b| { // if let Some(b) = self.boost
            if (new_head.x == b.x and new_head.y == b.y) {
                self.boost = null; // 道具消失
                self.boost_remaining = 30; // 30 步加速
                self.speed_ms = @max(30, self.speed_ms / 2); // 速度翻倍，下限 30ms
                self.boost_cooldown = self.boost_cooldown_max; // 开始冷却
            }
        }

        // ── 6. 加速倒计时 ──
        if (self.boost_remaining > 0) {
            self.boost_remaining -= 1;
            if (self.boost_remaining == 0) {
                // 加速过期，恢复原速
                self.speed_ms = self.base_speed_ms;
            }
        }

        // ── 7. 道具重生冷却 ──
        // 只有当前没有道具、且不在加速中时才计时
        if (self.boost == null and self.boost_remaining == 0) {
            if (self.boost_cooldown > 0) {
                self.boost_cooldown -= 1;
                if (self.boost_cooldown == 0) {
                    self.spawnBoost(); // 冷却完毕，生成新道具
                }
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// 辅助函数：位置判定
// ═══════════════════════════════════════════════════════════════════════════════

/// 检查 (x, y) 是否被蛇身或障碍物占用。
fn isOccupied(game: *const Game, x: u16, y: u16) bool {
    for (game.snake.body.items) |seg| {
        if (seg.x == x and seg.y == y) return true;
    }
    return isObstacleAt(game, x, y);
}

/// 检查 (x, y) 是否有障碍物。
fn isObstacleAt(game: *const Game, x: u16, y: u16) bool {
    for (game.obstacles.items) |obs| {
        if (obs.x == x and obs.y == y) return true;
    }
    return false;
}

/// 检查 (x, y) 是否在蛇出生点 3 格范围内。
/// 用于障碍物生成时避开初始位置。
fn isNearSnakeStart(game: *const Game, x: u16, y: u16) bool {
    const sx = game.width / 2;
    const sy = game.height / 2;
    // 手动计算绝对值（避免浮点）
    const dx = if (x > sx) x - sx else sx - x;
    const dy = if (y > sy) y - sy else sy - y;
    return dx <= 3 and dy <= 3;
}

/// 根据蛇身节的索引返回 ANSI 颜色转义码。
/// 6 种颜色循环：红→黄→绿→青→蓝→紫
fn rainbowColor(index: usize) []const u8 {
    return switch (index % 6) {
        0 => "\x1b[31m", // 红
        1 => "\x1b[33m", // 黄
        2 => "\x1b[32m", // 绿
        3 => "\x1b[36m", // 青
        4 => "\x1b[34m", // 蓝
        5 => "\x1b[35m", // 紫
        else => "\x1b[37m", // 白（不应到达）
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// 渲染器：把游戏状态画成 ANSI escape codes 输出到终端
// ═══════════════════════════════════════════════════════════════════════════════
//
// 渲染流程：
//   1. 把整个画面拼接成一个字符串（写入固定缓冲区 buf）
//   2. 一次性 writeAll 输出到终端
//
// 用固定缓冲区而不是逐字符输出，是为了减少系统调用次数，提升性能。
//
// ANSI escape codes 速查：
//   \x1b[H        — 光标移到左上角
//   \x1b[?25l     — 隐藏光标
//   \x1b[?25h     — 显示光标
//   \x1b[2J       — 清屏
//   \x1b[31m      — 红色前景
//   \x1b[0m       — 重置颜色
//   \r\n          — Windows 换行（\r 回到行首，\n 换行）

const Renderer = struct {
    /// 输出目标（标准输出的 Writer 接口）
    writer: *std.Io.Writer,
    /// 帧缓冲区（8KB 足够 42×22 的游戏区域）
    buf: [8192]u8,

    /// 初始化屏幕：隐藏光标 + 清屏
    fn initScreen(self: *Renderer) !void {
        try self.writer.writeAll("\x1b[?25l\x1b[2J");
    }

    /// 恢复屏幕：显示光标 + 清屏 + 光标回左上角
    fn restoreScreen(self: *Renderer) !void {
        try self.writer.writeAll("\x1b[?25h\x1b[2J\x1b[H");
    }

    /// 渲染一帧。
    ///
    /// 绘制顺序（从后往前画，后面的覆盖前面的）：
    ///   空格 → 障碍物 → 食物/道具 → 蛇
    ///
    /// 每个格子检查顺序：
    ///   1. 加速道具？（金色 ★）
    ///   2. 普通食物？（红色 ●）
    ///   3. 障碍物？（灰色 ▓）
    ///   4. 蛇身？（彩虹 ■，蛇头特殊处理）
    ///   5. 否则空格
    fn render(self: *Renderer, game: *const Game) !void {
        // .fixed(&buf) 创建一个写入固定缓冲区的 Writer
        // 所有 writeAll/print 都会写入 buf 而不是直接输出
        var w: std.Io.Writer = .fixed(&self.buf);

        // 光标回左上角（重绘整个画面，避免闪烁）
        try w.writeAll("\x1b[H");

        // ── 顶部边框（每个游戏单元 = 2 字符宽，使视觉正方形）──
        try w.writeAll("┌");
        for (0..game.width - 2) |_| try w.writeAll("──");
        try w.writeAll("┐\r\n");

        // ── 游戏区域（逐行逐列）──
        // 每个游戏单元渲染为 2 个字符宽（██），
        // 配合终端字符约 1:2 宽高比，视觉上接近正方形
        var y: u16 = 1;
        while (y < game.height - 1) : (y += 1) {
            try w.writeAll("│"); // 左边框
            var x: u16 = 1;
            while (x < game.width - 1) : (x += 1) {
                // 按优先级检查每个格子画什么
                if (game.boost) |b| {
                    if (b.x == x and b.y == y) {
                        try w.writeAll("\x1b[33m★★\x1b[0m"); // 金色星星 = 加速道具
                        continue; // 跳到下一个 x
                    }
                }
                if (game.food.x == x and game.food.y == y) {
                    try w.writeAll("\x1b[31m●●\x1b[0m"); // 红色圆点 = 普通食物
                } else if (isObstacleAt(game, x, y)) {
                    try w.writeAll("\x1b[90m▓▓\x1b[0m"); // 灰色方块 = 障碍物
                } else if (snakeAt(game, x, y)) |seg_index| {
                    // 找到了蛇身，seg_index 是该节的索引（0 = 蛇头）
                    if (seg_index == 0) {
                        // 蛇头：加速时金色，平时绿色
                        if (game.boost_remaining > 0) {
                            try w.writeAll("\x1b[33m◆◆\x1b[0m");
                        } else {
                            try w.writeAll("\x1b[32m██\x1b[0m");
                        }
                    } else {
                        // 蛇身：彩虹渐变色
                        try w.writeAll(rainbowColor(seg_index - 1));
                        try w.writeAll("██");
                        try w.writeAll("\x1b[0m"); // 重置颜色
                    }
                } else {
                    try w.writeAll("  "); // 空格（2 个字符宽）
                }
            }
            try w.writeAll("│\r\n"); // 右边框 + 换行
        }

        // ── 底部边框 ──
        try w.writeAll("└");
        for (0..game.width - 2) |_| try w.writeAll("──");
        try w.writeAll("┘\r\n");

        // ── 状态信息栏 ──
        try w.print("  🏆 {d}", .{game.high_score}); // 历史最高分
        try w.print("  得分: {d}", .{game.score}); // 当前得分
        if (game.boost_remaining > 0) {
            try w.print("  ⚡×{d}", .{game.boost_remaining}); // 加速剩余步数
        }
        if (game.wrap_mode) try w.writeAll("  🔄穿墙"); // 穿墙模式指示
        if (game.paused) try w.writeAll("  ⏸暂停"); // 暂停指示
        try w.writeAll("\r\n");
        try w.writeAll("  WASD/方向键 | R:穿墙 | Q:退出 | P:暂停\r\n");

        // 把帧缓冲区的所有内容一次性输出到终端
        const written = std.Io.Writer.buffered(&w);
        try self.writer.writeAll(written);
    }
};

/// 查找 (x, y) 上的蛇身节索引。
/// 返回 null 表示这个位置没有蛇。
fn snakeAt(game: *const Game, x: u16, y: u16) ?usize {
    for (game.snake.body.items, 0..) |seg, i| {
        if (seg.x == x and seg.y == y) return i;
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 输入处理：平台相关的终端 raw 模式
// ═══════════════════════════════════════════════════════════════════════════════
// 已委托给 shared input 模块 (src/input.zig)。
//
// input.Terminal — 平台合适的 Terminal 类型：
//   enterRawMode() → Terminal
//   deinit()       → void
//   readKey()      → !?input.Key
//
// input.Key — union(enum) { up, down, left, right, enter, escape, char: u8 }
//

/// 将 `input.Key` 映射为游戏内语义按键。
/// 返回 null 表示忽略该按键（如 Escape）。
fn toGameKey(k: input.Key) ?Key {
    return switch (k) {
        .up => Key{ .direction = .up },
        .down => Key{ .direction = .down },
        .left => Key{ .direction = .left },
        .right => Key{ .direction = .right },
        .enter => Key.enter,
        .escape => null,
        .char => |c| switch (c) {
            'q', 'Q' => Key.quit,
            'p', 'P' => Key.pause,
            'r', 'R' => Key.toggle_wrap,
            'w', 'W' => Key{ .direction = .up },
            's', 'S' => Key{ .direction = .down },
            'a', 'A' => Key{ .direction = .left },
            'd', 'D' => Key{ .direction = .right },
            else => null,
        },
    };
}

/// 按键的语义表示。
/// union(enum) = 带标签的联合体 = Rust 的 enum。
const Key = union(enum) {
    direction: Game.Direction, // 方向键或 WASD → 携带具体方向
    quit, // Q 键 → 退出
    pause, // P 键 → 暂停/恢复
    toggle_wrap, // R 键 → 切换穿墙模式
    enter, // 回车键 → 退出结束画面
};

// ═══════════════════════════════════════════════════════════════════════════════
// 持久化：最高分文件读写
// ═══════════════════════════════════════════════════════════════════════════════

/// 从 .snake_highscore 文件读取历史最高分。
/// 文件不存在或格式错误时返回 0。
fn loadHighScore(allocator: mem.Allocator, io: std.Io) u32 {
    // readFileAlloc 一次性读取整个文件到堆内存
    // .limited(32) 限制最多读 32 字节（防止恶意大文件）
    const contents = std.Io.Dir.cwd().readFileAlloc(io, SCORE_FILE, allocator, .limited(32)) catch return 0;
    defer allocator.free(contents); // 读完立刻释放

    // 去掉尾部空白（换行符等）
    const trimmed = mem.trimEnd(u8, contents, &std.ascii.whitespace);
    // 解析为无符号整数
    return std.fmt.parseUnsigned(u32, trimmed, 10) catch 0;
}

/// 把当前分数写入 .snake_highscore 文件（覆盖）。
/// 只在破纪录时调用。
fn saveHighScore(io: std.Io, gpa: mem.Allocator, score: u32) !void {
    _ = gpa; // 这个函数不需要分配堆内存，但保留参数以供扩展

    // 把分数格式化成字符串
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{score});

    // 创建文件（覆盖已有文件）
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, SCORE_FILE, .{});
    defer file.close(io);

    // 写入分数
    var file_buf: [64]u8 = undefined;
    var fw = file.writer(io, &file_buf); // file.writer() 返回 Io.File.Writer
    try fw.interface.writeAll(text); // .interface 是底层的 Io.Writer
    try fw.flush(); // 确保数据写入磁盘
}

// ═══════════════════════════════════════════════════════════════════════════════
// 游戏主入口
// ═══════════════════════════════════════════════════════════════════════════════
//
// 整个游戏的驱动循环：
//
//   ┌──────────────────────────────────┐
//   │  加载最高分                      │
//   │  进入 raw 模式                   │
//   │  初始化渲染器                    │
//   │  初始化游戏状态                  │
//   │  ┌─ while (running) ──────────┐  │
//   │  │  读取所有待处理按键         │  │
//   │  │  若到时间 → 游戏前进一步    │  │
//   │  │  渲染一帧                  │  │
//   │  │  等待 ~16ms（≈60fps）     │  │
//   │  └───────────────────────────┘  │
//   │  保存最高分（如果破了纪录）      │
//   │  显示结束画面                   │
//   │  等待回车退出                   │
//   └──────────────────────────────────┘

pub fn run(allocator: mem.Allocator, io: std.Io) !void {
    // ── 游戏区域大小 ──
    const width: u16 = 42;
    const height: u16 = 22;

    // ── 加载历史最高分 ──
    const high_score = loadHighScore(allocator, io);

    // ── 终端 raw 模式 ──
    // defer 保证函数返回时恢复终端设置（即使 panic 也会执行）
    var term = try input.Terminal.enterRawMode();
    defer term.deinit();

    // ── 标准输出 ──
    // Io.File.Writer 是带缓冲的文件写入器
    // .init(文件句柄, Io 实例, 缓冲区) 创建一个 Writer
    // .interface 是底层的 Io.Writer，可以调用 writeAll/print 等方法
    var stdout_buf: [1024]u8 = undefined; // 1KB 输出缓冲
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout_writer = &stdout_file_writer.interface;

    // ── 渲染器（帧缓冲 8KB）──
    var renderer = Renderer{ .writer = stdout_writer, .buf = undefined };
    try renderer.initScreen();
    defer renderer.restoreScreen() catch {};

    // ── 初始化游戏 ──
    // 用当前时间戳（纳秒）作为随机种子
    const seed: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    var game = try Game.init(allocator, width, height, seed, high_score);
    defer game.deinit();

    // 生成第一个食物
    game.spawnFood();

    // ═══════════════════════════════════════════════════════════════
    // 主游戏循环
    // ═══════════════════════════════════════════════════════════════
    //
    // 两个独立的时钟：
    //   - 输入处理：每帧都检查（越快越好，保证响应灵敏）
    //   - 游戏步进：按 speed_ms 间隔更新（120ms 起步，逐渐加快）
    //   - 渲染：每帧都画（~60fps）
    //
    // last_step 记录上一次游戏步进的时间戳。
    var last_step = std.Io.Timestamp.now(io, .awake);
    while (game.running) {
        // ── 输入处理 ──
        // readKey 返回 null 表示没有按键，非 null 表示有按键。
        // while 循环一次性处理完所有积压的按键（防止输入延迟堆积）。
        while (try term.readKey()) |k| {
            if (toGameKey(k)) |key| {
                switch (key) {
                    .direction => |dir| {
                        // 不允许反向：如果蛇正在向右走，不能立刻向左
                        if (dir != game.direction.opposite()) {
                            game.next_direction = dir;
                        }
                    },
                    .quit => game.running = false,
                    .pause => game.paused = !game.paused,
                    .toggle_wrap => game.wrap_mode = !game.wrap_mode,
                    .enter => {}, // 游戏中回车无效
                }
            }
        }

        // ── 游戏步进 ──
        // 检查是否到了该移动的时间
        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed_ms = last_step.durationTo(now).toMilliseconds();
        if (elapsed_ms >= game.speed_ms) {
            last_step = now;
            try game.step();
        }

        // ── 渲染 ──
        try renderer.render(&game);

        // ── 帧率控制 ──
        // sleep 16ms ≈ 60fps 上限（防止 CPU 空转）
        // catch {} 忽略取消错误（Canceled）
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake) catch {};
    }

    // ═══════════════════════════════════════════════════════════════
    // 游戏结束
    // ═══════════════════════════════════════════════════════════════

    // 如果破了纪录，保存到文件
    const final_score: u32 = if (game.score > game.high_score) blk: {
        // blk: 是一个带标签的块，break :blk value 可以返回值
        saveHighScore(io, allocator, game.score) catch {};
        break :blk game.score;
    } else game.high_score;

    // 显示结束画面
    try renderer.restoreScreen();
    try stdout_writer.print("\n  🎮 游戏结束!\n", .{});
    try stdout_writer.print("  得分: {d}    最高分: {d}\n", .{ game.score, final_score });
    if (game.score > game.high_score and game.score > 0) {
        try stdout_writer.print("  🎉 新纪录!\n", .{});
    }
    try stdout_writer.print("\n  按 Enter 退出...", .{});
    try stdout_writer.flush(); // 确保所有输出都送到终端

    // 等待用户按 Enter 或 Q 退出
    while (true) {
        const k = try term.readKey();
        if (k) |ik| {
            if (toGameKey(ik)) |k2| {
                if (k2 == .enter or k2 == .quit) break;
            }
        }
        // 空闲等待 50ms，避免 CPU 空转
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════════

test "蛇初始状态" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, 20, 20, 42, 0);
    defer game.deinit(allocator);

    // 蛇应该有 3 节
    try std.testing.expectEqual(@as(usize, 3), game.snake.body.items.len);
    // 初始方向朝右
    try std.testing.expectEqual(Game.Direction.right, game.direction);
    // 初始分数为 0
    try std.testing.expectEqual(@as(u32, 0), game.score);
}

test "蛇移动" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, 20, 20, 42, 0);
    defer game.deinit();

    // 清除障碍物，避免随机障碍物干扰测试
    game.obstacles.clearRetainingCapacity();

    const old_head = game.snake.body.items[0];
    const old_tail = game.snake.body.items[game.snake.body.items.len - 1];

    try game.step();

    // 蛇头向前移动一格（方向朝右，x + 1）
    try std.testing.expectEqual(old_head.x + 1, game.snake.body.items[0].x);
    try std.testing.expectEqual(old_head.y, game.snake.body.items[0].y);

    // 旧蛇尾已不在蛇身中
    for (game.snake.body.items) |seg| {
        try std.testing.expect(!(seg.x == old_tail.x and seg.y == old_tail.y));
    }

    // 长度不变（没吃到食物）
    try std.testing.expectEqual(@as(usize, 3), game.snake.body.items.len);
}

test "吃食物" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, 20, 20, 42, 0);
    defer game.deinit();

    // 清除障碍物
    game.obstacles.clearRetainingCapacity();

    const head = game.snake.body.items[0];
    // 把食物放在蛇头正前方一格（方向朝右）
    game.food = .{ .x = head.x + 1, .y = head.y };

    try game.step();

    // 吃到食物后分数增加（+10 分，非加速状态）
    try std.testing.expect(game.score > 0);
    // 蛇变长（吃到食物时不 pop 蛇尾）
    try std.testing.expectEqual(@as(usize, 4), game.snake.body.items.len);
}

test "撞墙死亡" {
    const allocator = std.testing.allocator;
    // 使用 8×8 的小地图，蛇头起点 (4,4)，向右走 3 步后撞到右墙
    var game = try Game.init(allocator, 8, 8, 42, 0);
    defer game.deinit();

    // 清除障碍物，确保蛇能走到墙边
    game.obstacles.clearRetainingCapacity();

    // 走 2 步到达 x=6（最右安全格），第 3 步 x=7 即撞墙（width-1=7）
    try game.step(); // head: (4,4) → (5,4)
    try game.step(); // head: (5,4) → (6,4)
    try game.step(); // head: (6,4) → (7,4)，x>=7 撞墙

    try std.testing.expect(!game.running);
}

test "撞自己死亡" {
    const allocator = std.testing.allocator;
    var game = try Game.init(allocator, 20, 20, 42, 0);
    defer game.deinit();

    // 清除障碍物
    game.obstacles.clearRetainingCapacity();

    // 构造一条环形的蛇：头 (5,5) 向右走到 (6,5)，会撞到第二节身体
    game.snake.body.clearRetainingCapacity();
    try game.snake.body.appendSlice(allocator, &[_]Game.Position{
        .{ .x = 5, .y = 5 }, // 蛇头
        .{ .x = 6, .y = 5 }, // 第 2 节 —— 新蛇头正前方
        .{ .x = 6, .y = 6 }, // 第 3 节
        .{ .x = 5, .y = 6 }, // 第 4 节（蛇尾，碰撞检测排除它）
    });
    game.direction = .right;
    game.next_direction = .right;

    // 蛇头 (5,5) 向右走一步到 (6,5)，撞到第 2 节身体 → 死亡
    try game.step();

    try std.testing.expect(!game.running);
}

test "不能掉头" {
    // Direction.opposite() 返回反方向
    try std.testing.expectEqual(Game.Direction.down, Game.Direction.up.opposite());
    try std.testing.expectEqual(Game.Direction.up, Game.Direction.down.opposite());
    try std.testing.expectEqual(Game.Direction.right, Game.Direction.left.opposite());
    try std.testing.expectEqual(Game.Direction.left, Game.Direction.right.opposite());
}
