//! Snake 游戏的 WASM 导出层。
//!
//! 这个文件把 Game 的核心逻辑编译为 WebAssembly，
//! 导出给 JavaScript 调用。渲染和输入由 HTML/JS 负责。
//!
//! 编译命令：
//!   zig build-exe src/wasm.zig -target wasm32-freestanding -OReleaseSmall --export=snake_init --export=snake_step --export=snake_get_state --export=snake_set_direction --export=snake_get_width --export=snake_get_height --export=snake_get_score --export=snake_memory
//!
//! 或者用 zig build（需要在 build.zig 里加 wasm target）

const std = @import("std");

// WASM 没有操作系统，用固定大小的静态内存
const WIDTH: u16 = 40;
const HEIGHT: u16 = 30;
const MAX_SNAKE_LEN: usize = 500; // 蛇的最大长度

const Direction = enum(u8) {
    up = 0,
    down = 1,
    left = 2,
    right = 3,
};

const Position = struct {
    x: u16,
    y: u16,
};

/// 游戏状态 — 全部用固定大小数组（WASM 没有堆分配器）
const GameState = struct {
    /// 蛇身 x 坐标数组
    snake_x: [MAX_SNAKE_LEN]u16,
    /// 蛇身 y 坐标数组
    snake_y: [MAX_SNAKE_LEN]u16,
    /// 蛇当前长度
    snake_len: u16,
    /// 蛇头方向
    dir: Direction,
    /// 食物位置
    food_x: u16,
    food_y: u16,
    /// 分数
    score: u32,
    /// 游戏是否结束
    game_over: bool,
    /// 随机种子
    seed: u32,
};

/// 全局游戏状态（WASM 线性内存中）
var state: GameState = undefined;

/// 简易伪随机数生成器（xorshift32）
fn random(seed: *u32) u16 {
    var x = seed.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    seed.* = x;
    return @truncate(x);
}

/// 在新位置生成食物（避开蛇身）
fn spawnFood() void {
    var s: u32 = state.seed;
    while (true) {
        const x = random(&s) % WIDTH;
        const y = random(&s) % HEIGHT;
        state.seed = s;

        // 确保不生成在蛇身上
        var on_snake = false;
        var i: u16 = 0;
        while (i < state.snake_len) : (i += 1) {
            if (state.snake_x[i] == x and state.snake_y[i] == y) {
                on_snake = true;
                break;
            }
        }
        if (!on_snake) {
            state.food_x = x;
            state.food_y = y;
            return;
        }
        s +%= 1; // 防止死循环
    }
}

// ═══════════════════════════════════════════════════════════════
// 导出函数（JavaScript 通过 WebAssembly 调用）
// ═══════════════════════════════════════════════════════════════

/// 初始化游戏。seed 从 JS 传入（如 Date.now()）。
export fn snake_init(seed: u32) void {
    state.seed = seed;
    state.snake_len = 3;
    state.dir = .right;
    state.score = 0;
    state.game_over = false;

    // 蛇从中心开始，水平 3 节，朝右
    const start_x = WIDTH / 2;
    const start_y = HEIGHT / 2;
    state.snake_x[0] = start_x;
    state.snake_y[0] = start_y;
    state.snake_x[1] = start_x - 1;
    state.snake_y[1] = start_y;
    state.snake_x[2] = start_x - 2;
    state.snake_y[2] = start_y;

    spawnFood();
}

/// 设置方向。JS 在按键事件中调用。
export fn snake_set_direction(dir: u8) void {
    const new_dir: Direction = @enumFromInt(dir);
    // 防止掉头
    const opposite = switch (state.dir) {
        .up => Direction.down,
        .down => Direction.up,
        .left => Direction.right,
        .right => Direction.left,
    };
    if (new_dir != opposite) {
        state.dir = new_dir;
    }
}

/// 游戏前进一步。返回 1 表示吃到食物（JS 可以加分/播放音效）。
export fn snake_step() u8 {
    if (state.game_over) return 0;

    // ── 计算新蛇头 ──
    var new_x = state.snake_x[0];
    var new_y = state.snake_y[0];
    switch (state.dir) {
        .up => new_y -= 1,
        .down => new_y += 1,
        .left => new_x -= 1,
        .right => new_x += 1,
    }

    // ── 撞墙检测（边界在 0..WIDTH-1, 0..HEIGHT-1）──
    if (new_x >= WIDTH or new_y >= HEIGHT) {
        state.game_over = true;
        return 0;
    }

    // ── 撞自己检测 ──
    var i: u16 = 0;
    while (i < state.snake_len - 1) : (i += 1) {
        if (state.snake_x[i] == new_x and state.snake_y[i] == new_y) {
            state.game_over = true;
            return 0;
        }
    }

    // ── 移动蛇身（从尾到头前移，位置 0 留给新蛇头）──
    i = state.snake_len;
    while (i > 1) {
        i -= 1;
        state.snake_x[i] = state.snake_x[i - 1];
        state.snake_y[i] = state.snake_y[i - 1];
    }
    state.snake_x[0] = new_x;
    state.snake_y[0] = new_y;

    // ── 吃食物判定 ──
    if (new_x == state.food_x and new_y == state.food_y) {
        state.score += 10;
        if (state.snake_len < MAX_SNAKE_LEN) {
            state.snake_len += 1;
        }
        spawnFood();
        return 1; // 吃到了
    }

    return 0;
}

/// 获取游戏状态指针（JS 通过 memory 读取蛇身数组）
export fn snake_get_state() [*]u16 {
    return &state.snake_x;
}

/// 获取蛇的长度
export fn snake_get_len() u16 {
    return state.snake_len;
}

/// 获取食物坐标（低 16 位 x，高 16 位 y）
export fn snake_get_food() u32 {
    return (@as(u32, state.food_x)) | (@as(u32, state.food_y) << 16);
}

/// 获取游戏结束标志
export fn snake_is_game_over() u8 {
    return if (state.game_over) @as(u8, 1) else @as(u8, 0);
}

/// 获取分数
export fn snake_get_score() u32 {
    return state.score;
}

/// 获取地图宽度
export fn snake_get_width() u16 {
    return WIDTH;
}

/// 获取地图高度
export fn snake_get_height() u16 {
    return HEIGHT;
}
