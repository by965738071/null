//! Brainfuck 解释器 —— 极简图灵完备语言的完整实现。
//!
//! ## Brainfuck 指令集（8 个指令）
//!
//! | 指令 | 含义 |
//! |------|------|
//! | `>`  | 数据指针右移（越界回绕） |
//! | `<`  | 数据指针左移（越界回绕） |
//! | `+`  | 当前单元格值 +1（溢出回绕） |
//! | `-`  | 当前单元格值 -1（溢出回绕） |
//! | `.`  | 输出当前单元格（ASCII 字符） |
//! | `,`  | 读取一个字节存入当前单元格 |
//! | `[`  | 若当前单元格为 0，跳到匹配的 `]` 之后 |
//! | `]`  | 若当前单元格非 0，跳回匹配的 `[` 之后 |
//!
//! ## 用法示例
//!
//! ```zig
//! const bf = @import("brainfuck.zig");
//!
//! const code = "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>." ++
//!              ">---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.";
//!
//! var input: std.Io.Reader = .fixed("");
//! var out: std.Io.Writer.Allocating = .init(gpa);
//! defer out.deinit();
//!
//! try bf.interpret(code, input, &out.writer);
//! // out.written() == "Hello World!\n"
//! ```

const std = @import("std");

/// Brainfuck 标准规范：30000 个字节的内存带。
const TAPE_SIZE = 30000;

/// 执行 Brainfuck 代码。
///
/// 参数说明：
/// - `code`:   Brainfuck 源代码。只有 8 个指令字符被处理（`> < + - . , [ ]`），
///             其余字符（空格、换行、注释等）自动忽略。
/// - `reader`: 输入源，需要实现 `take(1) ![]const u8` 语义（如 `std.Io.Reader`）。
/// - `writer`: 输出目标，需要实现 `writeByte(u8) !void` 语义（如 `std.Io.Writer`）。
///
/// 错误类型：
/// - `error.UnmatchedBracket`：括号不匹配（`[` 多于 `]`，或反之）。
/// - 由 `reader.take()` 或 `writer.writeByte()` 抛出的任何 I/O 错误也会向上传播。
pub fn interpret(code: []const u8, reader: anytype, writer: anytype) !void {
    // ═══ 内存带：30000 个单元格，全部初始化为 0 ═══
    var tape: [TAPE_SIZE]u8 = undefined;
    @memset(&tape, 0);
    var ptr: usize = 0; // 数据指针（当前操作哪个单元格）

    var ip: usize = 0; // 指令指针（当前执行到代码的哪个位置）
    while (ip < code.len) : (ip += 1) {
        switch (code[ip]) {
            // ── `>` 数据指针右移 ──
            // 越界回绕到 0（标准 Brainfuck 行为）
            '>' => {
                ptr += 1;
                if (ptr >= TAPE_SIZE) ptr = 0;
            },

            // ── `<` 数据指针左移 ──
            // 越界回绕到 TAPE_SIZE - 1
            '<' => {
                if (ptr == 0) {
                    ptr = TAPE_SIZE - 1;
                } else {
                    ptr -= 1;
                }
            },

            // ── `+` 当前单元格值 +1 ──
            // 使用 +%=（溢出回绕），255 + 1 → 0
            '+' => tape[ptr] +%= 1,

            // ── `-` 当前单元格值 -1 ──
            // 使用 -%=（溢出回绕），0 - 1 → 255
            '-' => tape[ptr] -%= 1,

            // ── `.` 输出当前单元格 ──
            // 将当前单元格的值作为 ASCII 字符输出
            '.' => try writer.writeByte(tape[ptr]),

            // ── `,` 读取一个字节 ──
            // 从输入读取一个字节，存入当前单元格
            ',' => tape[ptr] = (try reader.take(1))[0],

            // ── `[` 循环开始 ──
            // 若当前单元格为 0，跳过整个循环体（找到匹配的 `]`）
            '[' => {
                if (tape[ptr] == 0) {
                    ip = try skipForward(code, ip);
                }
            },

            // ── `]` 循环结束 ──
            // 若当前单元格非 0，跳回循环开头（找到匹配的 `[`）
            ']' => {
                if (tape[ptr] != 0) {
                    ip = try skipBackward(code, ip);
                }
            },

            // ── 其他字符 ──
            // 所有非指令字符（空格、换行、字母等）都当作注释忽略
            else => {},
        }
    }
}

