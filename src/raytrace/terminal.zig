//! PPM 格式光线追踪器
//!
//! 功能：
//! - 输出 PPM P3 格式彩色图片到 stdout
//! - 3 个彩色球体 + 1 个地面平面
//! - Lambertian 漫反射光照 + 简单阴影
//! - 相机在 (0,0,0)，看向 (0,0,-1)
//! - 分辨率 640×480（兼顾速度与效果）
//!
//! 用法：zig build run -- raytrace > output.ppm

const std = @import("std");
const math = std.math;

/// 三维向量，使用 f64 精度
const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    /// 向量加法
    fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    /// 向量减法
    fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    /// 标量乘法
    fn scale(self: Vec3, s: f64) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    /// 点积（内积）
    fn dot(self: Vec3, other: Vec3) f64 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    /// 向量长度（模）
    fn length(self: Vec3) f64 {
        return math.sqrt(self.dot(self));
    }

    /// 返回归一化后的单位向量（长度为 1）
    fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0) return self;
        return self.scale(1.0 / len);
    }
};

/// 球体
const Sphere = struct {
    center: Vec3, // 球心坐标
    radius: f64, // 半径
    color: Vec3, // 颜色 (RGB，各分量范围 0~1)
};

/// 无限大平面
const Plane = struct {
    point: Vec3, // 平面上一点
    normal: Vec3, // 平面法线（应已归一化）
    color: Vec3, // 颜色 (RGB，各分量范围 0~1)
};

/// 光线与物体的交点信息
const Hit = struct {
    t: f64, // 从光线原点到交点的距离
    point: Vec3, // 交点世界坐标
    normal: Vec3, // 交点处的表面法线（指向外侧）
    color: Vec3, // 物体颜色
};

/// 检测光线与球体的交点。
/// 返回最近的交点距离 t，若无交点则返回 null。
fn intersectSphere(origin: Vec3, dir: Vec3, sphere: Sphere) ?f64 {
    // 射线方程：P = O + t*D
    // 球方程：|P - C|² = r²
    // 代入：|O + t*D - C|² = r²
    // 令 oc = O - C，则：|oc + t*D|² = r²
    // 展开：t²(D·D) + 2t(oc·D) + (oc·oc - r²) = 0
    const oc = origin.sub(sphere.center);

    const a = dir.dot(dir); // 对于归一化方向，a = 1
    const b = 2.0 * oc.dot(dir);
    const c = oc.dot(oc) - sphere.radius * sphere.radius;

    const discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0) return null; // 无交点

    const sqrt_d = math.sqrt(discriminant);
    const t1 = (-b - sqrt_d) / (2.0 * a);
    const t2 = (-b + sqrt_d) / (2.0 * a);

    // 返回最近的正 t 值
    if (t1 > 0.001) return t1;
    if (t2 > 0.001) return t2;
    return null; // 交点在光线后面或太近
}

/// 检测光线与平面的交点。
/// 返回交点距离 t，若无交点则返回 null。
fn intersectPlane(origin: Vec3, dir: Vec3, plane: Plane) ?f64 {
    // 平面方程：(P - P₀)·N = 0
    // 代入射线： (O + t*D - P₀)·N = 0
    // 解得：t = (P₀ - O)·N / (D·N)
    const denom = dir.dot(plane.normal);

    // 光线平行于平面（或几乎平行）
    if (@abs(denom) < 0.0001) return null;

    const t = plane.point.sub(origin).dot(plane.normal) / denom;
    if (t > 0.001) return t;
    return null; // 交点在光线后面
}

/// 找到光线与场景中所有物体最近的交点。
fn findClosestHit(
    origin: Vec3,
    dir: Vec3,
    spheres: []const Sphere,
    ground: Plane,
) ?Hit {
    var closest: ?Hit = null;

    // 检测所有球体
    for (spheres) |sphere| {
        if (intersectSphere(origin, dir, sphere)) |t| {
            if (closest == null or t < closest.?.t) {
                const point = origin.add(dir.scale(t));
                // 球体法线：从球心指向交点
                const normal = point.sub(sphere.center).normalize();
                closest = Hit{ .t = t, .point = point, .normal = normal, .color = sphere.color };
            }
        }
    }

    // 检测地面平面
    if (intersectPlane(origin, dir, ground)) |t| {
        if (closest == null or t < closest.?.t) {
            const point = origin.add(dir.scale(t));
            closest = Hit{ .t = t, .point = point, .normal = ground.normal, .color = ground.color };
        }
    }

    return closest;
}

