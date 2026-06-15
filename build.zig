const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("null", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ── 原生可执行文件 ──
    const link_libc = target.result.os.tag == .windows;

    const exe = b.addExecutable(.{
        .name = "null",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
            .imports = &.{
                .{ .name = "null", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ═══════════════════════════════════════════════════════
    // 独立游戏可执行文件（可分发到其他电脑）
    // ═══════════════════════════════════════════════════════

    const games = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "snake", .desc = "贪吃蛇" },
        .{ .name = "tetris", .desc = "俄罗斯方块" },
        .{ .name = "game2048", .desc = "2048" },
        .{ .name = "life", .desc = "生命游戏" },
        .{ .name = "raytrace", .desc = "光线追踪" },
    };

    for (games) |game| {
        const game_exe = b.addExecutable(.{
            .name = game.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}/main.zig", .{game.name})),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
            }),
        });

        const install_step = b.addInstallArtifact(game_exe, .{});
        b.step(b.fmt("build-{s}", .{game.name}), b.fmt("Build {s} standalone", .{game.desc})).dependOn(&install_step.step);

        const run_cmd2 = b.addRunArtifact(game_exe);
        run_cmd2.step.dependOn(&install_step.step);
        b.step(b.fmt("run-{s}", .{game.name}), b.fmt("Run {s}", .{game.desc})).dependOn(&run_cmd2.step);
    }

    // ═══════════════════════════════════════════════════════
    // WASM 游戏编译
    // ═══════════════════════════════════════════════════════

    const wasm_step = b.step("wasm", "Build all WASM games for web");

    const wasm_games = [_]struct { name: []const u8, exports: []const []const u8 }{
        .{ .name = "snake", .exports = &.{ "snake_init", "snake_step", "snake_set_direction", "snake_get_state", "snake_get_len", "snake_get_food", "snake_is_game_over", "snake_get_score", "snake_get_width", "snake_get_height" } },
        .{ .name = "tetris", .exports = &.{ "tetris_init", "tetris_step", "tetris_move_left", "tetris_move_right", "tetris_rotate", "tetris_hard_drop", "tetris_get_board", "tetris_get_piece_info", "tetris_get_score", "tetris_get_next", "tetris_is_game_over" } },
        .{ .name = "game2048", .exports = &.{ "game2048_init", "game2048_move", "game2048_get_grid", "game2048_get_score", "game2048_is_game_over", "game2048_has_won" } },
        .{ .name = "life", .exports = &.{ "life_init", "life_step", "life_get_grid", "life_get_width", "life_get_height", "life_get_generation", "life_toggle", "life_randomize" } },
        .{ .name = "raytrace", .exports = &.{ "raytrace_render", "raytrace_get_pixels", "raytrace_get_width", "raytrace_get_height", "raytrace_is_done" } },
    };

    for (wasm_games) |game| {
        // 构建参数列表：调用 zig build-exe 编译 freestanding WASM
        var args = std.ArrayList([]const u8).initCapacity(b.allocator, 32) catch @panic("OOM");
        args.appendSlice(b.allocator, &.{ b.graph.zig_exe, "build-exe", b.fmt("src/{s}/wasm.zig", .{game.name}), "--name", game.name, "-target", "wasm32-freestanding", "-fno-entry", "-OReleaseSmall" }) catch @panic("OOM");
        for (game.exports) |exp| {
            args.append(b.allocator, b.fmt("--export={s}", .{exp})) catch @panic("OOM");
        }

        const cmd = b.addSystemCommand(args.items);
        const install = b.addInstallFile(b.path(b.fmt("{s}.wasm", .{game.name})), b.fmt("www/wasm/{s}.wasm", .{game.name}));
        install.step.dependOn(&cmd.step);
        wasm_step.dependOn(&install.step);
    }

    // 复制 HTML
    const install_html = b.addInstallFile(b.path("www/index.html"), "www/index.html");
    wasm_step.dependOn(&install_html.step);
}