/// 从当前位置向前扫描，找到匹配的 `]`。
/// 正确处理嵌套：遇到 `[` 深度+1，遇到 `]` 深度-1，深度归零时返回 `]` 所在位置。
///
/// 调用方在返回后会执行 `ip += 1`，因此最终 ip 指向 `]` 的下一个字符，
/// 即跳过了整个循环体。
fn skipForward(code: []const u8, ip: usize) !usize {
    var depth: usize = 1;
    var pos: usize = ip;
    while (depth > 0) {
        pos += 1;
        if (pos >= code.len) return error.UnmatchedBracket;
        switch (code[pos]) {
            '[' => depth += 1,
            ']' => depth -= 1,
            else => {},
        }
    }
    return pos; // 指向匹配的 `]`
}

/// 从当前位置向后扫描，找到匹配的 `[`。
/// 正确处理嵌套：遇到 `]` 深度+1，遇到 `[` 深度-1，深度归零时返回 `[` 所在位置。
///
/// 调用方在返回后会执行 `ip += 1`，因此最终 ip 指向 `[` 的下一个字符，
/// 即循环体的第一条指令，实现"跳回循环开头"的效果。
fn skipBackward(code: []const u8, ip: usize) !usize {
    var depth: usize = 1;
    var pos: usize = ip;
    while (depth > 0) {
        if (pos == 0) return error.UnmatchedBracket;
        pos -= 1;
        switch (code[pos]) {
            ']' => depth += 1,
            '[' => depth -= 1,
            else => {},
        }
    }
    return pos; // 指向匹配的 `[`
}

// ═══════════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════════

test "helloWorld" {
    // 经典的 Brainfuck "Hello World!" 程序
    // 用嵌套循环在内存带中构造 ASCII 码，然后逐个输出字符
    const hello_code =
        "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>." ++
        ">---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.";

    const gpa = std.testing.allocator;

    // 用 Io.Writer.Allocating 捕获输出到内存
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // 输入源：hello world 不需要读取输入，给一个空切片
    const input: std.Io.Reader = .fixed("");

    try interpret(hello_code, input, &out.writer);

    // 验证输出
    const result = out.written();
    try std.testing.expectEqualStrings("Hello World!\n", result);
}

test "echo: read one byte and output it" {
    // 最简单的交互程序：读一个字节，原样输出
    const echo_code = ",.";

    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // 提供输入 "A"
    const input: std.Io.Reader = .fixed("A");

    try interpret(echo_code, input, &out.writer);

    try std.testing.expectEqualStrings("A", out.written());
}

test "add two numbers" {
    // 读取两个字节，把它们相加后输出
    // ,>, 读取两个数到 cell#0 和 cell#1
    // [-<+>] 把 cell#1 的值加到 cell#0（同时 cell#1 清零）
    // <. 移回 cell#0 并输出结果
    const add_code = ",>,[-<+>]<.";

    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // \x03 + \x04 = \x07 (ASCII BEL, 不可见但值是 7)
    const input: std.Io.Reader = .fixed(&[_]u8{ 3, 4 });

    try interpret(add_code, input, &out.writer);

    try std.testing.expectEqual(@as(u8, 7), out.written()[0]);
}

test "nested loops" {
    // 测试嵌套循环的正确性：使用双重循环在 cell#2 中累积 3×4 = 12
    // 外循环 3 次（cell#0=3），内循环 4 次（cell#1=4），每次给 cell#2 加 1
    const multiply_code = "+++[>++++[>+<-]<-]>>.";

    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const input: std.Io.Reader = .fixed("");

    try interpret(multiply_code, input, &out.writer);

    try std.testing.expectEqual(@as(u8, 12), out.written()[0]);
}

test "unmatched bracket: extra [" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const input: std.Io.Reader = .fixed("");

    // 多了一个 [，没有对应的 ]
    try std.testing.expectError(
        error.UnmatchedBracket,
        interpret("+++[>+++.<", input, &out.writer),
    );
}

test "unmatched bracket: extra ]" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const input: std.Io.Reader = .fixed("");

    // 多了一个 ]，没有对应的 [
    try std.testing.expectError(
        error.UnmatchedBracket,
        interpret("+++>+++.<]", input, &out.writer),
    );
}

test "cell overflow" {
    // 验证 8 位溢出回绕：255 + 1 → 0（使用 +%= 溢出运算）
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const input: std.Io.Reader = .fixed("");

    // 构造 256 个 '+' 指令：填满一个 u8 后再加 1，溢出回绕到 0
    var code_buf: [512]u8 = undefined;
    @memset(code_buf[0..255], '+');
    code_buf[255] = '+'; // 第 256 个 +，使 255 + 1 → 0
    code_buf[256] = '.';
    const code = code_buf[0..257];

    try interpret(code, input, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), out.written()[0]);
}
