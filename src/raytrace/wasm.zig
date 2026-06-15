//! 光线追踪 WASM 导出层。
//! 渲染 3 个彩色球体 + 地面到像素缓冲区，JS 读取后在 Canvas 显示。

const W = 400;
const H = 300;

const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,
    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    fn scale(a: Vec3, s: f64) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    fn length(a: Vec3) f64 {
        return @sqrt(a.dot(a));
    }
    fn normalize(a: Vec3) Vec3 {
        const l = a.length();
        return if (l > 0.0001) a.scale(1.0 / l) else a;
    }
};

const Sphere = struct { center: Vec3, radius: f64, color: Vec3 };
const Hit = struct { t: f64, point: Vec3, normal: Vec3, color: Vec3 };

var pixels: [W * H * 3]u8 = undefined; // WASM 全局内存默认零初始化
var rendered: bool = false;

const spheres = [_]Sphere{
    .{ .center = .{ .x = 0.0, .y = 0.5, .z = -5 }, .radius = 1.2, .color = .{ .x = 1.0, .y = 0.2, .z = 0.2 } }, // 红球 中间
    .{ .center = .{ .x = -2.5, .y = -0.2, .z = -4 }, .radius = 0.7, .color = .{ .x = 0.2, .y = 1.0, .z = 0.2 } }, // 绿球 左边
    .{ .center = .{ .x = 2.5, .y = 0.3, .z = -3.5 }, .radius = 0.9, .color = .{ .x = 0.2, .y = 0.4, .z = 1.0 } }, // 蓝球 右边
};
const light = Vec3{ .x = 6, .y = 8, .z = -1 };
const ambient: f64 = 0.15;

fn intersectSphere(ray_origin: Vec3, ray_dir: Vec3, sphere: Sphere) ?f64 {
    const oc = ray_origin.sub(sphere.center);
    const a = ray_dir.dot(ray_dir);
    const b = 2.0 * oc.dot(ray_dir);
    const c = oc.dot(oc) - sphere.radius * sphere.radius;
    const disc = b * b - 4.0 * a * c;
    if (disc < 0) return null;
    const t = (-b - @sqrt(disc)) / (2.0 * a);
    return if (t > 0.001) t else null;
}

fn intersectPlane(ray_origin: Vec3, ray_dir: Vec3) ?f64 {
    const n = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    const denom = ray_dir.dot(n);
    if (@abs(denom) < 0.0001) return null;
    const plane_point = Vec3{ .x = 0.0, .y = -1.0, .z = 0.0 };
    const t = plane_point.sub(ray_origin).dot(n) / denom;
    return if (t > 0.001) t else null;
}

fn trace(ray_origin: Vec3, ray_dir: Vec3) Vec3 {
    var closest: ?Hit = null;

    // 球体
    for (&spheres) |*s| {
        if (intersectSphere(ray_origin, ray_dir, s.*)) |t| {
            if (closest == null or t < closest.?.t) {
                const pt = ray_origin.add(ray_dir.scale(t));
                closest = .{ .t = t, .point = pt, .normal = pt.sub(s.center).normalize(), .color = s.color };
            }
        }
    }

    // 地面
    if (intersectPlane(ray_origin, ray_dir)) |t| {
        const pt = ray_origin.add(ray_dir.scale(t));
        const checker = (@mod(@floor(pt.x), 2.0) + @mod(@floor(pt.z), 2.0));
        const col: f64 = if (@mod(checker, 2.0) < 1.0) 0.5 else 0.8;
        if (closest == null or t < closest.?.t) {
            closest = .{ .t = t, .point = pt, .normal = .{ .x = 0.0, .y = 1.0, .z = 0 }, .color = .{ .x = col, .y = col, .z = col } };
        }
    }

    if (closest) |hit| {
        const to_light = light.sub(hit.point).normalize();
        const diff = @max(0, hit.normal.dot(to_light));
        // 简单阴影
        var shadow = false;
        for (&spheres) |*s| {
            if (intersectSphere(hit.point.add(hit.normal.scale(0.001)), to_light, s.*)) |_| {
                shadow = true;
                break;
            }
        }
        const brightness = if (shadow) ambient else ambient + diff * 0.85;
        return hit.color.scale(brightness);
    }

    // 天空渐变
    const t = 0.5 * (ray_dir.y + 1.0);
    return Vec3{ .x = 0.5 + t * 0.5, .y = 0.7 + t * 0.3, .z = 1.0 };
}

fn clamp(v: f64) u8 {
    if (v <= 0) return 0;
    if (v >= 1) return 255;
    return @intFromFloat(v * 255.0);
}

export fn raytrace_render() void {
    if (rendered) return;
    const aspect: f64 = @as(f64, @floatFromInt(W)) / @as(f64, @floatFromInt(H));
    const origin = Vec3{ .x = 0.0, .y = 0.0, .z = 0 };

    var idx: usize = 0;
    var y: usize = 0;
    while (y < H) : (y += 1) {
        var x: usize = 0;
        while (x < W) : (x += 1) {
            const u = (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(W - 1)) - 0.5) * aspect;
            const v = 0.5 - @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(H - 1));
            const dir_raw = Vec3{ .x = u, .y = v, .z = -1.0 };
            const dir = dir_raw.normalize();
            const col = trace(origin, dir);
            pixels[idx] = clamp(col.x);
            idx += 1;
            pixels[idx] = clamp(col.y);
            idx += 1;
            pixels[idx] = clamp(col.z);
            idx += 1;
        }
    }
    rendered = true;
}

export fn raytrace_get_pixels() [*]u8 {
    return &pixels;
}
export fn raytrace_get_width() u32 {
    return W;
}
export fn raytrace_get_height() u32 {
    return H;
}
export fn raytrace_is_done() u32 {
    return if (rendered) @as(u32, 1) else @as(u32, 0);
}
