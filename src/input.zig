//! 跨平台终端输入抽象层。
//!
//! 提供统一的「raw 模式终端 + 按键解码」接口，
//! 所有终端游戏共享此模块，消除重复代码。
//!
//! 使用方式：
//!   var term = try input.init();
//!   defer term.deinit();
//!   while (try term.readKey()) |key| { ... }

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

// ═══════════════════════════════════════════════════════════════════
// 公共接口
// ═══════════════════════════════════════════════════════════════════

/// 终端控制器 — 编译期根据平台选择实现。
pub const Terminal = if (is_windows) WindowsTerm else PosixTerm;

/// 统一按键枚举。游戏各自做 `fromCode(Key) ?GameKey` 转换。
pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    escape,
    char: u8,
};

// ═══════════════════════════════════════════════════════════════════
// POSIX 实现（macOS / Linux / BSD）
// ═══════════════════════════════════════════════════════════════════

const PosixTerm = struct {
    orig_termios: std.posix.termios,
    tty_fd: std.posix.fd_t,

    pub fn enterRawMode() !PosixTerm {
        const posix = std.posix;
        const fd = posix.STDIN_FILENO;

        const orig = try posix.tcgetattr(fd);

        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .NOW, raw);

        return PosixTerm{ .orig_termios = orig, .tty_fd = fd };
    }

    pub fn deinit(self: *const PosixTerm) void {
        std.posix.tcsetattr(self.tty_fd, .NOW, self.orig_termios) catch {};
    }

    pub fn readKey(self: *const PosixTerm) !?Key {
        const posix = std.posix;
        var buf: [8]u8 = undefined;
        const n = posix.read(self.tty_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (n == 0) return null;
        return decodeKey(&buf, n);
    }
};

// ═══════════════════════════════════════════════════════════════════
// Windows 实现
// ═══════════════════════════════════════════════════════════════════

const win = struct {
    const H = *anyopaque;
    const D = u32;
    const STD_OUT: D = @bitCast(@as(i32, -11));
    extern "kernel32" fn GetStdHandle(D) callconv(.winapi) ?H;
    extern "kernel32" fn GetConsoleMode(H, *D) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(H, D) callconv(.winapi) i32;
    extern fn _kbhit() callconv(.c) i32;
    extern fn _getch() callconv(.c) i32;
    const VTP: D = 0x0004;
};

const WindowsTerm = struct {
    orig_stdout_mode: win.D,

    pub fn enterRawMode() !WindowsTerm {
        const stdout_handle = win.GetStdHandle(win.STD_OUT) orelse return error.Unexpected;

        var orig_mode: win.D = 0;
        if (win.GetConsoleMode(stdout_handle, &orig_mode) == 0) return error.Unexpected;

        const new_mode = orig_mode | win.VTP;
        _ = win.SetConsoleMode(stdout_handle, new_mode);

        return WindowsTerm{ .orig_stdout_mode = orig_mode };
    }

    pub fn deinit(self: *const WindowsTerm) void {
        const stdout_handle = win.GetStdHandle(win.STD_OUT) orelse return;
        _ = win.SetConsoleMode(stdout_handle, self.orig_stdout_mode);
    }

    pub fn readKey(_: *const WindowsTerm) !?Key {
        if (win._kbhit() == 0) return null;

        const first = win._getch();

        if (first == 0 or first == 0xE0) {
            const second = win._getch();
            return switch (second) {
                0x48 => Key.up,
                0x50 => Key.down,
                0x4B => Key.left,
                0x4D => Key.right,
                else => null,
            };
        }

        var buf: [1]u8 = .{@intCast(first)};
        return decodeKey(&buf, 1);
    }
};

// ═══════════════════════════════════════════════════════════════════
// 按键解码（平台无关）
// ═══════════════════════════════════════════════════════════════════

fn decodeKey(buf: []const u8, n: usize) ?Key {
    if (n >= 3 and buf[0] == '\x1b' and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => Key.up,
            'B' => Key.down,
            'C' => Key.right,
            'D' => Key.left,
            else => null,
        };
    }

    return switch (buf[0]) {
        '\r', '\n' => Key.enter,
        '\x1b' => Key.escape,
        else => Key{ .char = buf[0] },
    };
}

// ═══════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════

test "decode ANSI escape sequence" {
    try std.testing.expectEqual(Key.up, decodeKey(&[_]u8{ '\x1b', '[', 'A' }, 3));
    try std.testing.expectEqual(Key.down, decodeKey(&[_]u8{ '\x1b', '[', 'B' }, 3));
    try std.testing.expectEqual(Key.right, decodeKey(&[_]u8{ '\x1b', '[', 'C' }, 3));
    try std.testing.expectEqual(Key.left, decodeKey(&[_]u8{ '\x1b', '[', 'D' }, 3));
}

test "decode plain characters" {
    try std.testing.expectEqual(Key.enter, decodeKey(&[_]u8{'\r'}, 1));
    try std.testing.expectEqual(Key{ .char = 'w' }, decodeKey(&[_]u8{'w'}, 1));
    try std.testing.expectEqual(Key{ .char = 'q' }, decodeKey(&[_]u8{'q'}, 1));
}

test "decode escape alone" {
    try std.testing.expectEqual(Key.escape, decodeKey(&[_]u8{'\x1b'}, 1));
}

test "unknown sequences return null" {
    try std.testing.expectEqual(@as(?Key, null), decodeKey(&[_]u8{ '\x1b', '[', 'X' }, 3));
}