/// 检测从 origin 到 light_pos 之间是否有物体遮挡。
fn isInShadow(
    origin: Vec3,
    normal: Vec3,
    light_pos: Vec3,
    spheres: []const Sphere,
    ground: Plane,
) bool {
    const light_dir = light_pos.sub(origin).normalize();
    const light_dist = light_pos.sub(origin).length();

    // 从交点沿法线方向略微偏移，避免自交
    const shadow_origin = origin.add(normal.scale(0.001));

    // 检测球体遮挡
    for (spheres) |sphere| {
        if (intersectSphere(shadow_origin, light_dir, sphere)) |t| {
            if (t < light_dist) return true;
        }
    }

    // 检测地面遮挡
    if (intersectPlane(shadow_origin, light_dir, ground)) |t| {
        if (t < light_dist) return true;
    }

    return false;
}

/// 光线追踪入口函数。
///
/// 渲染 800×600 的 PPM P3 格式图像，输出到 stdout。
/// allocator 参数保留以备将来扩展，当前实现不分配堆内存。
pub fn render(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = allocator; // 当前实现不需要动态分配

    const width: usize = 640;
    const height: usize = 480;
    const aspect: f64 = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));

    // ═══════════════════════════════════════════════════════
    // 定义场景
    // ═══════════════════════════════════════════════════════

    // 光源位置（点光源，位于场景右上方）
    const light_pos = Vec3{ .x = 5, .y = 8, .z = 3 };

    // 3 个彩色球体
    const spheres = [_]Sphere{
        // 红色球体 —— 中间偏上
        .{ .center = Vec3{ .x = 0, .y = 0.8, .z = -5 }, .radius = 1.0, .color = Vec3{ .x = 1.0, .y = 0.2, .z = 0.2 } },
        // 绿色球体 —— 左侧
        .{ .center = Vec3{ .x = -2.5, .y = 0.1, .z = -4.5 }, .radius = 0.9, .color = Vec3{ .x = 0.2, .y = 1.0, .z = 0.3 } },
        // 蓝色球体 —— 右侧偏前
        .{ .center = Vec3{ .x = 2.5, .y = -0.1, .z = -3.8 }, .radius = 0.75, .color = Vec3{ .x = 0.2, .y = 0.3, .z = 1.0 } },
    };

    // 灰色地面平面（法线朝上）
    const ground = Plane{
        .point = Vec3{ .x = 0, .y = -1, .z = 0 },
        .normal = Vec3{ .x = 0, .y = 1, .z = 0 },
        .color = Vec3{ .x = 0.75, .y = 0.75, .z = 0.75 },
    };

    // ═══════════════════════════════════════════════════════
    // 初始化 stdout 写入器
    // ═══════════════════════════════════════════════════════

    // Io.File.Writer 是带缓冲的文件写入器，init 的三个参数分别是：
    //   1. 文件句柄（.stdout() 获取标准输出）
    //   2. Io 实例（来自 main 的 init.io）
    //   3. 内部缓冲区
    var stdout_buf: [8192]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);

    // ═══════════════════════════════════════════════════════
    // 写入 PPM P3 头部
    // ═══════════════════════════════════════════════════════
    // P3 格式：ASCII 编码的 RGB 值
    // 头部格式："P3\n<width> <height>\n<max_color>\n"
    try w.interface.print("P3\n{d} {d}\n255\n", .{ width, height });

    // ═══════════════════════════════════════════════════════
    // 逐像素光线追踪
    // ═══════════════════════════════════════════════════════
    // 从左上角开始，逐行向下扫描
    var j: usize = 0;
    while (j < height) : (j += 1) {
        var i: usize = 0;
        while (i < width) : (i += 1) {
            // ── 计算光线方向 ──
            // 将像素坐标映射到 [-1, 1] 区间
            // u 水平方向，v 垂直方向（翻转 y 轴以匹配图像坐标系）
            const u = (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(width)) * 2.0 - 1.0;
            const v = (@as(f64, @floatFromInt(j)) + 0.5) / @as(f64, @floatFromInt(height)) * 2.0 - 1.0;

            // 射线从相机原点 (0,0,0) 出发，指向像素位置
            const dir_raw = Vec3{
                .x = u * aspect,
                .y = -v, // 翻转 y（屏幕坐标 y 向下，世界坐标 y 向上）
                .z = -1,
            };
            const dir = dir_raw.normalize();

            const origin = Vec3{ .x = 0, .y = 0, .z = 0 };

            // ── 找最近的交点 ──
            const hit = findClosestHit(origin, dir, &spheres, ground);

            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;

            if (hit) |h| {
                // ── Lambertian 漫反射光照 ──
                const light_dir = light_pos.sub(h.point).normalize();
                // 法线与光线方向的点积 → 漫反射强度（clamp 到 >= 0）
                const diffuse = @max(0.0, h.normal.dot(light_dir));

                // ── 阴影检测 ──
                const in_shadow = isInShadow(h.point, h.normal, light_pos, &spheres, ground);

                // ── 计算最终颜色 ──
                // 环境光：保证阴影区域不是全黑
                const ambient: f64 = 0.12;
                // 阴影中只用环境光，非阴影用漫反射+环境光
                const light_factor: f64 = if (in_shadow) ambient else diffuse + ambient;

                // 钳制颜色到 [0, 1] 范围后转为 u8
                const fc = h.color.scale(light_factor);
                r = @intFromFloat(@min(255.0, @max(0.0, fc.x * 255.0)));
                g = @intFromFloat(@min(255.0, @max(0.0, fc.y * 255.0)));
                b = @intFromFloat(@min(255.0, @max(0.0, fc.z * 255.0)));
            }

            // 写入单个像素的 RGB 值（PPM 格式每个通道用空格分隔）
            try w.interface.print("{d} {d} {d} ", .{ r, g, b });
        }

        // 每行结束换行
        try w.interface.print("\n", .{});

        // 每 20 行刷新一次缓冲区（既看到进度，又不影响性能太多）
        if (j % 20 == 0) {
            try w.flush();
        }
    }

    // 确保所有数据写出
    try w.flush();
}

