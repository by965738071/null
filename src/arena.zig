//! 从零手写的 Arena Allocator，帮助你彻底搞懂 Zig 的内存模型。
//!
//! ## Arena 分配器的核心思想
//!
//! Arena（竞技场/区域）分配器是最简单的内存分配策略之一：
//! - 它维护一个大块内存，每次分配只是把「水龙头」往前推（bump allocator）
//! - 不单独释放单个分配，而是整体重置（类似「推土机」）
//! - 适合：请求生命周期、帧分配、编译器前端、短期批量操作
//!
//! ## 关键概念
//!
//! 1. **Bump Allocation**：维护一个 offset，分配时 offset += size，O(1) 极快
//! 2. **对齐 (Alignment)**：分配的地址必须是对齐值的倍数，可能需要填充字节
//! 3. **Backing Allocator**：底层真正向 OS 申请内存的分配器（如 page_allocator）
//! 4. **Reset**：保留第一个节点，释放后续节点，所有之前的分配「失效」
//! 5. **多节点链表**：当前节点满了自动分配新节点，所有分配都可以成功（除非底层 OOM）
//!
//! ## 和 std.heap.ArenaAllocator 的区别
//!
//! - std 版本：支持线程安全、retain_capacity / free_all 两种 reset 模式
//! - 这个版本：多节点链表，reset 释放后续节点只保留首节点，更简单但够教学
//!
//! ```zig
//! // 用法示例：
//! var arena = try Arena.init(std.heap.page_allocator, null);
//! defer arena.deinit();
//!
//! const allocator = arena.allocator();
//! const buf = try allocator.alloc(u8, 100);
//! const list = try std.ArrayList(u8).initCapacity(allocator, 10);
//! // ... 用完之后 ...
//! arena.reset(); // 所有分配一次性失效，可重新使用
//! ```

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

/// 链表节点：每个节点持有一块内存缓冲区。
/// 所有分配在当前节点内进行；当前节点满了就创建新节点。
const Node = struct {
    /// 当前节点的内存缓冲区
    buf: []u8,
    /// 已分配到的位置（bump offset）
    offset: usize,
    /// 下一个节点（链表指针）
    next: ?*Node,
};

