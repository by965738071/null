//! 2048 游戏 WASM 导出层。
//!
//! 把核心游戏逻辑编译为 WebAssembly，导出给 JavaScript 调用。
//! 全部使用固定大小数组，无堆分配，兼容 wasm32-freestanding 目标。
//!
//! 编译命令：
//!   zig build-exe src/wasm/game2048.zig -target wasm32-freestanding -fno-entry -OReleaseSmall
//!   然后按需 --export 各函数，或用 wasm-opt 处理。

// ═══════════════════════════════════════════════════════════════
// 常量定义
// ═══════════════════════════════════════════════════════════════

/// 网格大小（4×4）
const GRID_SIZE: u8 = 4;

// ═══════════════════════════════════════════════════════════════
// 全局游戏状态
// ═══════════════════════════════════════════════════════════════

/// 全部字段为标量或固定大小数组，不依赖堆分配。
const GameState = struct {
    /// 4×4 网格，平铺为一维数组（行优先），0 表示空格
    grid: [16]u16,
    /// 当前分数（合并数字的总和）
    score: u32,
    /// 是否已经合成过 2048
    won: bool,
    /// 游戏是否结束（无空格且无可合并相邻格）
    over: bool,
    /// 随机数种子
    seed: u32,
};

/// 全局游戏状态（WASM 线性内存中）
var state: GameState = undefined;

// ═══════════════════════════════════════════════════════════════
// xorshift32 伪随机数生成器
// ═══════════════════════════════════════════════════════════════

fn xorshift32(seed: *u32) u32 {
    var x = seed.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    seed.* = x;
    return x;
}

// ═══════════════════════════════════════════════════════════════
// 核心游戏逻辑
// ═══════════════════════════════════════════════════════════════

/// 获取空格个数并填充坐标数组。返回空格数量。
/// 坐标数组最多 16 个 (row, col)，每个坐标占 2 个 u8（行在前，列在后）。
fn findEmptyCells(buf: *[32]u8) u8 {
    var count: u8 = 0;
    for (0..GRID_SIZE) |r| {
        for (0..GRID_SIZE) |c| {
            const idx: u8 = @intCast(r * GRID_SIZE + c);
            if (state.grid[idx] == 0) {
                buf[count * 2] = @intCast(r);
                buf[count * 2 + 1] = @intCast(c);
                count += 1;
            }
        }
    }
    return count;
}

/// 在随机空格中生成新方块。
/// 90% 概率生成 2，10% 概率生成 4。
fn addRandomTile() void {
    var buf: [32]u8 = undefined;
    const empty_count = findEmptyCells(&buf);
    if (empty_count == 0) return;

    // 用 xorshift 选一个随机空格
    const rand_idx = xorshift32(&state.seed) % empty_count;
    const r = buf[rand_idx * 2];
    const c = buf[rand_idx * 2 + 1];
    const grid_idx: u8 = @intCast(r * GRID_SIZE + c);

    // 90% 生成 2，10% 生成 4
    const value: u16 = if (xorshift32(&state.seed) % 10 == 0) @as(u16, 4) else @as(u16, 2);
    state.grid[grid_idx] = value;
}

/// 将一行（4 个 u16）向左滑动并合并。
/// 返回合并后的新行，并通过指针累加分数。
///
/// 算法：
///   1. 压实：去掉所有 0，非零值左对齐
///   2. 合并：从左到右扫描，相邻相等值合并一次
///   3. 再次压实：去掉合并产生的 0
fn slideRow(row: [4]u16, add_score: *u32) [4]u16 {
    // 第一步：压实（去掉 0）
    var compacted: [4]u16 = .{ 0, 0, 0, 0 };
    var pos: u8 = 0;
    for (row) |v| {
        if (v != 0) {
            compacted[pos] = v;
            pos += 1;
        }
    }

    // 第二步：合并相邻相等值
    for (0..3) |i| {
        if (compacted[i] != 0 and compacted[i] == compacted[i + 1]) {
            compacted[i] *= 2;
            add_score.* += compacted[i];
            compacted[i + 1] = 0;
            // 检查是否合成 2048
            if (compacted[i] == 2048) {
                state.won = true;
            }
        }
    }

    // 第三步：再次压实
    var result: [4]u16 = .{ 0, 0, 0, 0 };
    pos = 0;
    for (compacted) |v| {
        if (v != 0) {
            result[pos] = v;
            pos += 1;
        }
    }

    return result;
}

/// 检测网格是否发生变化（滑动前后比较）
fn rowChanged(old: [4]u16, new: [4]u16) bool {
    for (0..4) |i| {
        if (old[i] != new[i]) return true;
    }
    return false;
}

