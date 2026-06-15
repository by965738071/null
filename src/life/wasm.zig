//! 康威生命游戏的 WASM 导出层。
//!
//! 把核心逻辑编译为 WebAssembly，导出给 JavaScript 调用。
//! 渲染和输入由 HTML/JS 负责。
//!
//! 编译命令：
//!   zig build-exe src/wasm/life.zig -target wasm32-freestanding -OReleaseSmall \
//!     --export=life_init --export=life_step --export=life_get_grid \
//!     --export=life_get_width --export=life_get_height --export=life_get_generation \
//!     --export=life_toggle --export=life_randomize

// ── 常量 ────────────────────────────────────────────────────────
const W = 60; // 网格宽度
const H = 40; // 网格高度

// ── 全局状态（全部固定大小，无堆分配）───────────────────────────────
var cur: [H][W]u8 = undefined; // 当前帧
var next: [H][W]u8 = undefined; // 下一帧（用于双缓冲计算）
var generation: u32 = 0; // 当前代数
var rng_state: u32 = 0; // xorshift32 状态

// ═══════════════════════════════════════════════════════════════════
// 内部辅助函数
// ═══════════════════════════════════════════════════════════════════

/// xorshift32 伪随机数生成器（Marsaglia, 2003）
fn xorshift32() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/// 用随机种子填充当前网格（约 30% 存活）
fn populateRandom() void {
    for (0..H) |y| {
        for (0..W) |x| {
            // 取随机值的高位判断，约 30% 概率为活
            cur[y][x] = if (xorshift32() % 10 < 3) @as(u8, 1) else @as(u8, 0);
        }
    }
}

/// 计算 (y, x) 细胞的活邻居数（环形边界，用 @mod 处理回绕）
fn countNeighbors(y: usize, x: usize) u8 {
    var n: u8 = 0;
    const dy_vals = [_]i2{ -1, 0, 1 };
    const dx_vals = [_]i2{ -1, 0, 1 };
    for (dy_vals) |dy| {
        for (dx_vals) |dx| {
            if (dy == 0 and dx == 0) continue;
            // @mod 同时处理正负偏移，实现环形回绕
            const ny: usize = @intCast(@mod(@as(i32, @intCast(y)) + dy, H));
            const nx: usize = @intCast(@mod(@as(i32, @intCast(x)) + dx, W));
            n += cur[ny][nx];
        }
    }
    return n;
}

// ═══════════════════════════════════════════════════════════════════
// 导出函数（JavaScript 通过 WebAssembly 调用）
// ═══════════════════════════════════════════════════════════════════

/// 初始化网格。seed 从 JS 传入（如 Date.now()）。
export fn life_init(seed: u32) void {
    rng_state = seed;
    generation = 0;
    populateRandom();
}

/// 演化一代：根据康威规则计算 next，然后与 cur 交换。
export fn life_step() void {
    // 对每个细胞应用规则
    for (0..H) |y| {
        for (0..W) |x| {
            const n = countNeighbors(y, x);
            next[y][x] = if (cur[y][x] == 1)
                @as(u8, if (n == 2 or n == 3) 1 else 0)
            else
                @as(u8, if (n == 3) 1 else 0);
        }
    }
    // 双缓冲交换：cur ← next
    const tmp = cur;
    cur = next;
    next = tmp;
    generation += 1;
}

/// 返回网格指针（W * H 字节，行主序，1=活 0=死）。
/// JS 端通过 Module.HEAPU8 读取。
export fn life_get_grid() [*]u8 {
    return @ptrCast(&cur[0][0]);
}

/// 返回网格宽度
export fn life_get_width() u32 {
    return W;
}

/// 返回网格高度
export fn life_get_height() u32 {
    return H;
}

/// 返回当前代数
export fn life_get_generation() u32 {
    return generation;
}

/// 切换 (x, y) 位置细胞状态。越界坐标会被忽略。
export fn life_toggle(x: u32, y: u32) void {
    if (x < W and y < H) {
        cur[@intCast(y)][@intCast(x)] ^= 1;
    }
}

/// 用新种子随机重置整个网格。
export fn life_randomize(seed: u32) void {
    rng_state = seed;
    generation = 0;
    populateRandom();
}