/// 多节点链表 Arena Allocator。
/// 当当前节点的空间不足时，自动从 backing_allocator 分配新节点并链接到链表。
/// reset 会释放除第一个节点外的所有节点，并将第一个节点的 offset 归零。
pub const Arena = struct {
    /// 底层分配器，用于获取和释放原始内存
    backing_allocator: mem.Allocator,
    /// 每个节点的缓冲区大小
    node_size: usize,
    /// 链表的头节点
    head: ?*Node,
    /// 当前正在使用的节点（分配总是从这里开始尝试）
    current: ?*Node,

    /// 允许的最大单一节点大小，默认 64 KiB
    pub const default_node_size: usize = 65536;

    /// 创建一个 Arena，预分配第一个节点。
    /// `backing_allocator` 是底层分配器（如 page_allocator、测试分配器等）。
    /// `node_size` 是每个节点缓冲区大小，可选，默认 64 KiB。
    pub fn init(backing_allocator: mem.Allocator, node_size: ?usize) !Arena {
        const size = node_size orelse default_node_size;
        const node = try backing_allocator.create(Node);
        errdefer backing_allocator.destroy(node);
        const buf = try backing_allocator.alloc(u8, size);
        node.* = .{ .buf = buf, .offset = 0, .next = null };
        return Arena{
            .backing_allocator = backing_allocator,
            .node_size = size,
            .head = node,
            .current = node,
        };
    }

    /// 释放所有节点的底层内存。调用此方法后 arena 不能再用。
    pub fn deinit(self: *Arena) void {
        var node: ?*Node = self.head;
        while (node) |n| {
            const next = n.next;
            self.backing_allocator.free(n.buf);
            self.backing_allocator.destroy(n);
            node = next;
        }
        self.head = null;
        self.current = null;
    }

    /// 返回一个 std.mem.Allocator 接口，可以传给任何需要分配器的函数。
    pub fn allocator(self: *Arena) mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// 重置 arena：保留第一个节点，释放后续所有节点，
    /// 并将第一个节点的 offset 归零。
    /// 所有之前的分配全部「失效」，内存可重新使用。
    /// 保留第一个节点避免了完全释放后重新分配的开销。
    pub fn reset(self: *Arena) void {
        if (self.head) |head_node| {
            // 释放第一个节点之后的所有节点
            var node: ?*Node = head_node.next;
            head_node.next = null;
            while (node) |n| {
                const next = n.next;
                self.backing_allocator.free(n.buf);
                self.backing_allocator.destroy(n);
                node = next;
            }
            // 重置第一个节点的 offset
            head_node.offset = 0;
        }
        // 重置后从第一个节点重新开始分配
        self.current = self.head;
    }

    /// 返回当前所有节点已分配的字节总数。
    pub fn allocatedBytes(self: *const Arena) usize {
        var total: usize = 0;
        var node: ?*Node = self.head;
        while (node) |n| {
            total += n.offset;
            node = n.next;
        }
        return total;
    }

    /// 返回当前节点剩余可分配的字节数。
    /// 注意：这只是当前节点的剩余空间，arena 会自动分配新节点，
    /// 所以这个值不代表可分配的总上限。
    pub fn remainingBytes(self: *const Arena) usize {
        if (self.current) |cur| {
            return cur.buf.len - cur.offset;
        }
        return 0;
    }

    // ─── 分配新节点的辅助函数 ───

    /// 从 backing_allocator 分配一个新节点并链接到链表末尾。
    /// `min_size` 是新节点缓冲区的最小大小：正常分配用 node_size，
    /// 大分配（超过 node_size）用实际请求的大小。
    /// 返回 true 表示分配失败（底层 OOM）。
    fn allocNewNode(self: *Arena, min_size: usize) bool {
        const alloc_size = @max(min_size, self.node_size);
        const node = self.backing_allocator.create(Node) catch return true;
        const buf = self.backing_allocator.alloc(u8, alloc_size) catch {
            self.backing_allocator.destroy(node);
            return true;
        };
        node.* = .{ .buf = buf, .offset = 0, .next = null };

        if (self.current) |cur| {
            cur.next = node;
        } else {
            // 第一个节点（正常情况下只在 init 失败后的恢复场景出现）
            self.head = node;
        }
        self.current = node;
        return false;
    }

    // ─── 分配器虚函数实现 ───

    /// 核心分配逻辑：先尝试当前节点，不够就分配新节点。
    /// 正常分配使用标准节点大小；超过标准节点大小的请求会分配
    /// 一个足够大的节点来容纳（类似 std.heap.ArenaAllocator 的行为）。
    fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const align_bytes = alignment.toByteUnits();

        // 防御性检查：理论上 current 总是非 null（init 保证），
        // 但 deinit 后会置 null，这里兜底处理。
        if (self.current == null) {
            return null;
        }

        const cur = self.current.?;

        // 在当前节点中计算对齐后的偏移
        const aligned_offset = mem.alignForward(usize, cur.offset, align_bytes);
        const new_offset = aligned_offset + len;

        if (new_offset <= cur.buf.len) {
            // 当前节点空间足够，直接分配
            const ptr = cur.buf[aligned_offset..][0..len];
            cur.offset = new_offset;
            return ptr.ptr;
        }

        // 当前节点不够，尝试分配新节点。
        // 传入 len 作为最小大小：如果 len > node_size，新节点会分配更大的缓冲区。
        if (allocNewNode(self, len)) {
            return null; // 底层 OOM
        }

        // 在新节点上分配
        const new_cur = self.current.?;
        const new_aligned_offset = mem.alignForward(usize, new_cur.offset, align_bytes);
        const new_new_offset = new_aligned_offset + len;

        // 防御性检查：新节点缓冲区大小 >= len，理论上一定能容纳
        if (new_new_offset > new_cur.buf.len) {
            return null;
        }

        const ptr = new_cur.buf[new_aligned_offset..][0..len];
        new_cur.offset = new_new_offset;
        return ptr.ptr;
    }

    /// resize：如果能原地扩展就扩展，否则不变。
    /// 只在当前节点内尝试扩展（不会跨节点 resize）。
    fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        _ = log2_buf_align;
        const self: *Arena = @ptrCast(@alignCast(ctx));

        if (self.current == null) {
            return new_len <= buf.len;
        }

        const cur = self.current.?;

        // 检查这个 buf 是否是当前节点最后一个分配
        const buf_end = @intFromPtr(buf.ptr) + buf.len;
        const current_end = @intFromPtr(cur.buf.ptr) + cur.offset;
        if (buf_end != current_end) {
            // 不是最后一个分配，只能缩小不能扩大
            return new_len <= buf.len;
        }

        // 是最后一个分配 → 尝试扩大
        const new_offset = @intFromPtr(buf.ptr) + new_len - @intFromPtr(cur.buf.ptr);
        if (new_offset > cur.buf.len) {
            // 超出当前节点缓冲区
            if (new_len <= buf.len) {
                cur.offset = new_offset;
                return true;
            }
            return false;
        }

        cur.offset = new_offset;
        return true;
    }

    /// Arena 不单独释放内存，free 是空操作。
    fn free(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize) void {}

    /// Arena 不支持 remap。先尝试 resize，失败则返回 null。
    fn remap(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // 尝试原地 resize
        if (resize(ctx, memory, alignment, new_len, ret_addr)) {
            return memory.ptr;
        }
        return null;
    }

    /// 分配一个已对齐的切片，并用零填充。常用于需要零初始化的场景。
    pub fn allocZ(self: *Arena, comptime T: type, len: usize) ![]T {
        const buf = try self.allocator().alloc(T, len);
        @memset(buf, 0);
        return buf;
    }
};