/// 对整个网格执行一次滑动。
/// dir: 0=up 1=down 2=left 3=right
/// 返回 true 表示网格发生了变化（有方块移动或合并）。
fn moveGrid(dir: u32, add_score: *u32) bool {
    var changed = false;

    switch (dir) {
        // Up：每列自上而下提取 → slideRow → 写回
        0 => {
            for (0..GRID_SIZE) |c| {
                var row: [4]u16 = undefined;
                for (0..GRID_SIZE) |r| {
                    row[r] = state.grid[r * GRID_SIZE + c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (rowChanged(old_row, new_row)) {
                    changed = true;
                    for (0..GRID_SIZE) |r| {
                        state.grid[r * GRID_SIZE + c] = new_row[r];
                    }
                }
            }
        },
        // Down：每列自下而上提取（反转） → slideRow → 反转写回
        1 => {
            for (0..GRID_SIZE) |c| {
                var row: [4]u16 = undefined;
                for (0..GRID_SIZE) |r| {
                    row[GRID_SIZE - 1 - r] = state.grid[r * GRID_SIZE + c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (rowChanged(old_row, new_row)) {
                    changed = true;
                    for (0..GRID_SIZE) |r| {
                        state.grid[(GRID_SIZE - 1 - r) * GRID_SIZE + c] = new_row[r];
                    }
                }
            }
        },
        // Left：每行原样 → slideRow → 写回
        2 => {
            for (0..GRID_SIZE) |r| {
                const row_start: u8 = @intCast(r * GRID_SIZE);
                var row: [4]u16 = undefined;
                for (0..GRID_SIZE) |c| {
                    row[c] = state.grid[row_start + c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (rowChanged(old_row, new_row)) {
                    changed = true;
                    for (0..GRID_SIZE) |c| {
                        state.grid[row_start + c] = new_row[c];
                    }
                }
            }
        },
        // Right：每行反转 → slideRow → 反转写回
        3 => {
            for (0..GRID_SIZE) |r| {
                const row_start: u8 = @intCast(r * GRID_SIZE);
                var row: [4]u16 = undefined;
                for (0..GRID_SIZE) |c| {
                    row[GRID_SIZE - 1 - c] = state.grid[row_start + c];
                }
                const old_row = row;
                const new_row = slideRow(row, add_score);
                if (rowChanged(old_row, new_row)) {
                    changed = true;
                    for (0..GRID_SIZE) |c| {
                        state.grid[row_start + GRID_SIZE - 1 - c] = new_row[c];
                    }
                }
            }
        },
        else => return false,
    }

    return changed;
}

/// 检测是否还有可用的移动（任意方向滑动是否能让网格变化）。
/// 用于判断游戏是否结束。
fn canMove() bool {
    // 检查是否有空格
    for (0..GRID_SIZE) |r| {
        for (0..GRID_SIZE) |c| {
            if (state.grid[r * GRID_SIZE + c] == 0) return true;
        }
    }

    // 检查水平相邻格是否有相同值
    for (0..GRID_SIZE) |r| {
        const row_start: u8 = @intCast(r * GRID_SIZE);
        for (0..GRID_SIZE - 1) |c| {
            if (state.grid[row_start + c] == state.grid[row_start + c + 1]) return true;
        }
    }

    // 检查垂直相邻格是否有相同值
    for (0..GRID_SIZE - 1) |r| {
        for (0..GRID_SIZE) |c| {
            if (state.grid[r * GRID_SIZE + c] == state.grid[(r + 1) * GRID_SIZE + c]) return true;
        }
    }

    return false;
}

/// 更新游戏结束标志
fn updateGameOver() void {
    state.over = !canMove();
}

// ═══════════════════════════════════════════════════════════════
// 导出函数（JavaScript 通过 WebAssembly 调用）
// ═══════════════════════════════════════════════════════════════

/// 初始化游戏。seed 从 JS 传入（如 Date.now()）。
/// 清空网格，随机放置 2 个初始方块（2 或 4）。
export fn game2048_init(seed: u32) void {
    // 清空网格
    for (0..16) |i| {
        state.grid[i] = 0;
    }
    state.score = 0;
    state.won = false;
    state.over = false;
    state.seed = seed;

    // 初始放置 2 个随机方块
    addRandomTile();
    addRandomTile();
}

/// 执行一次移动。
/// dir: 0=up 1=down 2=left 3=right
/// 返回本次移动的得分（合并产生的分数）。
export fn game2048_move(dir: u32) u32 {
    if (state.over) return 0;

    var add_score: u32 = 0;
    const changed = moveGrid(dir, &add_score);

    if (changed) {
        state.score += add_score;
        addRandomTile();
        updateGameOver();
    }

    return add_score;
}

/// 获取网格指针（16 个 u16，共 32 字节）。
/// JS 端通过 WASM memory 读取，行优先排列。0 表示空格。
export fn game2048_get_grid() [*]u16 {
    return &state.grid;
}

/// 获取当前分数
export fn game2048_get_score() u32 {
    return state.score;
}

/// 游戏是否结束：返回 1（无可用移动）或 0（可继续）
export fn game2048_is_game_over() u32 {
    return if (state.over) @as(u32, 1) else @as(u32, 0);
}

/// 是否已合成 2048：返回 1（已胜利）或 0（未胜利）
export fn game2048_has_won() u32 {
    return if (state.won) @as(u32, 1) else @as(u32, 0);
}