// ═══════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════

test "Vec3 向量运算" {
    const a = Vec3{ .x = 1, .y = 2, .z = 3 };
    const b = Vec3{ .x = 4, .y = 5, .z = 6 };

    // 加法：a + b = (5, 7, 9)
    const sum = a.add(b);
    try std.testing.expectEqual(@as(f64, 5), sum.x);
    try std.testing.expectEqual(@as(f64, 7), sum.y);
    try std.testing.expectEqual(@as(f64, 9), sum.z);

    // 减法：a - a = (0, 0, 0)
    const zero = a.sub(a);
    try std.testing.expectEqual(@as(f64, 0), zero.x);
    try std.testing.expectEqual(@as(f64, 0), zero.y);
    try std.testing.expectEqual(@as(f64, 0), zero.z);

    // 标量乘法：a * 2 = (2, 4, 6)
    const doubled = a.scale(2);
    try std.testing.expectEqual(@as(f64, 2), doubled.x);
    try std.testing.expectEqual(@as(f64, 4), doubled.y);
    try std.testing.expectEqual(@as(f64, 6), doubled.z);

    // 点积：1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    const d = a.dot(b);
    try std.testing.expectEqual(@as(f64, 32), d);

    // 长度：sqrt(1² + 2² + 3²) = sqrt(14) ≈ 3.74166
    const len = a.length();
    try std.testing.expectApproxEqRel(@as(f64, 3.7416573867739413), len, 0.0001);

    // 归一化：归一化后长度应为 1
    const n = a.normalize();
    try std.testing.expectApproxEqRel(@as(f64, 1.0), n.length(), 0.0001);

    // 归一化结果的各分量验证：a/sqrt(14)
    try std.testing.expectApproxEqRel(@as(f64, 1.0 / 3.7416573867739413), n.x, 0.0001);
    try std.testing.expectApproxEqRel(@as(f64, 2.0 / 3.7416573867739413), n.y, 0.0001);
    try std.testing.expectApproxEqRel(@as(f64, 3.0 / 3.7416573867739413), n.z, 0.0001);
}
