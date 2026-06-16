//! 俄罗斯方块 WASM 导出层。
//!
//! 把核心游戏逻辑编译为 WebAssembly，导出给 JavaScript 调用。
//! 全部使用固定大小数组，无堆分配，兼容 wasm32-freestanding 目标。
//!
//! 编译命令：
//!   zig build-exe src/wasm/tetris.zig -target wasm32-freestanding -fno-entry -OReleaseSmall
//!   然后按需 --export 各函数，或用 wasm-opt 处理。

// ═══════════════════════════════════════════════════════════════
// 常量定义
// ═══════════════════════════════════════════════════════════════

/// 棋盘宽度（格子数）
const BOARD_WIDTH: u8 = 10;
/// 棋盘高度（格子数）
const BOARD_HEIGHT: u8 = 20;
/// 棋盘总格数（传给 JS 的数组长度）
const BOARD_SIZE = BOARD_WIDTH * BOARD_HEIGHT; // 200

/// 7 种标准俄罗斯方块，每种用 4×4 的 u8 矩阵表示。
/// 每行是一个 u8，bit 3（最高位）= 最左列，bit 0 = 最右列。
const PIECES = [7][4]u8{
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

// ═══════════════════════════════════════════════════════════════
// 方块旋转：矩阵转置 + 水平翻转（顺时针 90°）
// ═══════════════════════════════════════════════════════════════

/// 将 4×4 矩阵顺时针旋转 90°。
/// 算法：先转置，再水平翻转每一行。
fn rotatePiece(shape: [4]u8) [4]u8 {
    // 第一步：转置（行变列）
    var transposed = [_]u8{ 0, 0, 0, 0 };
    for (0..4) |row| {
        for (0..4) |col| {
            if ((shape[row] >> @intCast(3 - col)) & 1 == 1) {
                transposed[col] |= @as(u8, 1) << @intCast(3 - row);
            }
        }
    }
    // 第二步：水平翻转每一行
    var result = [_]u8{ 0, 0, 0, 0 };
    for (0..4) |row| {
        result[row] = @bitReverse(transposed[row]) >> 4;
    }
    return result;
}

/// 获取指定旋转次数的方块形状
fn getShape(piece_index: u8, rotation: u8) [4]u8 {
    var shape = PIECES[piece_index];
    var i: u8 = 0;
    while (i < rotation) : (i += 1) {
        shape = rotatePiece(shape);
    }
    return shape;
}

// ═══════════════════════════════════════════════════════════════
// 全局游戏状态
// ═══════════════════════════════════════════════════════════════

/// 全部字段为标量或固定大小数组，不依赖堆分配。
const GameState = struct {
    /// 棋盘：10×20，0=空，1-7=颜色
    board: [BOARD_SIZE]u8,
    /// 当前方块类型（0-6）
    current_piece: u8,
    /// 当前方块旋转次数（0-3）
    current_rotation: u8,
    /// 当前方块左上角列坐标
    current_x: i16,
    /// 当前方块左上角行坐标（可为负）
    current_y: i16,
    /// 下一个方块类型
    next_piece: u8,
    /// 分数
    score: u32,
    /// 游戏是否结束
    game_over: bool,
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

/// 返回 0~6 的随机方块类型索引
fn randomPiece() u8 {
    return @truncate(xorshift32(&state.seed) % 7);
}

// ═══════════════════════════════════════════════════════════════
// 碰撞检测
// ═══════════════════════════════════════════════════════════════

/// 检查形状在指定位置是否与边界或已锁定方块重叠。
/// 返回 true 表示有碰撞。
fn checkCollision(shape: [4]u8, px: i16, py: i16) bool {
    for (0..4) |row| {
        for (0..4) |col| {
            if ((shape[row] >> @intCast(3 - col)) & 1 == 0) continue;

            const bx = px + @as(i16, @intCast(col));
            const by = py + @as(i16, @intCast(row));

            // 左右边界检查
            if (bx < 0 or bx >= BOARD_WIDTH) return true;
            // 底部边界检查
            if (by >= BOARD_HEIGHT) return true;
            // 顶部之上允许（方块可以部分在屏幕上方）
            if (by < 0) continue;
            // 与已锁定方块碰撞
            const idx: usize = @intCast(@as(u16, @intCast(by)) * BOARD_WIDTH + @as(u16, @intCast(bx)));
            if (state.board[idx] != 0) return true;
        }
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════
// 方块锁定与行消除
// ═══════════════════════════════════════════════════════════════

/// 将当前方块锁定到棋盘上
fn lockPiece(shape: [4]u8) void {
    const color: u8 = state.current_piece + 1; // 1~7
    for (0..4) |row| {
        for (0..4) |col| {
            if ((shape[row] >> @intCast(3 - col)) & 1 == 0) continue;
            const bx = state.current_x + @as(i16, @intCast(col));
            const by = state.current_y + @as(i16, @intCast(row));
            if (bx >= 0 and bx < BOARD_WIDTH and by >= 0 and by < BOARD_HEIGHT) {
                const idx: usize = @intCast(@as(u16, @intCast(by)) * BOARD_WIDTH + @as(u16, @intCast(bx)));
                state.board[idx] = color;
            }
        }
    }
}

/// 检查并消除所有满行，返回消除的行数（0-4）。
fn clearLines() u8 {
    var cleared: u8 = 0;
    var row: i16 = BOARD_HEIGHT - 1;
    while (row >= 0) {
        // 检查当前行是否满
        var full = true;
        const row_start: usize = @intCast(@as(u16, @intCast(row)) * BOARD_WIDTH);
        for (0..BOARD_WIDTH) |c| {
            if (state.board[row_start + c] == 0) {
                full = false;
                break;
            }
        }

        if (full) {
            // 将当前行以上的所有行下移一行
            var r: i16 = row;
            while (r > 0) : (r -= 1) {
                const src_start: usize = @intCast(@as(u16, @intCast(r - 1)) * BOARD_WIDTH);
                const dst_start: usize = @intCast(@as(u16, @intCast(r)) * BOARD_WIDTH);
                for (0..BOARD_WIDTH) |c| {
                    state.board[dst_start + c] = state.board[src_start + c];
                }
            }
            // 最顶行清空
            const top_start: usize = 0;
            for (0..BOARD_WIDTH) |c| {
                state.board[top_start + c] = 0;
            }
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
        state.score += points;
    }

    return cleared;
}

/// 生成新方块。如果一生成就碰撞，则游戏结束。
fn spawnPiece() void {
    state.current_rotation = 0;
    state.current_x = 3; // 水平居中：(10-4)/2
    state.current_y = 0;
    const shape = getShape(state.current_piece, state.current_rotation);
    if (checkCollision(shape, state.current_x, state.current_y)) {
        state.game_over = true;
    }
}

// ═══════════════════════════════════════════════════════════════
// 导出函数（JavaScript 通过 WebAssembly 调用）
// ═══════════════════════════════════════════════════════════════

/// tetris_get_shape 的输出缓冲区
var shape_out: [4]u8 = undefined;

/// 获取指定类型的方块形状（4 行，每行 u8 低 4 位有效）。
/// rotation: 0-3，顺时针旋转次数。
/// 返回指向 4 字节缓冲区的指针，JS 用 Uint8Array[m8] 读取。
export fn tetris_get_shape(piece_type: u8, rotation: u8) [*]u8 {
    shape_out = getShape(piece_type, rotation);
    return &shape_out;
}

/// 初始化游戏。seed 从 JS 传入（如 Date.now()）。
export fn tetris_init(seed: u32) void {
    // 清空棋盘
    for (0..BOARD_SIZE) |i| {
        state.board[i] = 0;
    }
    state.score = 0;
    state.game_over = false;
    state.seed = seed;

    // 生成当前方块和下一个方块
    state.current_piece = randomPiece();
    state.next_piece = randomPiece();
    spawnPiece();
}

/// 游戏前进一步（方块下落一行）。
/// 返回清除的行数（0-4），JS 可用此来加分或播放消行动画。
export fn tetris_step() u32 {
    if (state.game_over) return 0;

    const shape = getShape(state.current_piece, state.current_rotation);

    // 尝试下移
    if (!checkCollision(shape, state.current_x, state.current_y + 1)) {
        state.current_y += 1;
        return 0;
    }

    // 无法下移 → 锁定并生成下一个方块
    lockPiece(shape);
    const cleared = clearLines();

    state.current_piece = state.next_piece;
    state.next_piece = randomPiece();
    spawnPiece();

    return cleared;
}

/// 方块左移
export fn tetris_move_left() void {
    if (state.game_over) return;
    const shape = getShape(state.current_piece, state.current_rotation);
    if (!checkCollision(shape, state.current_x - 1, state.current_y)) {
        state.current_x -= 1;
    }
}

/// 方块右移
export fn tetris_move_right() void {
    if (state.game_over) return;
    const shape = getShape(state.current_piece, state.current_rotation);
    if (!checkCollision(shape, state.current_x + 1, state.current_y)) {
        state.current_x += 1;
    }
}

/// 方块顺时针旋转 90°，带墙踢（Wall Kick）
export fn tetris_rotate() void {
    if (state.game_over) return;

    const new_rotation: u8 = (state.current_rotation + 1) % 4;
    const new_shape = getShape(state.current_piece, new_rotation);

    // 直接旋转
    if (!checkCollision(new_shape, state.current_x, state.current_y)) {
        state.current_rotation = new_rotation;
        return;
    }

    // 墙踢：尝试左右偏移 [-1, +1, -2, +2]
    const kicks = [_]i16{ -1, 1, -2, 2 };
    for (kicks) |dx| {
        if (!checkCollision(new_shape, state.current_x + dx, state.current_y)) {
            state.current_x += dx;
            state.current_rotation = new_rotation;
            return;
        }
    }
}

/// 硬降：方块直接落到底部
export fn tetris_hard_drop() void {
    if (state.game_over) return;

    const shape = getShape(state.current_piece, state.current_rotation);

    // 不断下移直到碰撞
    while (!checkCollision(shape, state.current_x, state.current_y + 1)) {
        state.current_y += 1;
    }

    lockPiece(shape);
    _ = clearLines();

    state.current_piece = state.next_piece;
    state.next_piece = randomPiece();
    spawnPiece();
}

/// 获取棋盘指针（10×20=200 字节）。
/// JS 端通过 WASM memory 读取：每个字节 0=空，1-7=颜色索引
export fn tetris_get_board() [*]u8 {
    return &state.board;
}

/// 获取当前下落中方块信息，打包为 u32：piece(bit0-7) | rot(8-15) | x(16-23) | y(24-31)
export fn tetris_get_piece_info() u32 {
    const xu: u8 = @bitCast(@as(i8, @intCast(state.current_x)));
    const yu: u8 = @bitCast(@as(i8, @intCast(state.current_y)));
    return (@as(u32, state.current_piece)) |
        (@as(u32, state.current_rotation) << 8) |
        (@as(u32, xu) << 16) |
        (@as(u32, yu) << 24);
}

/// 获取当前分数
export fn tetris_get_score() u32 {
    return state.score;
}

/// 获取下一个方块类型（0-6），JS 用于预览
export fn tetris_get_next() u32 {
    return state.next_piece;
}

/// 游戏是否结束：返回 1（结束）或 0（进行中）
export fn tetris_is_game_over() u32 {
    return if (state.game_over) @as(u32, 1) else @as(u32, 0);
}
