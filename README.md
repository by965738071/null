# 🧪 Null — Zig 练手项目集合

用 [Zig](https://ziglang.org/) 写的多合一终端游戏 + WebAssembly 项目。

```
null/
├── src/
│   ├── input.zig          ← 跨平台终端输入抽象（Posix / Windows）
│   ├── arena.zig          ← Arena 分配器
│   ├── brainfuck.zig      ← Brainfuck 解释器
│   ├── root.zig           ← 模块入口
│   ├── main.zig           ← CLI 入口
│   ├── snake/             ← 🐍 贪吃蛇
│   ├── tetris/            ← 🧱 俄罗斯方块
│   ├── game2048/          ← 🔢 2048
│   ├── life/              ← 🧬 生命游戏
│   └── raytrace/          ← 🎨 光线追踪
├── www/                   ← Web 前端（HTML + Canvas）
└── build.zig              ← 构建脚本
```

---

## 快速开始

### 依赖

- **[Zig](https://ziglang.org/download/)** ≥ 0.17.0-dev（需要 `std.Io` 新 API）

### 运行终端游戏

```bash
zig build run -- snake      # 贪吃蛇
zig build run -- tetris     # 俄罗斯方块
zig build run -- 2048       # 2048
zig build run -- life       # 生命游戏
zig build run -- raytrace   # 光线追踪（输出 PPM 图片到 stdout）
zig build run -- arena      # Arena 分配器演示
```

不带参数显示帮助菜单：

```bash
zig build run
# ╔══════════════════════════════════════════╗
# ║       🧪 Zig 练手项目                   ║
# ╠══════════════════════════════════════════╣
# ║  snake    →  🐍 贪吃蛇                  ║
# ║  tetris   →  🧱 俄罗斯方块              ║
# ║  2048     →  🔢 2048                    ║
# ║  life     →  🧬 生命游戏                ║
# ║  raytrace →  🎨 光线追踪 (stdout)       ║
# ║  arena    →  📦 Arena 分配器            ║
# ╚══════════════════════════════════════════╝
```

### 构建独立可执行文件

```bash
zig build build-snake      # 贪吃蛇独立 exe
zig build build-tetris     # 俄罗斯方块独立 exe
zig build build-game2048   # 2048 独立 exe
zig build build-life       # 生命游戏独立 exe
zig build build-raytrace   # 光线追踪独立 exe
```

产物在 `zig-out/bin/` 下，可直接复制到其他电脑运行。

### 构建 Web（WASM）

```bash
zig build wasm
# 产物在 www/wasm/ 下
# 用任意静态服务器打开 www/index.html
```

---

## 项目架构

### 公共模块

| 模块 | 文件 | 说明 |
|------|------|------|
| 终端输入 | `src/input.zig` | 跨平台 raw 模式终端 + 按键解码。编译期根据目标平台选择 Posix（termios）或 Windows（kernel32 FFI）实现。**所有游戏共享此模块**。 |
| Arena 分配器 | `src/arena.zig` | 自定义 Bump Allocator，链表式节点管理，支持 `reset()`。实现了 `std.mem.Allocator` 接口。 |
| Brainfuck | `src/brainfuck.zig` | 完整 Brainfuck 解释器，支持嵌套循环、括号错误检测。30000 字节磁带 + 指针回绕。 |

### 游戏结构

每个游戏目录包含两个文件：

```
src/xxx/
├── terminal.zig    ← 终端版（ANSI escape code 渲染 + 键盘输入）
└── wasm.zig        ← WASM 导出层（零堆分配，固定大小数组，xorshift32 随机）
```

### WASM 设计

五个游戏的 WASM 层遵循统一设计原则：

- 全部使用**全局静态数组**，零堆分配，兼容 `wasm32-freestanding`
- `xorshift32` 轻量伪随机，不依赖 OS
- 导出函数遵循 `xxx_init` / `xxx_step` / `xxx_get_*` 命名约定
- 通过 `[*]u8` / `[*]u16` 指针暴露状态给 JavaScript，JS 通过 `Module.HEAPU8` 读取

---

## 测试

```bash
zig build test
```

包含：

- **input.zig**：ANSI 转义序列解码、普通字符、Escape 处理
- **brainfuck.zig**：Hello World、加法、嵌套循环、括号错误、溢出回绕
- **arena.zig**：基本分配、reset 重用、对齐、跨节点分配、resize
- **raytrace/terminal.zig**：Vec3 向量运算（加减乘除、点积、归一化）
- **life/terminal.zig**：blinker oscillator 演化规则验证
- **tetris/terminal.zig**：方块旋转、行消除
- **game2048/terminal.zig**：合并逻辑、滑动逻辑
- **snake/terminal.zig**：蛇移动、吃食物、撞墙、撞自己、防掉头

---

## 光线追踪输出

```bash
# 终端版 640×480 P3 格式 PPM，输出到 stdout
zig build run -- raytrace > output.ppm

# 用 Preview 或任意看图软件打开（macOS）
open output.ppm
```

WASM 版为 400×300，直接在 `www/index.html` 的 Canvas 上渲染。

---

## 跨平台

所有代码在 macOS / Windows / Linux 三个平台上编译通过。

| 目标 | 状态 |
|------|------|
| macOS arm64（本机） | ✅ |
| Windows x86_64 | ✅ |
| Linux x86_64 glibc | ✅ |
| Linux x86_64 musl | ✅ |

> **注意**：如果用 Homebrew 安装的 zig-dev，显式指定 macOS target 时需要软链 `libSystem.tbd`：
> ```bash
> ln -sf /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib/libSystem.tbd \
>   /opt/homebrew/Cellar/zig-dev/*/lib/zig/libc/darwin/libSystem.tbd
> ```
> 这只影响 Homebrew 安装的 zig-dev，官方二进制包不需要。

---

## 许可证

MIT