// ─── 测试 ───

test "基本分配和释放" {
    var arena = try Arena.init(std.testing.allocator, 1024);
    defer arena.deinit();

    const a = arena.allocator();

    // 分配一些整数
    const nums = try a.alloc(i32, 3);
    nums[0] = 10;
    nums[1] = 20;
    nums[2] = 30;

    try std.testing.expectEqual(@as(i32, 10), nums[0]);
    try std.testing.expectEqual(@as(i32, 20), nums[1]);
    try std.testing.expectEqual(@as(i32, 30), nums[2]);
}

test "reset 后重用" {
    var arena = try Arena.init(std.testing.allocator, 1024);
    defer arena.deinit();

    const a = arena.allocator();

    // 第一轮分配
    const first = try a.alloc(u8, 500);
    @memset(first, 0xAA);
    try std.testing.expect(arena.allocatedBytes() >= 500);

    // reset 后 offset 归零
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.allocatedBytes());

    // 第二轮分配——可以正常使用
    const second = try a.alloc(u8, 800);
    @memset(second, 0xBB);
    try std.testing.expect(arena.allocatedBytes() >= 800);

    // 注意：first 指针现在指向被「回收」的内存，不应再使用！
    // 这就是 arena 的核心约定：由你保证在 reset 前不再访问旧指针。
}

test "对齐分配" {
    var arena = try Arena.init(std.testing.allocator, 1024);
    defer arena.deinit();

    const a = arena.allocator();

    // 分配一个 u8（对齐 1）来故意制造非对齐的 offset
    _ = try a.alloc(u8, 1);

    // 然后分配一个对齐要求 8 字节的 u64
    const aligned_val = try a.alloc(u64, 1);
    aligned_val[0] = 42;

    // 验证对齐正确
    const addr = @intFromPtr(&aligned_val[0]);
    try std.testing.expectEqual(@as(usize, 0), addr % @alignOf(u64));
    try std.testing.expectEqual(@as(u64, 42), aligned_val[0]);
}

test "超出容量返回 OutOfMemory" {
    // 使用 FixedBufferAllocator 模拟底层 OOM 场景。
    // 注意：多节点 Arena 本身不会因为单个节点满而 OOM，
    // 但底层分配器耗尽时会返回 OutOfMemory。
    var buf: [160]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var arena = try Arena.init(fba.allocator(), 64);
    defer arena.deinit();

    const a = arena.allocator();

    // 先分配一些数据（在 arena 内部，不触及 FBA）
    _ = try a.alloc(u8, 10);

    // 再尝试分配 100 字节 → 当前节点不够（64 字节），
    // arena 会尝试从 FBA 分配新节点，但 FBA 已耗尽 → 返回 OutOfMemory
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 100));
}

