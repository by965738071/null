//! 2048 游戏 WASM 导出层。
//!
//! 把核心游戏逻辑编译为 WebAssembly，导出给 JavaScript 调用。
//! 全部使用固定大小数组，无堆分配，兼容 wasm32-freestanding 目标。
//! grid 使用 u32 避免 65536 时 u16 溢出回零。

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
    /// 使用 u32 防止合成 65536 时溢出回零（理论上限 131072）
    grid: [16]u32,
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

/// 在随机空格中生成新方块。
/// 90% 概率生成 2，10% 概率生成 4。
fn addRandomTile() void {
    // 收集所有空格坐标
    var empty_buf: [16]usize = undefined; // 最多 16 个空格
    var empty_count: u8 = 0;
    for (0..16) |idx| {
        if (state.grid[idx] == 0) {
            empty_buf[empty_count] = idx;
            empty_count += 1;
        }
    }
    if (empty_count == 0) return;

    // 用 xorshift 选一个随机空格
    const rand_idx = xorshift32(&state.seed) % empty_count;

    // 90% 生成 2，10% 生成 4
    const value: u32 = if (xorshift32(&state.seed) % 10 == 0) 4 else 2;
    state.grid[empty_buf[rand_idx]] = value;
}

/// 将一行（4 个 u32）向左滑动并合并。
/// 返回合并后的新行，并通过指针累加分数。
fn slideRow(row: [4]u32, add_score: *u32) [4]u32 {
    var compacted: [4]u32 = .{ 0, 0, 0, 0 };
    var pos: u8 = 0;
    for (row) |v| {
        if (v != 0) {
            compacted[pos] = v;
            pos += 1;
        }
    }

    for (0..3) |i| {
        if (compacted[i] != 0 and compacted[i] == compacted[i + 1]) {
            compacted[i] *= 2;
            add_score.* += compacted[i];
            compacted[i + 1] = 0;
            if (compacted[i] == 2048) {
                state.won = true;
            }
        }
    }

    var result: [4]u32 = .{ 0, 0, 0, 0 };
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
fn rowChanged(old: [4]u32, new: [4]u32) bool {
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
        0 => {
            for (0..GRID_SIZE) |c| {
                var row: [4]u32 = undefined;
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
        1 => {
            for (0..GRID_SIZE) |c| {
                var row: [4]u32 = undefined;
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
        2 => {
            for (0..GRID_SIZE) |r| {
                const row_start: u8 = @intCast(r * GRID_SIZE);
                var row: [4]u32 = undefined;
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
        3 => {
            for (0..GRID_SIZE) |r| {
                const row_start: u8 = @intCast(r * GRID_SIZE);
                var row: [4]u32 = undefined;
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
fn canMove() bool {
    for (0..GRID_SIZE) |r| {
        for (0..GRID_SIZE) |c| {
            if (state.grid[r * GRID_SIZE + c] == 0) return true;
        }
    }

    for (0..GRID_SIZE) |r| {
        const row_start: u8 = @intCast(r * GRID_SIZE);
        for (0..GRID_SIZE - 1) |c| {
            if (state.grid[row_start + c] == state.grid[row_start + c + 1]) return true;
        }
    }

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
export fn game2048_init(seed: u32) void {
    for (0..16) |i| {
        state.grid[i] = 0;
    }
    state.score = 0;
    state.won = false;
    state.over = false;
    state.seed = seed;

    addRandomTile();
    addRandomTile();
}

/// 执行一次移动。dir: 0=up 1=down 2=left 3=right
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

/// 获取网格指针（16 个 u32，共 64 字节）。
/// JS 端通过 WASM memory 读取，行优先排列。0 表示空格。
export fn game2048_get_grid() [*]u32 {
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