test "resize 最后一个分配" {
    var arena = try Arena.init(std.testing.allocator, 1024);
    defer arena.deinit();

    const a = arena.allocator();

    var list = try std.ArrayList(u8).initCapacity(a, 4);
    try list.appendSlice(a, &.{ 1, 2, 3, 4 });

    // 扩大
    try list.ensureTotalCapacity(a, 8);
    try list.appendSlice(a, &.{ 5, 6, 7, 8 });

    try std.testing.expectEqual(@as(usize, 8), list.items.len);
    try std.testing.expectEqual(@as(u8, 1), list.items[0]);
    try std.testing.expectEqual(@as(u8, 8), list.items[7]);
}

test "用 arena 模拟一个请求的生命周期" {
    // 模拟：处理一个 HTTP 请求，期间所有临时数据都用 arena 分配
    var arena = try Arena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    const a = arena.allocator();

    // 请求 1：解析 JSON body
    const body = try a.alloc(u8, 100);
    @memset(body, 0);
    const headers = try a.alloc(u8, 200);
    @memset(headers, 0);

    try std.testing.expect(arena.allocatedBytes() >= 300);

    // 请求处理完毕，reset
    arena.reset();

    // 请求 2：新一轮分配
    const body2 = try a.alloc(u8, 500);
    @memset(body2, 0);

    try std.testing.expect(arena.allocatedBytes() >= 500);
}

test "多节点分配" {
    // 使用小节点大小（32 字节），强制 arena 分配多个节点
    var arena = try Arena.init(std.testing.allocator, 32);
    defer arena.deinit();

    const a = arena.allocator();

    // 第一次分配：在当前节点内（30 字节刚好放入 32 字节节点）
    const a1 = try a.alloc(u8, 30);
    @memset(a1, 0x01);

    // 第二次分配：当前节点只剩 ~2 字节，不够放 u64（8 字节），触发新节点分配
    const a2 = try a.alloc(u64, 4);
    a2[0] = 42;
    a2[1] = 43;
    a2[2] = 44;
    a2[3] = 45;

    // 验证第一个节点的数据没有被破坏
    try std.testing.expectEqual(@as(u8, 0x01), a1[0]);
    try std.testing.expectEqual(@as(u8, 0x01), a1[29]);

    // 验证第二个节点的数据正确
    try std.testing.expectEqual(@as(u64, 42), a2[0]);
    try std.testing.expectEqual(@as(u64, 43), a2[1]);
    try std.testing.expectEqual(@as(u64, 44), a2[2]);
    try std.testing.expectEqual(@as(u64, 45), a2[3]);

    // allocatedBytes 应该跨节点统计
    try std.testing.expect(arena.allocatedBytes() >= 30 + 4 * @sizeOf(u64));
}

test "跨节点分配后数据正确" {
    // 使用 64 字节节点，让数据分布在多个节点上
    var arena = try Arena.init(std.testing.allocator, 64);
    defer arena.deinit();

    const a = arena.allocator();

    // 第一个节点：填入 50 字节
    const buf1 = try a.alloc(u8, 50);
    @memset(buf1, 0xAA);

    // 第二个节点：当前节点剩 ~14 字节，再分配 50 字节触发新节点
    const buf2 = try a.alloc(u8, 50);
    @memset(buf2, 0xBB);

    // 第三个节点：再分配 50 字节，可能需要第三个节点
    const buf3 = try a.alloc(u8, 50);
    @memset(buf3, 0xCC);

    // 验证三个节点的数据互不干扰
    for (buf1) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
    for (buf2) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);
    for (buf3) |b| try std.testing.expectEqual(@as(u8, 0xCC), b);

    // reset 后重新使用——验证跨节点重置
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.allocatedBytes());

    // reset 后可以正常分配（重用已有节点，不会 OOM）
    const buf4 = try a.alloc(u8, 120);
    @memset(buf4, 0xDD);

    try std.testing.expect(arena.allocatedBytes() >= 120);
    for (buf4) |b| try std.testing.expectEqual(@as(u8, 0xDD), b);
}
